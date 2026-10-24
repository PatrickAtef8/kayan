"use client";

import { useEffect, useState, useTransition } from "react";
import { Modal } from "@/components/ui/modal";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { getReturnableItems, createSalesReturn, type ReturnableItem, type ReturnReason } from "./actions";

function money(n: number) {
  return n.toLocaleString("ar-EG", { minimumFractionDigits: 2 });
}

type LineState = { quantity: string; condition: "resalable" | "damaged"; reason: "" | "damaged" | "expired" | "slow_moving" | "other" };

const REASONS = [
  { value: "damaged", label: "تالف" },
  { value: "expired", label: "صلاحية منتهية" },
  { value: "slow_moving", label: "عدم الدوران عند التاجر" },
  { value: "other", label: "أخرى" },
] as const;

export function ReturnFormModal({
  open,
  onClose,
  salesInvoiceId,
  invoiceLabel,
}: {
  open: boolean;
  onClose: () => void;
  salesInvoiceId: string;
  invoiceLabel: string;
}) {
  const [items, setItems] = useState<ReturnableItem[]>([]);
  const [lines, setLines] = useState<Record<string, LineState>>({});
  const [returnDate, setReturnDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [cashRefund, setCashRefund] = useState(0);
  const [notes, setNotes] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  // Entering "open for this invoice" starts a load: raise the flag while rendering, not inside the effect.
  const fetchKey = open ? salesInvoiceId : null;
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
    getReturnableItems(salesInvoiceId).then((result) => {
      if (result.error) {
        setError(result.error);
      } else {
        setItems(result.items.filter((i) => i.returnable > 0));
        setLines(Object.fromEntries(result.items.map((i) => [i.sales_invoice_item_id, { quantity: "", condition: "resalable" as const, reason: "" as const }])));
      }
      setLoading(false);
    });
  }, [open, salesInvoiceId]);

  function updateLine(id: string, patch: Partial<LineState>) {
    setLines((prev) => ({ ...prev, [id]: { ...prev[id], ...patch } }));
  }

  // "Full return": every remaining unit of every line (bonus units included).
  function fillAll() {
    setLines((prev) => {
      const next = { ...prev };
      for (const item of items) next[item.sales_invoice_item_id] = { ...(prev[item.sales_invoice_item_id] ?? { condition: "resalable" as const, reason: "" as const }), quantity: String(item.returnable) };
      return next;
    });
  }

  // The server credits the goods at their net price PLUS their share of the invoice
  // tax (last piece takes the remainder, like create_sales_return).
  const previewTax = items.reduce((sum, item) => {
    const qty = Number(lines[item.sales_invoice_item_id]?.quantity || 0);
    if (qty <= 0) return sum;
    const units = item.quantity + item.bonus_quantity;
    const share = qty >= item.returnable ? item.tax_alloc - item.tax_returned : Math.round((item.tax_alloc * qty) / units * 100) / 100;
    return sum + share;
  }, 0);
  const previewGoods = items.reduce((sum, item) => {
    const qty = Number(lines[item.sales_invoice_item_id]?.quantity || 0);
    return sum + qty * item.unit_price;
  }, 0);
  const previewTotal = previewGoods + previewTax;

  function submit() {
    setError(null);
    const payload = items
      .map((item) => ({
        sales_invoice_item_id: item.sales_invoice_item_id,
        quantity: Number(lines[item.sales_invoice_item_id]?.quantity || 0),
        condition: lines[item.sales_invoice_item_id]?.condition ?? "resalable",
        reason: lines[item.sales_invoice_item_id]?.reason ?? "",
      }))
      .filter((line) => line.quantity > 0);

    if (payload.length === 0) {
      setError("أدخل كمية لصنف واحد على الأقل");
      return;
    }
    if (payload.some((line) => !line.reason)) {
      setError("اختر سبب الإرجاع لكل صنف");
      return;
    }

    startTransition(async () => {
      const result = await createSalesReturn({
        sales_invoice_id: salesInvoiceId,
        return_date: returnDate,
        items: payload.map((line) => ({ ...line, reason: line.reason as ReturnReason })),
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
    <Modal open={open} onClose={onClose} title={`تسجيل مرتجع — ${invoiceLabel}`}>
      {loading ? (
        <p className="text-sm text-charcoal/45">جارٍ التحميل...</p>
      ) : items.length === 0 ? (
        <p className="text-sm text-charcoal/45">لا توجد أصناف قابلة للإرجاع في هذه الفاتورة.</p>
      ) : (
        <div className="max-h-[60vh] space-y-4 overflow-y-auto">
          <div className="flex items-center justify-between">
            <p className="text-xs text-charcoal/50">المرتجع يُحسب بالسعر الصافي الفعلي بعد الخصومات والـBonus.</p>
            <button type="button" onClick={fillAll} className="rounded-lg px-2 py-1 text-xs text-sage hover:bg-sageSoft/30">إرجاع كامل الفاتورة</button>
          </div>
          <div className="space-y-3">
            {items.map((item) => (
              <div key={item.sales_invoice_item_id} className="rounded-xl border border-borderSoft p-3">
                <div className="mb-2 flex items-center justify-between text-sm">
                  <span className="text-charcoal">
                    {item.product_name}
                    {item.is_bonus && <span className="mr-2 rounded bg-sageSoft/50 px-1.5 py-0.5 text-[0.65rem] text-sage">Bonus</span>}
                  </span>
                  <span className="text-xs text-charcoal/40" dir="ltr">
                    المتاح: {item.returnable}
                    {item.bonus_quantity > 0 ? ` (شامل ${item.bonus_quantity} Bonus)` : ""} · {money(item.unit_price)} ج.م/قطعة
                  </span>
                </div>
                <div className="grid grid-cols-3 gap-2">
                  <Input
                    type="number"
                    min="0"
                    max={item.returnable}
                    step="0.001"
                    dir="ltr"
                    placeholder="الكمية"
                    value={lines[item.sales_invoice_item_id]?.quantity ?? ""}
                    onChange={(e) => updateLine(item.sales_invoice_item_id, { quantity: e.target.value })}
                  />
                  <select
                    value={lines[item.sales_invoice_item_id]?.condition ?? "resalable"}
                    onChange={(e) => updateLine(item.sales_invoice_item_id, { condition: e.target.value as "resalable" | "damaged" })}
                    className="rounded-lg border border-borderSoft bg-white px-2.5 text-sm text-charcoal focus:border-sage focus:outline-none"
                  >
                    <option value="resalable">صالح لإعادة البيع</option>
                    <option value="damaged">تالف</option>
                  </select>
                  <select
                    value={lines[item.sales_invoice_item_id]?.reason ?? ""}
                    onChange={(e) => {
                      const reason = e.target.value as LineState["reason"];
                      // damaged / expired goods are normally not re-sold: suggest it (the user can still change the condition)
                      updateLine(item.sales_invoice_item_id, reason === "damaged" || reason === "expired" ? { reason, condition: "damaged" } : { reason });
                    }}
                    className="rounded-lg border border-borderSoft bg-white px-2.5 text-sm text-charcoal focus:border-sage focus:outline-none"
                  >
                    <option value="">سبب الإرجاع…</option>
                    {REASONS.map((r) => (
                      <option key={r.value} value={r.value}>{r.label}</option>
                    ))}
                  </select>
                </div>
              </div>
            ))}
          </div>

          <Field label="تاريخ المرتجع">
            <Input type="date" dir="ltr" value={returnDate} onChange={(e) => setReturnDate(e.target.value)} />
          </Field>
          <Field label="استرجاع نقدي (اختياري)">
            <Input type="number" min="0" max={previewTotal} step="0.01" dir="ltr" value={cashRefund} onChange={(e) => setCashRefund(Number(e.target.value))} />
          </Field>
          <Field label="ملاحظات">
            <Input value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="سبب الإرجاع" />
          </Field>

          <div className="flex items-center justify-between border-t border-borderSoft pt-3 text-sm">
            <span className="text-charcoal/50">إجمالي قيمة المرتجع (تقريبي{previewTax > 0 ? " — شامل الضريبة" : ""})</span>
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
