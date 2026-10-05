"use client";

import { useState, useTransition } from "react";
import { Plus, Trash2 } from "lucide-react";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ModernSelect } from "@/components/ui/select";
import { PricingSummary, usePricingPreview } from "@/components/sales/pricing-summary";
import { BonusEditor, emptyBonusRow, type BonusRow } from "@/components/sales/bonus-editor";
import { PAYMENT_METHODS, DEFAULT_PAYMENT_METHOD } from "@/lib/payment-methods";
import { createSalesInvoice, type SalesItemInput } from "./actions";
import type { ProductOption, CustomerOption } from "./page";

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
  customers,
  warehouses,
  products,
  representatives,
  restrictedRep = false,
}: {
  customers: CustomerOption[];
  warehouses: { id: string; name: string }[];
  products: ProductOption[];
  representatives: { id: string; name: string }[];
  restrictedRep?: boolean;
}) {
  const [customerId, setCustomerId] = useState("");
  const [warehouseId, setWarehouseId] = useState(warehouses[0]?.id ?? "");
  const [salesRepId, setSalesRepId] = useState("");
  const [invoiceNumber, setInvoiceNumber] = useState("");
  const [invoiceDate, setInvoiceDate] = useState(() => new Date().toISOString().slice(0, 10));
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

  const productById = (id: string) => products.find((p) => p.id === id);
  const customerTier = customers.find((c) => c.id === customerId)?.price_tier ?? "retail";
  const { preview, error: previewError } = usePricingPreview({
    applies_to: "sales",
    items: rows.map(({ key, ...r }) => r),
    invoice_discount_pct: discountPct,
    cash_discount_pct: cashDiscountPct,
    amount_paid: amountCollected,
    tax: taxTotal,
    bonus_items: bonusRows.map(({ key, ...b }) => b),
  });

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
    const previousTier = customers.find((c) => c.id === customerId)?.price_tier ?? "retail";
    const nextTier = customers.find((c) => c.id === nextCustomerId)?.price_tier ?? "retail";
    setCustomerId(nextCustomerId);
    const nextRep = customers.find((c) => c.id === nextCustomerId)?.sales_rep_id;
    if (nextRep) setSalesRepId(nextRep);
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
        return;
      }
      setCustomerId("");
      setSalesRepId("");
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
      <div className="mb-5 grid grid-cols-1 gap-4 sm:grid-cols-5">
        <Field label="العميل">
          <ModernSelect value={customerId} onChange={selectCustomer} allowClear={false} placeholder="اختر عميلًا" options={customers.map((c) => ({ value: c.id, label: c.name }))} />
        </Field>
        <Field label="المخزن">
          <ModernSelect value={warehouseId} onChange={setWarehouseId} allowClear={false} placeholder="اختر مخزنًا" options={warehouses.map((w) => ({ value: w.id, label: w.name }))} />
        </Field>
        {!restrictedRep && (
          <Field label="المندوب">
            <ModernSelect value={salesRepId} onChange={setSalesRepId} placeholder="بدون مندوب" clearLabel="بدون مندوب" options={representatives.map((r) => ({ value: r.id, label: r.name }))} />
          </Field>
        )}
        <Field label="رقم الفاتورة">
          <Input value={invoiceNumber} onChange={(e) => setInvoiceNumber(e.target.value)} dir="ltr" placeholder="اختياري" />
        </Field>
        <Field label="تاريخ الفاتورة">
          <Input type="date" value={invoiceDate} onChange={(e) => setInvoiceDate(e.target.value)} dir="ltr" />
        </Field>
      </div>

      <div className="mb-3 text-xs font-medium text-charcoal/45">الأصناف</div>
      <div className="space-y-2.5">
        {rows.map((row) => {
          const product = productById(row.product_id);
          return (
            <div key={row.key} className="grid grid-cols-1 gap-2.5 rounded-xl border border-borderSoft bg-paper/40 p-3 sm:grid-cols-[1.6fr_0.8fr_0.9fr_0.8fr_auto] sm:items-end">
              <Field label="المنتج">
                <ModernSelect value={row.product_id} onChange={(id) => setProduct(row.key, id)} allowClear={false} placeholder="اختر منتجًا" options={products.map((p) => ({ value: p.id, label: p.name }))} />
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
            </div>
          );
        })}
      </div>
      <button type="button" onClick={() => setRows((current) => [...current, emptyRow()])} className="mt-3 flex items-center gap-1.5 rounded-lg px-2 py-1.5 text-xs text-sage hover:bg-sageSoft/30">
        <Plus size={15} /> إضافة صنف
      </button>

      <BonusEditor products={products} rows={bonusRows} onChange={setBonusRows} />

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
          <select value={paymentMethod} onChange={(e) => setPaymentMethod(e.target.value)} className="h-11 w-full rounded-xl border border-borderSoft bg-white px-3 text-sm text-charcoal focus:border-sage focus:outline-none">
            {PAYMENT_METHODS.map((m) => (
              <option key={m} value={m}>{m}</option>
            ))}
          </select>
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
          {error && <span className="text-xs text-rose">{error}</span>}
          <Button type="button" disabled={pending} onClick={submit}>
            {pending ? "جارٍ الحفظ..." : "حفظ فاتورة البيع"}
          </Button>
        </div>
      </div>
    </Card>
  );
}
