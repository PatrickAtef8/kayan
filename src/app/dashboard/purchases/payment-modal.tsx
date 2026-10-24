"use client";

import { useState, useTransition } from "react";
import { Modal } from "@/components/ui/modal";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { DEFAULT_PAYMENT_METHOD, PAYMENT_METHODS } from "@/lib/payment-methods";
import { recordPurchaseInvoicePayment } from "./actions";

function money(n: number) {
  return n.toLocaleString("ar-EG", { minimumFractionDigits: 2 });
}

// "تسجيل دفعة" for a purchase invoice: adds one payment (paid TO the supplier) (amount + date) to an invoice. The component is mounted
// only while open, so every opening starts with a clean form.
export function PaymentModal({
  onClose,
  purchaseInvoiceId,
  invoiceLabel,
  supplierName,
  total,
  paid,
  remaining,
}: {
  onClose: () => void;
  purchaseInvoiceId: string;
  invoiceLabel: string;
  supplierName: string;
  total: number;
  paid: number;
  remaining: number;
}) {
  const [amount, setAmount] = useState("");
  const [date, setDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [method, setMethod] = useState<string>(DEFAULT_PAYMENT_METHOD);
  const [notes, setNotes] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  const value = Number(amount);
  const valid = Number.isFinite(value) && value > 0;
  const after = valid ? Math.max(0, Math.round((remaining - value) * 100) / 100) : remaining;

  function submit() {
    setError(null);
    if (!valid) return setError("أدخل مبلغًا صحيحًا أكبر من صفر");
    if (Math.round(value * 100) > Math.round(remaining * 100)) return setError(`المبلغ أكبر من المتبقي على الفاتورة (${money(remaining)} ج.م)`);
    startTransition(async () => {
      const result = await recordPurchaseInvoicePayment({ purchase_invoice_id: purchaseInvoiceId, amount: value, payment_date: date, payment_method: method, notes });
      if (result.error) return setError(result.error);
      onClose();
    });
  }

  return (
    <Modal open onClose={onClose} title={`تسجيل دفعة — ${invoiceLabel}`}>
      <div className="space-y-4">
        <div className="text-xs text-charcoal/50">{supplierName}</div>
        <div className="grid grid-cols-3 gap-2 rounded-xl border border-borderSoft p-3 text-center text-xs text-charcoal/50">
          <div>
            <div>إجمالي الفاتورة</div>
            <div className="mt-1 text-sm font-medium text-charcoal" dir="ltr">{money(total)}</div>
          </div>
          <div>
            <div>المدفوع</div>
            <div className="mt-1 text-sm font-medium text-sage" dir="ltr">{money(paid)}</div>
          </div>
          <div>
            <div>المتبقي</div>
            <div className="mt-1 text-sm font-medium text-rose" dir="ltr">{money(remaining)}</div>
          </div>
        </div>

        <Field label="مبلغ الدفعة (ج.م)">
          <div className="flex items-center gap-2">
            <Input type="number" min="0" max={remaining} step="0.01" dir="ltr" autoFocus value={amount} onChange={(e) => setAmount(e.target.value)} className="rounded-xl" />
            <button type="button" onClick={() => setAmount(String(remaining))} className="shrink-0 rounded-lg px-2 py-1 text-xs text-sage hover:bg-sageSoft/30">سداد المتبقي</button>
          </div>
        </Field>
        <Field label="تاريخ الدفع">
          <Input type="date" dir="ltr" value={date} onChange={(e) => setDate(e.target.value)} className="rounded-xl" />
        </Field>
        <Field label="طريقة الدفع">
          <select value={method} onChange={(e) => setMethod(e.target.value)} className="w-full rounded-xl border border-borderSoft bg-white px-3.5 py-3 text-base text-charcoal focus:border-sage focus:outline-none">
            {PAYMENT_METHODS.map((m) => (
              <option key={m} value={m}>{m}</option>
            ))}
          </select>
        </Field>
        <Field label="ملاحظات (اختياري)">
          <Input value={notes} onChange={(e) => setNotes(e.target.value)} className="rounded-xl" />
        </Field>

        {valid && (
          <p className="text-xs text-charcoal/50">
            {after === 0 ? "بعد هذه الدفعة تصبح الفاتورة مدفوعة بالكامل." : <>بعد هذه الدفعة يتبقى <span dir="ltr">{money(after)} ج.م</span> وتظل الفاتورة مدفوعة جزئيًا.</>}
          </p>
        )}
        {error && <p className="text-sm text-rose">{error}</p>}

        <div className="flex justify-end gap-2 pt-1">
          <Button variant="ghost" type="button" onClick={onClose} disabled={pending}>إلغاء</Button>
          <Button type="button" onClick={submit} disabled={pending}>{pending ? "جارٍ الحفظ..." : "تسجيل الدفعة"}</Button>
        </div>
      </div>
    </Modal>
  );
}
