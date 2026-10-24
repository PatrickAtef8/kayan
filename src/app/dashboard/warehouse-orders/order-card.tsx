"use client";

import { useState, useTransition } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { FulfilmentBadge } from "@/components/ui/fulfilment-badge";
import { confirmFulfilment } from "./actions";

export type OrderLine = {
  line_id: string;
  product_name: string;
  unit: string;
  ordered: number;
  fulfilled: number;
  released: number;
  open: number;
  expiry_date?: string | null;
};
export type OrderEvent = { at: string; by: string | null; type: "confirm" | "release"; product_name: string; quantity: number; note: string | null };
export type Order = {
  id: string;
  invoice_number: string | null;
  invoice_date: string;
  party_name: string | null;
  warehouse_name: string | null;
  status: string;
  completed_at: string | null;
  completed_by: string | null;
  lines: OrderLine[];
  history: OrderEvent[];
};

export function OrderCard({ order, kind, canConfirm }: { order: Order; kind: "sales" | "purchase"; canConfirm: boolean }) {
  const isOpen = order.status === "pending" || order.status === "partial";
  const [qty, setQty] = useState<Record<string, string>>(() => Object.fromEntries(order.lines.map((l) => [l.line_id, String(l.open)])));
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [showHistory, setShowHistory] = useState(false);
  const [pending, startTransition] = useTransition();
  const verb = kind === "sales" ? "الصرف" : "الاستلام";

  function submit() {
    setError(null);
    const lines = order.lines
      .filter((l) => l.open > 0)
      .map((l) => ({ line_id: l.line_id, quantity: Number(qty[l.line_id] || 0) }));
    for (const l of order.lines) {
      const q = Number(qty[l.line_id] || 0);
      if (q > l.open) {
        setError(`الكمية المُدخلة لـ«${l.product_name}» أكبر من المتبقي (${l.open})`);
        return;
      }
      if (q < 0 || Number.isNaN(q)) {
        setError("كمية غير صحيحة");
        return;
      }
    }
    const total = lines.reduce((s, l) => s + l.quantity, 0);
    if (total <= 0) {
      setError("أدخل كمية واحدة على الأقل");
      return;
    }
    const partial = order.lines.some((l) => l.open > 0 && Number(qty[l.line_id] || 0) < l.open);
    if (partial && !confirm(`بعض الأصناف أقل من المطلوب وسيبقى المتبقي مفتوحًا. تأكيد ${verb} الجزئي؟`)) return;
    startTransition(async () => {
      const r = await confirmFulfilment({ kind, invoiceId: order.id, lines, note });
      if (r.error) setError(r.error);
    });
  }

  return (
    <div className="mb-4 rounded-xl border border-borderSoft bg-white p-4 sm:p-5">
      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
        <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm">
          <span className="font-semibold text-charcoal" dir="ltr">{order.invoice_number ?? "—"}</span>
          <span className="text-charcoal/55">{order.party_name ?? "—"}</span>
          <span className="text-xs text-charcoal/40">{order.warehouse_name ?? ""}</span>
          <span className="text-xs text-charcoal/40" dir="ltr">{order.invoice_date}</span>
        </div>
        <FulfilmentBadge kind={kind} status={order.status} at={order.completed_at} />
      </div>

      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-borderSoft text-xs text-charcoal/45">
              <th className="py-2 text-right font-medium">الصنف</th>
              <th className="py-2 text-right font-medium">المطلوب</th>
              <th className="py-2 text-right font-medium">{kind === "sales" ? "تم صرفه" : "تم استلامه"}</th>
              {order.lines.some((l) => l.released > 0) && <th className="py-2 text-right font-medium">أُلغي بمرتجع</th>}
              <th className="py-2 text-right font-medium">المتبقي</th>
              {isOpen && canConfirm && <th className="py-2 text-right font-medium">{kind === "sales" ? "الكمية المصروفة الآن" : "الكمية المستلمة الآن"}</th>}
            </tr>
          </thead>
          <tbody>
            {order.lines.map((l) => (
              <tr key={l.line_id} className="border-b border-borderSoft/60 last:border-0">
                <td className="py-2">
                  {l.product_name} <span className="text-xs text-charcoal/35">{l.unit}</span>
                  {l.expiry_date && <span className="mr-2 text-[0.6875rem] text-charcoal/35" dir="ltr">صلاحية {l.expiry_date}</span>}
                </td>
                <td className="py-2" dir="ltr">{l.ordered}</td>
                <td className="py-2" dir="ltr">{l.fulfilled}</td>
                {order.lines.some((x) => x.released > 0) && <td className="py-2" dir="ltr">{l.released || "—"}</td>}
                <td className="py-2 font-medium" dir="ltr">{l.open}</td>
                {isOpen && canConfirm && (
                  <td className="w-36 py-1.5">
                    {l.open > 0 ? (
                      <Input type="number" min="0" max={l.open} step="0.001" dir="ltr" value={qty[l.line_id] ?? ""} onChange={(e) => setQty((p) => ({ ...p, [l.line_id]: e.target.value }))} />
                    ) : (
                      <span className="text-charcoal/30">—</span>
                    )}
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {isOpen && canConfirm && (
        <div className="mt-3 flex flex-wrap items-end gap-3">
          <div className="min-w-[12rem] flex-1">
            <Input placeholder="ملاحظة (اختياري) — مثلًا: نقص من المورد" value={note} onChange={(e) => setNote(e.target.value)} />
          </div>
          <Button type="button" disabled={pending} onClick={submit}>{pending ? "جارٍ التسجيل..." : `تأكيد ${verb}`}</Button>
        </div>
      )}
      {error && <p className="mt-2 text-xs text-rose">{error}</p>}

      {!isOpen && order.completed_at && (
        <p className="mt-3 text-xs text-charcoal/45">
          {kind === "sales" ? "أكّد الصرف" : "أكّد الاستلام"}: {order.completed_by ?? "—"} — {new Date(order.completed_at).toLocaleString("ar-EG")}
        </p>
      )}

      {order.history.length > 0 && (
        <div className="mt-3">
          <button type="button" onClick={() => setShowHistory((v) => !v)} className="text-xs text-sage hover:underline">
            {showHistory ? "إخفاء السجل" : `سجل التأكيدات (${order.history.length})`}
          </button>
          {showHistory && (
            <ul className="mt-2 space-y-1 text-xs text-charcoal/55">
              {order.history.map((h, i) => (
                <li key={i}>
                  <span dir="ltr">{new Date(h.at).toLocaleString("ar-EG")}</span> — {h.by ?? "النظام"} —{" "}
                  {h.type === "confirm" ? (kind === "sales" ? "صرف" : "استلام") : "إلغاء كمية بمرتجع"} {h.quantity} من {h.product_name}
                  {h.note ? ` — ${h.note}` : ""}
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </div>
  );
}
