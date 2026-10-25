"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Plus, Trash2 } from "lucide-react";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ModernSelect } from "@/components/ui/select";
import { PricingSummary, usePricingPreview } from "@/components/sales/pricing-summary";
import { BonusEditor, type BonusRow } from "@/components/sales/bonus-editor";
import { PAYMENT_METHODS, DEFAULT_PAYMENT_METHOD } from "@/lib/payment-methods";
import { createPurchaseInvoice, type PurchaseItemInput } from "./actions";
import type { ProductOption } from "./page";

type Row = PurchaseItemInput & { key: number };

// Present when the form was opened from a stock-shortage report: the missing product is already in the first row and
// the saved invoice is linked back to that report. All values are editable defaults.
export type ShortagePrefill = {
  reportId: string;
  productId: string;
  productName: string;
  unit: string;
  warehouseId?: string;
  suggestedQty?: number; // what is STILL missing (needed − sellable − already on its way); falls back to the shortfall at report time
  incoming?: number; // units already on their way on live purchase invoices linked to this report
  covered?: boolean; // those purchases already cover the shortage -> a further purchase needs an explicit confirmation
  pending?: { invoice_number: string | null; open_units: number }[];
};

let rowKey = 0;
function emptyRow(): Row {
  return { key: rowKey++, product_id: "", quantity: 1, unit_cost: 0, discount_pct: 0 };
}

export function PurchaseForm({
  suppliers,
  warehouses,
  products,
  prefill,
}: {
  suppliers: { id: string; name: string; payment_terms_days: number | null }[];
  warehouses: { id: string; name: string }[];
  products: ProductOption[];
  prefill?: ShortagePrefill;
}) {
  const router = useRouter();
  const [supplierId, setSupplierId] = useState("");
  const [warehouseId, setWarehouseId] = useState(prefill?.warehouseId ?? warehouses[0]?.id ?? "");
  const [invoiceNumber, setInvoiceNumber] = useState("");
  const [invoiceDate, setInvoiceDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [dueDate, setDueDate] = useState("");
  const [discountPct, setDiscountPct] = useState(0);
  const [cashDiscountPct, setCashDiscountPct] = useState(0);
  const [bonusRows, setBonusRows] = useState<BonusRow[]>([]);
  const [taxTotal, setTaxTotal] = useState(0);
  const [amountPaid, setAmountPaid] = useState(0);
  const [paymentMethod, setPaymentMethod] = useState<string>(DEFAULT_PAYMENT_METHOD);
  const [notes, setNotes] = useState("");
  const [rows, setRows] = useState<Row[]>(() =>
    prefill
      ? [{ ...emptyRow(), product_id: prefill.productId, quantity: prefill.suggestedQty ?? 1, unit_cost: products.find((p) => p.id === prefill.productId)?.cost ?? 0 }]
      : [emptyRow()]
  );
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [confirmAdditional, setConfirmAdditional] = useState(false);
  const [pending, startTransition] = useTransition();

  const productById = (id: string) => products.find((p) => p.id === id);
  const { preview, error: previewError } = usePricingPreview({
    applies_to: "purchases",
    items: rows.map(({ key, ...r }) => r),
    invoice_discount_pct: discountPct,
    cash_discount_pct: cashDiscountPct,
    amount_paid: amountPaid,
    tax: taxTotal,
    bonus_items: bonusRows.map(({ key, ...b }) => b),
  });

  function updateRow(key: number, patch: Partial<Row>) {
    setRows((current) => current.map((r) => (r.key === key ? { ...r, ...patch } : r)));
  }

  function setProduct(key: number, productId: string) {
    const product = productById(productId);
    updateRow(key, { product_id: productId, unit_cost: product?.cost ?? 0 });
  }

  const terms = suppliers.find((s) => s.id === supplierId)?.payment_terms_days ?? null;
  const termsDueText = (() => {
    if (terms === null || !invoiceDate) return "";
    const d = new Date(invoiceDate + "T00:00:00");
    d.setDate(d.getDate() + terms);
    return d.toLocaleDateString("ar-EG", { year: "numeric", month: "short", day: "numeric" });
  })();

  function submit() {
    setError(null);
    setNotice(null);
    startTransition(async () => {
      const result = await createPurchaseInvoice({
        supplier_id: supplierId,
        warehouse_id: warehouseId,
        invoice_number: invoiceNumber,
        invoice_date: invoiceDate,
        due_date: dueDate,
        items: rows.map(({ key, ...item }) => item),
        discount_pct: discountPct,
        cash_discount_pct: cashDiscountPct,
        bonus_items: bonusRows.map(({ key, ...b }) => b),
        tax_total: taxTotal,
        amount_paid: amountPaid,
        payment_method: paymentMethod,
        notes,
        shortage_report_id: prefill?.reportId,
        confirm_additional: confirmAdditional,
      });
      if (result.error) {
        setError(result.error);
        return;
      }
      if (prefill && result.linkedShortage) {
        // back to the shortage reports: the report now shows «جاري التجهيز» with this invoice attached
        router.push("/dashboard/shortages?status=in_progress");
        return;
      }
      if (result.warning) setNotice(result.warning);
      setSupplierId("");
      setInvoiceNumber("");
      setDiscountPct(0);
      setCashDiscountPct(0);
      setBonusRows([]);
      setTaxTotal(0);
      setAmountPaid(0);
      setNotes("");
      setRows([emptyRow()]);
    });
  }

  return (
    <Card className="p-5 sm:p-6">
      {prefill && (
        <div className="mb-5 flex flex-wrap items-center justify-between gap-3 rounded-xl border border-brass/30 bg-brass/10 px-4 py-3 text-sm text-charcoal">
          <div>
            فاتورة شراء لتغطية بلاغ نقص: <b>{prefill.productName}</b>
            {prefill.suggestedQty ? <span className="text-charcoal/60"> — الناقص فعليًا الآن <b dir="ltr">{prefill.suggestedQty}</b> {prefill.unit}</span> : null}
            <div className="mt-0.5 text-xs text-charcoal/55">اختر المورد وحدّد الكمية المطلوب شراؤها، وبعد حفظ الفاتورة يتحدّث البلاغ تلقائيًا. تُضاف الكمية للمخزون عند استلام أمين المخزن للفاتورة.</div>
          </div>
          <Link href="/dashboard/shortages" className="shrink-0 text-xs text-charcoal/55 underline-offset-2 hover:text-sage hover:underline">رجوع للبلاغات</Link>
        </div>
      )}
      {prefill?.covered && (
        <div className="mb-5 rounded-xl border border-rose/30 bg-rose/5 px-4 py-3 text-sm text-charcoal">
          <div className="font-medium text-rose">يوجد بالفعل فاتورة شراء قائمة تغطي هذا العجز</div>
          <ul className="mt-1 text-xs text-charcoal/65">
            {(prefill.pending ?? []).map((p, i) => (
              <li key={i}>فاتورة <span dir="ltr">{p.invoice_number ?? "بدون رقم"}</span> — بانتظار استلام <b dir="ltr">{p.open_units}</b> {prefill.unit}</li>
            ))}
          </ul>
          <label className="mt-2 flex cursor-pointer items-center gap-2 text-xs text-charcoal/70">
            <input type="checkbox" checked={confirmAdditional} onChange={(e) => setConfirmAdditional(e.target.checked)} />
            أؤكد أنني أحتاج فاتورة شراء إضافية لنفس البلاغ
          </label>
        </div>
      )}
      <div className="mb-5 grid grid-cols-1 gap-4 sm:grid-cols-5">
        <Field label="المورد">
          <ModernSelect value={supplierId} onChange={setSupplierId} allowClear={false} placeholder="اختر موردًا" options={suppliers.map((s) => ({ value: s.id, label: s.name }))} />
        </Field>
        <Field label="المخزن">
          <ModernSelect value={warehouseId} onChange={setWarehouseId} allowClear={false} placeholder="اختر مخزنًا" options={warehouses.map((w) => ({ value: w.id, label: w.name }))} />
        </Field>
        <Field label="رقم الفاتورة">
          <Input value={invoiceNumber} onChange={(e) => setInvoiceNumber(e.target.value)} dir="ltr" placeholder="يُولَّد تلقائيًا إن تُرك فارغًا" />
        </Field>
        <Field label="تاريخ الفاتورة">
          <Input type="date" value={invoiceDate} onChange={(e) => setInvoiceDate(e.target.value)} dir="ltr" />
        </Field>
        <Field label="تاريخ الاستحقاق (اختياري)">
          <Input type="date" value={dueDate} min={invoiceDate} onChange={(e) => setDueDate(e.target.value)} dir="ltr" />
          {!dueDate && terms !== null && invoiceDate && (
            <p className="mt-1 text-[0.6875rem] text-charcoal/40">سيُحسب تلقائيًا: {termsDueText} (مدة سداد المورد {terms} يوم)</p>
          )}
        </Field>
      </div>

      <div className="mb-3 text-xs font-medium text-charcoal/45">الأصناف</div>
      <div className="space-y-2.5">
        {rows.map((row) => {
          const product = productById(row.product_id);
          return (
            <div key={row.key} className="grid grid-cols-1 gap-2.5 rounded-xl border border-borderSoft bg-paper/40 p-3 sm:grid-cols-[1.6fr_0.8fr_0.9fr_0.8fr_1fr_auto] sm:items-end">
              <Field label="المنتج">
                <ModernSelect value={row.product_id} onChange={(id) => setProduct(row.key, id)} allowClear={false} placeholder="اختر منتجًا" options={products.map((p) => ({ value: p.id, label: p.name }))} />
              </Field>
              <Field label={`الكمية${product ? ` (${product.unit})` : ""}`}>
                <Input type="number" step="0.001" min="0" dir="ltr" value={row.quantity} onChange={(e) => updateRow(row.key, { quantity: Number(e.target.value) })} />
              </Field>
              <Field label="سعر الشراء">
                <Input type="number" step="0.01" min="0" dir="ltr" value={row.unit_cost} onChange={(e) => updateRow(row.key, { unit_cost: Number(e.target.value) })} />
              </Field>
              <Field label="خصم الصنف (%)">
                <Input type="number" step="0.01" min="0" max="100" dir="ltr" value={row.discount_pct} onChange={(e) => updateRow(row.key, { discount_pct: Number(e.target.value) })} />
              </Field>
              <Field label="الصلاحية (اختياري)">
                <Input type="date" dir="ltr" value={row.expiry_date ?? ""} onChange={(e) => updateRow(row.key, { expiry_date: e.target.value })} />
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
      <p className="mt-1 px-2 text-[0.6875rem] text-charcoal/40">
        تاريخ الصلاحية اختياري. لنفس الصنف بتواريخ مختلفة أضِف سطرًا لكل تاريخ.
      </p>

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
        <Field label="المبلغ المدفوع الآن">
          <Input type="number" step="0.01" min="0" dir="ltr" value={amountPaid} onChange={(e) => setAmountPaid(Number(e.target.value))} />
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
          {error && <span className="text-xs text-rose">{error}</span>}
          {notice && <span className="text-xs text-brass">{notice}</span>}
          <Button type="button" disabled={pending || (!!prefill?.covered && !confirmAdditional)} onClick={submit}>
            {pending ? "جارٍ الحفظ..." : "حفظ فاتورة الشراء"}
          </Button>
        </div>
      </div>
    </Card>
  );
}

