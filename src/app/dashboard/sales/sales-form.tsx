"use client";

import { useCallback, useEffect, useState, useTransition } from "react";
import { Plus, Trash2, PackageX } from "lucide-react";
import Link from "next/link";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ModernSelect } from "@/components/ui/select";
import { AsyncSearchSelect } from "@/components/ui/async-search-select";
import { useKnownPicks } from "@/components/ui/use-known-picks";
import { searchCustomerPicks, searchSalesProductPicks } from "../lookup-actions";
import { PricingSummary, usePricingPreview } from "@/components/sales/pricing-summary";
import { BonusEditor, emptyBonusRow, type BonusRow } from "@/components/sales/bonus-editor";
import { PAYMENT_METHODS, DEFAULT_PAYMENT_METHOD } from "@/lib/payment-methods";
import { createSalesInvoice, type SalesItemInput } from "./actions";
import { requiredUnits, findShortages } from "@/lib/stock-requirements";
import { getSellableStock, reportStockShortage, type SellableRow } from "../shortages/actions";
import type { ProductOption, CustomerOption } from "./page";
import { cairoDate } from "@/lib/report-period";

type Row = SalesItemInput & { key: number };

let rowKey = 0;
function emptyRow(): Row {
  return { key: rowKey++, product_id: "", quantity: 1, unit_price: 0, discount_pct: 0 };
}

function priceForTier(product: ProductOption, tier: string): number {
  if (tier === "wholesale" && product.wholesale_price != null) return product.wholesale_price;
  if (tier === "distributor" && product.distributor_price != null) return product.distributor_price;
  return product.selling_price;
}

export function SalesForm({
  warehouses,
  representatives,
  restrictedRep = false,
  canAssignAnyRep = false,
  ownRepId = null,
  limits = null,
}: {
  warehouses: { id: string; name: string }[];
  representatives: { id: string; name: string }[];
  restrictedRep?: boolean;
  canAssignAnyRep?: boolean;
  ownRepId?: string | null;
  limits?: { unlimited: boolean; max_discount_pct: number | null; can_give_manual_bonus: boolean } | null;
}) {
  const [customerId, setCustomerId] = useState("");
  const [warehouseId, setWarehouseId] = useState(warehouses[0]?.id ?? "");
  // without the override permission a user can only invoice under their own rep record (the database enforces it)
  const [salesRepId, setSalesRepId] = useState(!canAssignAnyRep && ownRepId ? ownRepId : "");
  const [salesChannel, setSalesChannel] = useState("");
  const [invoiceNumber, setInvoiceNumber] = useState("");
  const [invoiceDate, setInvoiceDate] = useState(() => cairoDate());
  const [discountPct, setDiscountPct] = useState(0);
  const [cashDiscountPct, setCashDiscountPct] = useState(0);
  const [bonusRows, setBonusRows] = useState<BonusRow[]>([]);
  const [taxTotal, setTaxTotal] = useState(0);
  const [amountCollected, setAmountCollected] = useState(0);
  const [paymentMethod, setPaymentMethod] = useState<string>(DEFAULT_PAYMENT_METHOD);
  const [notes, setNotes] = useState("");
  const [rows, setRows] = useState<Row[]>([emptyRow()]);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  // What can be sold right now from the chosen warehouse (on hand − reserved − expired). Informational: the database
  // re-checks every quantity when the invoice is saved, so a stale number can never let an oversell through.
  const [stock, setStock] = useState<Record<string, SellableRow>>({});
  const [stockError, setStockError] = useState<string | null>(null);
  const [reportMsg, setReportMsg] = useState<Record<string, { ok: boolean; text: string }>>({});
  const [reporting, setReporting] = useState<string | null>(null);

  const refreshStock = useCallback(async () => {
    if (!warehouseId) return;
    const r = await getSellableStock(warehouseId);
    setStockError(r.error);
    if (!r.error) setStock(r.stock);
  }, [warehouseId]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const r = await getSellableStock(warehouseId);
      if (cancelled) return;
      setStockError(r.error);
      setStock(r.error ? {} : r.stock);
      setReportMsg({});
    })();
    const timer = setInterval(() => { if (document.visibilityState === "visible") refreshStock(); }, 30000);
    const onFocus = () => refreshStock();
    window.addEventListener("focus", onFocus);
    return () => { cancelled = true; clearInterval(timer); window.removeEventListener("focus", onFocus); };
  }, [warehouseId, refreshStock]);

  function adjustToAvailable(row: Row) {
    const s = stock[row.product_id];
    if (!s || s.available == null) return;
    const others = (requested.get(row.product_id) ?? 0) - (Number(row.quantity) || 0);
    updateRow(row.key, { quantity: Math.max(Math.round((s.available - others) * 1000) / 1000, 0) });
  }

  async function sendReport(productId: string, id: string) {
    setReporting(id);
    const r = await reportStockShortage({ productId, warehouseId, neededQty: requested.get(productId) ?? 0 });
    setReporting(null);
    const text = r.error ? r.error : r.duplicate ? "سبق إرسال بلاغ عن هذا الصنف وما زال مفتوحًا — لم يُرسل إشعار جديد" : "تم إرسال البلاغ للمالك";
    setReportMsg((m) => ({ ...m, [id]: { ok: !r.error, text } }));
    refreshStock();
  }

  // Customers and products are searched on the server as the person types (no full catalogue is loaded, so there is no 1000-row cap);
  // every record found is remembered here so a selection already has its price tier / prices.
  const { known: productMap, search: searchProducts } = useKnownPicks<ProductOption>(searchSalesProductPicks);
  const { known: customerMap, search: searchCustomers } = useKnownPicks<CustomerOption>(searchCustomerPicks);
  const productById = (id: string) => productMap.get(id);
  const customerTier = customerMap.get(customerId)?.price_tier ?? "retail";
  const { preview, error: previewError, pending: previewPending } = usePricingPreview({
    applies_to: "sales",
    items: rows.map(({ key, ...r }) => r),
    invoice_discount_pct: discountPct,
    cash_discount_pct: cashDiscountPct,
    amount_paid: amountCollected,
    tax: taxTotal,
    bonus_items: bonusRows.map(({ key, ...b }) => b),
  });

  // Units the invoice needs per product: paid lines + EVERY bonus unit (typed by hand or returned by the pricing
  // engine — the same list the invoice RPC will post). The database re-checks all of it atomically when saving.
  const required = requiredUnits(
    rows.filter((r) => r.product_id),
    bonusRows.filter((b) => b.product_id),
    preview?.bonus
  );
  const requested = new Map<string, number>([...required].map(([id, r]) => [id, r.total]));
  const shortages = findShortages(required, stock);
  const anyExceeds = shortages.length > 0;
  const hasLines = rows.some((r) => r.product_id && Number(r.quantity) > 0);
  const waitingForEngine = hasLines && previewPending;

  function updateRow(key: number, patch: Partial<Row>) {
    setRows((current) => current.map((r) => (r.key === key ? { ...r, ...patch } : r)));
  }

  function setProduct(key: number, productId: string) {
    const product = productById(productId);
    updateRow(key, { product_id: productId, unit_price: product ? priceForTier(product, customerTier) : 0 });
  }

  // Changing the customer re-prices rows whose price still matches their
  // product's price at the PREVIOUS tier (§17/§18) — a price the person
  // already typed over by hand is left alone rather than silently
  // overwritten.
  function selectCustomer(nextCustomerId: string) {
    const previousTier = customerMap.get(customerId)?.price_tier ?? "retail";
    const nextTier = customerMap.get(nextCustomerId)?.price_tier ?? "retail";
    setCustomerId(nextCustomerId);
    const nextRep = customerMap.get(nextCustomerId)?.sales_rep_id;
    if (nextRep && (canAssignAnyRep || !ownRepId)) setSalesRepId(nextRep);
    if (previousTier === nextTier) return;

    setRows((current) =>
      current.map((row) => {
        const product = productById(row.product_id);
        if (!product) return row;
        const previousExpected = priceForTier(product, previousTier);
        if (row.unit_price !== previousExpected) return row; // hand-edited — leave it
        return { ...row, unit_price: priceForTier(product, nextTier) };
      })
    );
  }

  function submit() {
    setError(null);
    startTransition(async () => {
      const result = await createSalesInvoice({
        customer_id: customerId,
        warehouse_id: warehouseId,
        sales_rep_id: salesRepId,
        sales_channel: salesChannel,
        invoice_number: invoiceNumber,
        invoice_date: invoiceDate,
        items: rows.map(({ key, ...item }) => item),
        discount_pct: discountPct,
        cash_discount_pct: cashDiscountPct,
        bonus_items: bonusRows.map(({ key, ...b }) => b),
        tax_total: taxTotal,
        amount_collected: amountCollected,
        payment_method: paymentMethod,
        notes,
      });
      if (result.error) {
        setError(result.error);
        refreshStock(); // the shortage may be real: show the current figures
        return;
      }
      refreshStock();
      setCustomerId("");
      setSalesRepId("");
      setSalesChannel("");
      setInvoiceNumber("");
      setDiscountPct(0);
      setCashDiscountPct(0);
      setBonusRows([]);
      setTaxTotal(0);
      setAmountCollected(0);
      setNotes("");
      setRows([emptyRow()]);
    });
  }

  return (
    <Card className="p-5 sm:p-6">
      {limits && !limits.unlimited && (
        <p className="mb-4 rounded-card bg-paper px-3 py-2 text-xs text-charcoal/60">
          أقصى خصم مسموح لدورك: <span dir="ltr">{Number(limits.max_discount_pct ?? 0)}%</span>
          {!limits.can_give_manual_bonus && " — والبونص اليدوي غير متاح لدورك"}
        </p>
      )}
      <div className="mb-5 grid grid-cols-1 gap-4 sm:grid-cols-6">
        <Field label="العميل">
          <AsyncSearchSelect value={customerId} selectedLabel={customerMap.get(customerId)?.name} onChange={(id) => selectCustomer(id)} search={searchCustomers} placeholder="اختر عميلًا" searchPlaceholder="ابحث بالاسم أو الهاتف..." />
        </Field>
        <Field label="المخزن">
          <ModernSelect value={warehouseId} onChange={setWarehouseId} allowClear={false} placeholder="اختر مخزنًا" options={warehouses.map((w) => ({ value: w.id, label: w.name }))} />
        </Field>
        {canAssignAnyRep && (
          <Field label="المندوب">
            <ModernSelect value={salesRepId} onChange={setSalesRepId} placeholder="بدون مندوب" clearLabel="بدون مندوب" options={representatives.map((r) => ({ value: r.id, label: r.name }))} />
          </Field>
        )}
        <Field label="قناة البيع">
          <ModernSelect
            value={salesChannel}
            onChange={setSalesChannel}
            placeholder="تلقائي حسب العميل"
            clearLabel="تلقائي حسب العميل"
            options={[
              { value: "wholesale", label: "جملة" },
              { value: "retail", label: "تجزئة" },
              { value: "social", label: "سوشيال ميديا" },
            ]}
          />
        </Field>
        <Field label="رقم الفاتورة">
          <Input value={invoiceNumber} onChange={(e) => setInvoiceNumber(e.target.value)} dir="ltr" placeholder="يُولَّد تلقائيًا إن تُرك فارغًا" />
        </Field>
        <Field label="تاريخ الفاتورة">
          <Input type="date" value={invoiceDate} onChange={(e) => setInvoiceDate(e.target.value)} dir="ltr" />
        </Field>
      </div>

      {anyExceeds && (
        <div role="alert" className="mb-4 rounded-xl border border-rose/30 bg-rose/10 p-3 text-xs text-rose">
          <p className="font-semibold">الفاتورة تتجاوز المخزون المتاح — لا يمكن حفظها بهذه الكميات</p>
          <ul className="mt-2 space-y-2">
            {shortages.map((sh) => {
              const inRows = rows.some((r) => r.product_id === sh.productId);
              return (
                <li key={sh.productId} className="flex flex-wrap items-center gap-2">
                  <span>
                    {productById(sh.productId)?.name}: {sh.available === 0 ? "غير متوفر حاليًا" : <>المتاح <b dir="ltr">{sh.available}</b></>} — المطلوب <b dir="ltr">{sh.required}</b>
                    {sh.bonus > 0 && <> (مبيعات {sh.paid} + بونص {sh.bonus})</>}
                  </span>
                  {!inRows && (
                    <button type="button" disabled={reporting === sh.productId} onClick={() => sendReport(sh.productId, sh.productId)} className="flex items-center gap-1.5 rounded-md bg-rose px-2.5 py-1.5 font-medium text-white hover:opacity-90 disabled:opacity-50">
                      <PackageX size={14} /> إبلاغ المالك بالنقص
                    </button>
                  )}
                  {!inRows && reportMsg[sh.productId] && <span className={reportMsg[sh.productId].ok ? "text-sage" : "text-rose"}>{reportMsg[sh.productId].text}</span>}
                </li>
              );
            })}
          </ul>
          <p className="mt-2 text-rose/80">قلّل الكميات (أو البونص) إلى المتاح، أو أبلغ المالك بالنقص.</p>
        </div>
      )}
      <div className="mb-3 text-xs font-medium text-charcoal/45">الأصناف</div>
      <div className="space-y-2.5">
        {rows.map((row) => {
          const product = productById(row.product_id);
          const st = row.product_id ? stock[row.product_id] : undefined;
          const tracked = !!st && st.tracked && st.available != null;
          const total = requested.get(row.product_id) ?? 0;
          const soldOut = tracked && st!.available === 0;
          const short = tracked && total > (st!.available as number);
          const msg = reportMsg[row.key.toString()];
          return (
            <div key={row.key} className="grid grid-cols-1 gap-2.5 rounded-xl border border-borderSoft bg-paper/40 p-3 sm:grid-cols-[1.6fr_0.8fr_0.9fr_0.8fr_auto] sm:items-end">
              <Field label="المنتج">
                <AsyncSearchSelect value={row.product_id} selectedLabel={product?.name} onChange={(id) => setProduct(row.key, id)} search={searchProducts} placeholder="اختر منتجًا" searchPlaceholder="ابحث باسم المنتج أو الكود..." />
              </Field>
              <Field label={`الكمية${product ? ` (${product.unit})` : ""}`}>
                <Input type="number" step="0.001" min="0" dir="ltr" value={row.quantity} onChange={(e) => updateRow(row.key, { quantity: Number(e.target.value) })} />
              </Field>
              <Field label="سعر البيع">
                <Input type="number" step="0.01" min="0" dir="ltr" value={row.unit_price} onChange={(e) => updateRow(row.key, { unit_price: Number(e.target.value) })} />
              </Field>
              <Field label="خصم الصنف (%)">
                <Input type="number" step="0.01" min="0" max="100" dir="ltr" value={row.discount_pct} onChange={(e) => updateRow(row.key, { discount_pct: Number(e.target.value) })} />
              </Field>
              <button type="button" onClick={() => setRows((current) => (current.length > 1 ? current.filter((r) => r.key !== row.key) : current))} className="flex h-11 w-11 items-center justify-center rounded-xl text-charcoal/35 hover:bg-rose/10 hover:text-rose" aria-label="حذف الصنف">
                <Trash2 size={16} />
              </button>
              {tracked && (
                <div className="sm:col-span-full" aria-live="polite">
                  {!short && (
                    <p className="text-xs text-charcoal/55">المتاح للبيع: <b dir="ltr">{st!.available}</b> {product?.unit}</p>
                  )}
                  {short && (
                    <div className="rounded-lg bg-rose/10 px-3 py-2 text-xs text-rose">
                      <p>
                        {soldOut
                          ? "الصنف غير متوفر حاليًا"
                          : <>الكمية المطلوبة <b dir="ltr">{total}</b>{(required.get(row.product_id)?.bonus ?? 0) > 0 && <> (مبيعات {required.get(row.product_id)!.paid} + بونص {required.get(row.product_id)!.bonus})</>} أكبر من المتاح حاليًا <b dir="ltr">{st!.available}</b></>}
                      </p>
                      <div className="mt-2 flex flex-wrap items-center gap-2">
                        {!soldOut && (
                          <button type="button" onClick={() => adjustToAvailable(row)} className="rounded-md bg-white px-2.5 py-1.5 font-medium text-charcoal hover:bg-paper">
                            اجعل الكمية {Math.max((st!.available as number) - (total - (Number(row.quantity) || 0)), 0)} (المتاح)
                          </button>
                        )}
                        <button type="button" disabled={reporting === row.key.toString()} onClick={() => sendReport(row.product_id, row.key.toString())} className="flex items-center gap-1.5 rounded-md bg-rose px-2.5 py-1.5 font-medium text-white hover:opacity-90 disabled:opacity-50">
                          <PackageX size={14} /> {reporting === row.key.toString() ? "جارٍ الإرسال..." : "إبلاغ المالك بالنقص"}
                        </button>
                        <Link href="/dashboard/shortages" className="underline">بلاغاتي</Link>
                      </div>
                      {msg && <p className={`mt-2 ${msg.ok ? "text-sage" : "text-rose"}`}>{msg.text}</p>}
                    </div>
                  )}
                </div>
              )}
            </div>
          );
        })}
      </div>
      <button type="button" onClick={() => setRows((current) => [...current, emptyRow()])} className="mt-3 flex items-center gap-1.5 rounded-lg px-2 py-1.5 text-xs text-sage hover:bg-sageSoft/30">
        <Plus size={15} /> إضافة صنف
      </button>

      <BonusEditor search={searchProducts} known={productMap} rows={bonusRows} onChange={setBonusRows} />

      <div className="mt-6 grid grid-cols-1 gap-4 border-t border-borderSoft pt-5 sm:grid-cols-5">
        <Field label="خصم على إجمالي الفاتورة (%)">
          <Input type="number" step="0.01" min="0" max="100" dir="ltr" value={discountPct} onChange={(e) => setDiscountPct(Number(e.target.value))} />
        </Field>
        <Field label="خصم الدفع الفوري (%)">
          <Input type="number" step="0.01" min="0" max="100" dir="ltr" value={cashDiscountPct} onChange={(e) => setCashDiscountPct(Number(e.target.value))} />
        </Field>
        <Field label="الضريبة">
          <Input type="number" step="0.01" min="0" dir="ltr" value={taxTotal} onChange={(e) => setTaxTotal(Number(e.target.value))} />
        </Field>
        <Field label="المبلغ المحصل الآن">
          <Input type="number" step="0.01" min="0" dir="ltr" value={amountCollected} onChange={(e) => setAmountCollected(Number(e.target.value))} />
        </Field>
        <Field label="طريقة الدفع">
          <ModernSelect value={paymentMethod} onChange={setPaymentMethod} allowClear={false} placeholder="اختر طريقة الدفع" options={PAYMENT_METHODS.map((m) => ({ value: m, label: m }))} />
        </Field>
      </div>
      <div className="mt-4">
        <Field label="ملاحظات (للعرض فقط — لا تدخل في أي حسابات)">
          <Input value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="اختياري" />
        </Field>
      </div>

      <div className="mt-6 flex flex-wrap items-center justify-between gap-4 border-t border-borderSoft pt-5">
        <div className="w-full max-w-md">
          <PricingSummary preview={preview} error={previewError} cashDiscountPctEntered={cashDiscountPct} productName={(id) => productById(id)?.name ?? ""} />
        </div>
        <div className="flex items-center gap-3">
          {stockError && <span className="text-xs text-charcoal/45">تعذّر تحميل الكميات المتاحة — سيتحقق النظام عند الحفظ</span>}
          {error && <span className="text-xs text-rose">{error}</span>}
          {anyExceeds && <span className="text-xs text-rose">الكميات أكبر من المتاح — راجع التنبيه أعلى الفاتورة</span>}
          {!anyExceeds && waitingForEngine && <span className="text-xs text-charcoal/45">جارٍ احتساب البونص والتحقق من المخزون...</span>}
          <Button type="button" disabled={pending || anyExceeds || waitingForEngine} onClick={submit}>
            {pending ? "جارٍ الحفظ..." : "حفظ فاتورة البيع"}
          </Button>
        </div>
      </div>
    </Card>
  );
}
