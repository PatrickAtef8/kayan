"use client";

import { useEffect, useState, useTransition } from "react";
import { Modal } from "@/components/ui/modal";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { getReturnablePurchaseItems, createPurchaseReturn, type ReturnablePurchaseItem } from "./actions";

function money(n: number) {
  return n.toLocaleString("ar-EG", { minimumFractionDigits: 2 });
}

export function ReturnFormModal({
  open,
  onClose,
  purchaseInvoiceId,
  invoiceLabel,
}: {
  open: boolean;
  onClose: () => void;
  purchaseInvoiceId: string;
  invoiceLabel: string;
}) {
  const [items, setItems] = useState<ReturnablePurchaseItem[]>([]);
  const [quantities, setQuantities] = useState<Record<string, string>>({});
  const [returnDate, setReturnDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [cashRefund, setCashRefund] = useState(0);
  const [notes, setNotes] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  // Entering "open for this invoice" starts a load: raise the flag while rendering, not inside the effect.
  const fetchKey = open ? purchaseInvoiceId : null;
  const [prevFetchKey, setPrevFetchKey] = useState<string | null>(null);
  if (fetchKey !== prevFetchKey) {
    setPrevFetchKey(fetchKey);
    if (fetchKey) {
      setLoading(true);
      setError(null);
    }
  }

  useEffect(() => {
    if (!open) return;
    getReturnablePurchaseItems(purchaseInvoiceId).then((result) => {
      if (result.error) {
        setError(result.error);
      } else {
        // A line can only be returned up to what's still on hand in the
        // warehouse (§27 design note above) — cap by whichever is smaller.
        setItems(result.items.filter((i) => i.returnable > 0));
        setQuantities(Object.fromEntries(result.items.map((i) => [i.purchase_invoice_item_id, ""])));
      }
      setLoading(false);
    });
  }, [open, purchaseInvoiceId]);

  function updateQuantity(id: string, value: string) {
    setQuantities((prev) => ({ ...prev, [id]: value }));
  }

  // "Full return": every remaining unit the warehouse can still give back.
  function fillAll() {
    setQuantities(Object.fromEntries(items.map((i) => [i.purchase_invoice_item_id, String(Math.min(i.returnable, i.on_hand))])));
  }

  // The server credits the goods at their net cost PLUS their share of the invoice
  // tax (last piece takes the remainder, like create_purchase_return).
  const previewTax = items.reduce((sum, item) => {
    const qty = Number(quantities[item.purchase_invoice_item_id] || 0);
    if (qty <= 0) return sum;
    const units = item.quantity + item.bonus_quantity;
    const share = qty >= item.returnable ? item.tax_alloc - item.tax_returned : Math.round((item.tax_alloc * qty) / units * 100) / 100;
    return sum + share;
  }, 0);
  const previewGoods = items.reduce((sum, item) => {
    const qty = Number(quantities[item.purchase_invoice_item_id] || 0);
    return sum + qty * item.unit_cost;
  }, 0);
  const previewTotal = previewGoods + previewTax;

  function submit() {
    setError(null);
    const payload = items
      .map((item) => ({
        purchase_invoice_item_id: item.purchase_invoice_item_id,
        quantity: Number(quantities[item.purchase_invoice_item_id] || 0),
      }))
      .filter((line) => line.quantity > 0);

    if (payload.length === 0) {
      setError("أدخل كمية لصنف واحد على الأقل");
      return;
    }

    startTransition(async () => {
      const result = await createPurchaseReturn({
        purchase_invoice_id: purchaseInvoiceId,
        return_date: returnDate,
        items: payload,
        cash_refund: cashRefund,
        notes,
      });
      if (result.error) {
        setError(result.error);
        return;
      }
      onClose();
    });
  }

  return (
    <Modal open={open} onClose={onClose} title={`تسجيل مرتجع شراء — ${invoiceLabel}`}>
      {loading ? (
        <p className="text-sm text-charcoal/45">جارٍ التحميل...</p>
      ) : items.length === 0 ? (
        <p className="text-sm text-charcoal/45">لا توجد أصناف قابلة للإرجاع في هذه الفاتورة (إما تم إرجاعها بالكامل أو لم يعد لها رصيد بالمخزون).</p>
      ) : (
        <div className="max-h-[60vh] space-y-4 overflow-y-auto">
          <div className="flex items-center justify-between">
            <p className="text-xs text-charcoal/50">المرتجع يُحسب بالتكلفة الصافية الفعلية بعد الخصومات والـBonus.</p>
            <button type="button" onClick={fillAll} className="rounded-lg px-2 py-1 text-xs text-sage hover:bg-sageSoft/30">إرجاع كامل الفاتورة</button>
          </div>
          <div className="space-y-3">
            {items.map((item) => {
              const cap = Math.min(item.returnable, item.on_hand);
              return (
                <div key={item.purchase_invoice_item_id} className="rounded-xl border border-borderSoft p-3">
                  <div className="mb-2 flex items-center justify-between text-sm">
                    <span className="text-charcoal">
                      {item.product_name}
                      {item.is_bonus && <span className="mr-2 rounded bg-sageSoft/50 px-1.5 py-0.5 text-[0.65rem] text-sage">Bonus</span>}
                    </span>
                    <span className="text-xs text-charcoal/40" dir="ltr">
                      المتاح للإرجاع: {cap}
                      {item.bonus_quantity > 0 ? ` (شامل ${item.bonus_quantity} Bonus)` : ""} · {money(item.unit_cost)} ج.م/قطعة
                    </span>
                  </div>
                  <Input
                    type="number"
                    min="0"
                    max={cap}
                    step="0.001"
                    dir="ltr"
                    placeholder="الكمية"
                    value={quantities[item.purchase_invoice_item_id] ?? ""}
                    onChange={(e) => updateQuantity(item.purchase_invoice_item_id, e.target.value)}
                  />
                </div>
              );
            })}
          </div>

          <Field label="تاريخ المرتجع">
            <Input type="date" dir="ltr" value={returnDate} onChange={(e) => setReturnDate(e.target.value)} />
          </Field>
          <Field label="استرجاع نقدي من المورد (اختياري)">
            <Input type="number" min="0" max={previewTotal} step="0.01" dir="ltr" value={cashRefund} onChange={(e) => setCashRefund(Number(e.target.value))} />
          </Field>
          <Field label="ملاحظات">
            <Input value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="سبب الإرجاع" />
          </Field>

          <div className="flex items-center justify-between border-t border-borderSoft pt-3 text-sm">
            <span className="text-charcoal/50">إجمالي قيمة المرتجع{previewTax > 0 ? " (شامل الضريبة)" : ""} (يخصم من مستحقات المورد)</span>
            <span className="font-medium text-charcoal" dir="ltr">
              {money(previewTotal)} ج.م
            </span>
          </div>

          <div className="flex items-center gap-3">
            <Button type="button" disabled={pending} onClick={submit}>
              {pending ? "جارٍ الحفظ..." : "تسجيل المرتجع"}
            </Button>
            {error && <span className="text-xs text-rose">{error}</span>}
          </div>
        </div>
      )}
    </Modal>
  );
}
