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

      {/* phones: one card per item */}
      <ul className="space-y-3 md:hidden">
        {order.lines.map((l) => (
          <li key={l.line_id} className="rounded-xl border border-borderSoft/70 bg-paper/40 p-3">
            <p className="text-sm font-medium text-charcoal">
              {l.product_name} <span className="text-xs font-normal text-charcoal/40">{l.unit}</span>
            </p>
            {l.expiry_date && <p className="mt-0.5 text-[0.6875rem] text-charcoal/40">صلاحية <span dir="ltr" className="num">{l.expiry_date}</span></p>}
            <dl className="mt-2 grid grid-cols-3 gap-2 text-center text-xs">
              <div className="rounded-lg bg-white px-2 py-1.5"><dt className="text-charcoal/45">المطلوب</dt><dd className="mt-0.5 text-sm font-medium"><span className="num">{l.ordered}</span></dd></div>
              <div className="rounded-lg bg-white px-2 py-1.5"><dt className="text-charcoal/45">{kind === "sales" ? "تم صرفه" : "تم استلامه"}</dt><dd className="mt-0.5 text-sm font-medium"><span className="num">{l.fulfilled}</span></dd></div>
              <div className="rounded-lg bg-white px-2 py-1.5"><dt className="text-charcoal/45">المتبقي</dt><dd className="mt-0.5 text-sm font-semibold"><span className="num">{l.open}</span></dd></div>
            </dl>
            {l.released > 0 && <p className="mt-2 text-[0.6875rem] text-charcoal/45">أُلغي بمرتجع: <span className="num">{l.released}</span></p>}
            {isOpen && canConfirm && l.open > 0 && (
              <label className="mt-3 block text-xs text-charcoal/55">
                {kind === "sales" ? "الكمية المصروفة الآن" : "الكمية المستلمة الآن"}
                <div className="mt-1">
                  <Input type="number" min="0" max={l.open} step="0.001" dir="ltr" value={qty[l.line_id] ?? ""} onChange={(e) => setQty((p) => ({ ...p, [l.line_id]: e.target.value }))} />
                </div>
              </label>
            )}
          </li>
        ))}
      </ul>

      {/* larger screens: the table, numbers aligned under their headings */}
      <div className="hidden overflow-x-auto md:block">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-borderSoft text-xs text-charcoal/45">
              <th className="whitespace-nowrap px-3 py-2 text-start font-medium">الصنف</th>
              <th className="whitespace-nowrap px-3 py-2 text-start font-medium">المطلوب</th>
              <th className="whitespace-nowrap px-3 py-2 text-start font-medium">{kind === "sales" ? "تم صرفه" : "تم استلامه"}</th>
              {order.lines.some((l) => l.released > 0) && <th className="whitespace-nowrap px-3 py-2 text-start font-medium">أُلغي بمرتجع</th>}
              <th className="whitespace-nowrap px-3 py-2 text-start font-medium">المتبقي</th>
              {isOpen && canConfirm && <th className="whitespace-nowrap px-3 py-2 text-start font-medium">{kind === "sales" ? "الكمية المصروفة الآن" : "الكمية المستلمة الآن"}</th>}
            </tr>
          </thead>
          <tbody>
            {order.lines.map((l) => (
              <tr key={l.line_id} className="border-b border-borderSoft/60 last:border-0">
                <td className="px-3 py-2">
                  {l.product_name} <span className="text-xs text-charcoal/35">{l.unit}</span>
                  {l.expiry_date && <span className="mr-2 text-[0.6875rem] text-charcoal/35">صلاحية <span dir="ltr" className="num">{l.expiry_date}</span></span>}
                </td>
                <td className="px-3 py-2"><span className="num">{l.ordered}</span></td>
                <td className="px-3 py-2"><span className="num">{l.fulfilled}</span></td>
                {order.lines.some((x) => x.released > 0) && <td className="px-3 py-2"><span className="num">{l.released || "—"}</span></td>}
                <td className="px-3 py-2 font-medium"><span className="num">{l.open}</span></td>
                {isOpen && canConfirm && (
                  <td className="w-40 px-3 py-1.5">
                    {l.open > 0 ? (
                      <Input type="number" min="0" max={l.open} step="0.001" dir="ltr" className="py-2" value={qty[l.line_id] ?? ""} onChange={(e) => setQty((p) => ({ ...p, [l.line_id]: e.target.value }))} />
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
        <div className="mt-4 flex flex-col gap-3 sm:flex-row sm:items-end">
          <div className="min-w-0 flex-1">
            <Input placeholder="ملاحظة (اختياري) — مثلًا: نقص من المورد" value={note} onChange={(e) => setNote(e.target.value)} />
          </div>
          <Button type="button" disabled={pending} onClick={submit} className="w-full sm:w-auto">{pending ? "جارٍ التسجيل..." : `تأكيد ${verb}`}</Button>
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
