"use client";

import { useState, useTransition } from "react";
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

let rowKey = 0;
function emptyRow(): Row {
  return { key: rowKey++, product_id: "", quantity: 1, unit_cost: 0, discount_pct: 0 };
}

export function PurchaseForm({
  suppliers,
  warehouses,
  products,
}: {
  suppliers: { id: string; name: string }[];
  warehouses: { id: string; name: string }[];
  products: ProductOption[];
}) {
  const [supplierId, setSupplierId] = useState("");
  const [warehouseId, setWarehouseId] = useState(warehouses[0]?.id ?? "");
  const [invoiceNumber, setInvoiceNumber] = useState("");
  const [invoiceDate, setInvoiceDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [discountPct, setDiscountPct] = useState(0);
  const [cashDiscountPct, setCashDiscountPct] = useState(0);
  const [bonusRows, setBonusRows] = useState<BonusRow[]>([]);
  const [taxTotal, setTaxTotal] = useState(0);
  const [amountPaid, setAmountPaid] = useState(0);
  const [paymentMethod, setPaymentMethod] = useState<string>(DEFAULT_PAYMENT_METHOD);
  const [notes, setNotes] = useState("");
  const [rows, setRows] = useState<Row[]>([emptyRow()]);
  const [error, setError] = useState<string | null>(null);
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

  function submit() {
    setError(null);
    startTransition(async () => {
      const result = await createPurchaseInvoice({
        supplier_id: supplierId,
        warehouse_id: warehouseId,
        invoice_number: invoiceNumber,
        invoice_date: invoiceDate,
        items: rows.map(({ key, ...item }) => item),
        discount_pct: discountPct,
        cash_discount_pct: cashDiscountPct,
        bonus_items: bonusRows.map(({ key, ...b }) => b),
        tax_total: taxTotal,
        amount_paid: amountPaid,
        payment_method: paymentMethod,
        notes,
      });
      if (result.error) {
        setError(result.error);
        return;
      }
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
      <div className="mb-5 grid grid-cols-1 gap-4 sm:grid-cols-4">
        <Field label="المورد">
          <ModernSelect value={supplierId} onChange={setSupplierId} allowClear={false} placeholder="اختر موردًا" options={suppliers.map((s) => ({ value: s.id, label: s.name }))} />
        </Field>
        <Field label="المخزن">
          <ModernSelect value={warehouseId} onChange={setWarehouseId} allowClear={false} placeholder="اختر مخزنًا" options={warehouses.map((w) => ({ value: w.id, label: w.name }))} />
        </Field>
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
              <Field label="سعر الشراء">
                <Input type="number" step="0.01" min="0" dir="ltr" value={row.unit_cost} onChange={(e) => updateRow(row.key, { unit_cost: Number(e.target.value) })} />
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
        <Field label="المبلغ المدفوع الآن">
          <Input type="number" step="0.01" min="0" dir="ltr" value={amountPaid} onChange={(e) => setAmountPaid(Number(e.target.value))} />
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
            {pending ? "جارٍ الحفظ..." : "حفظ فاتورة الشراء"}
          </Button>
        </div>
      </div>
    </Card>
  );
}

