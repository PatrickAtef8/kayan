"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { ShoppingCart } from "lucide-react";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { setShortageStatus } from "./actions";

export type LinkedInvoice = { purchase_invoice_id: string; invoice_number: string | null; invoice_date: string; receipt_status: string };
const RECEIPT_LABEL: Record<string, string> = { pending: "بانتظار الاستلام", partial: "استلام جزئي", received: "تم الاستلام", cancelled: "ملغاة" };

export type ShortageReport = {
  id: string; product_id: string; warehouse_id: string; product_name: string; unit: string; warehouse_name: string; rep_name: string;
  available_qty: number; needed_qty: number; note: string | null; status: string; owner_note: string | null;
  created_at: string; status_changed_at: string | null; superseded: boolean; mine: boolean;
  current_available: number | null; incoming_qty: number | null; remaining_qty: number | null; // live figures (the owner sees all three, a rep only the first)
};

export const STATUS_LABEL: Record<string, string> = { new: "جديد", in_progress: "جاري التجهيز", resolved: "تم توفير الصنف" };
const STATUS_STYLE: Record<string, string> = {
  new: "bg-rose/10 text-rose",
  in_progress: "bg-brass/15 text-brass",
  resolved: "bg-sageSoft text-sage",
};

const fmt = (n: number) => Number(n).toLocaleString("en-US", { maximumFractionDigits: 3 });
const fmtDate = (d: string) => new Date(d).toLocaleString("ar-EG", { dateStyle: "medium", timeStyle: "short" });

export function ReportRow({ report, canManage, links = [] }: { report: ShortageReport; canManage: boolean; links?: LinkedInvoice[] }) {
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const [confirmingResolve, setConfirmingResolve] = useState(false);

  function change(status: "new" | "in_progress" | "resolved") {
    setError(null);
    startTransition(async () => {
      const r = await setShortageStatus({ reportId: report.id, status, note });
      if (r.error) setError(r.error);
      else setNote("");
    });
  }

  const shortfall = Math.max(report.needed_qty - report.available_qty, 0);
  // The normal way to cover a shortage: buy it. The purchase form opens with this product already chosen.
  const purchaseHref = `/dashboard/purchases?${new URLSearchParams({
    shortage: report.id,
    product: report.product_id,
    warehouse: report.warehouse_id,
    qty: String(Math.round((report.remaining_qty != null && report.remaining_qty > 0 ? report.remaining_qty : shortfall) * 1000) / 1000),
  }).toString()}`;
  return (
    <div className={`rounded-xl border border-borderSoft bg-white p-4 ${report.superseded ? "opacity-60" : ""}`}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="text-sm font-semibold text-charcoal">{report.product_name} <span className="text-xs font-normal text-charcoal/45">— {report.warehouse_name}</span></div>
          <div className="mt-1 text-xs text-charcoal/55">
            المطلوب <b dir="ltr">{fmt(report.needed_qty)}</b> {report.unit} · المتاح وقت البلاغ <b dir="ltr">{fmt(report.available_qty)}</b> · العجز <b dir="ltr">{fmt(shortfall)}</b>
          </div>
          {report.current_available != null && (
            <div className="mt-1 text-xs text-charcoal/55">
              الآن: المتاح للبيع <b dir="ltr">{fmt(report.current_available)}</b>
              {report.incoming_qty != null && <> · في الطريق <b dir="ltr">{fmt(report.incoming_qty)}</b></>}
              {report.remaining_qty != null && (
                <> · المتبقي <b dir="ltr" className={report.remaining_qty > 0 ? "text-rose" : "text-sage"}>{fmt(report.remaining_qty)}</b>{report.remaining_qty === 0 ? " (مغطّى)" : ""}</>
              )}
            </div>
          )}
          <div className="mt-1 text-xs text-charcoal/45">المندوب: {report.rep_name} · {fmtDate(report.created_at)}</div>
          {report.note && <div className="mt-1 text-xs text-charcoal/60">ملاحظة المندوب: {report.note}</div>}
          {report.owner_note && <div className="mt-1 text-xs text-sage">رد المالك: {report.owner_note}</div>}
          {canManage && links.length > 0 && (
            <div className="mt-1 text-xs text-charcoal/60">
              فواتير الشراء المرتبطة:{" "}
              {links.map((l, i) => (
                <span key={l.purchase_invoice_id}>
                  {i > 0 && "، "}
                  <Link href={`/dashboard/purchases?inv=${encodeURIComponent(l.purchase_invoice_id)}`} className="text-sage underline-offset-2 hover:underline">{l.invoice_number || l.invoice_date}</Link>
                  <span className="text-charcoal/45"> ({RECEIPT_LABEL[l.receipt_status] ?? l.receipt_status})</span>
                </span>
              ))}
            </div>
          )}
        </div>
        <div className="flex flex-col items-end gap-1">
          <span className={`rounded-full px-2.5 py-1 text-xs font-medium ${STATUS_STYLE[report.status] ?? ""}`}>{STATUS_LABEL[report.status] ?? report.status}</span>
          {report.superseded && <span className="text-[0.6875rem] text-charcoal/45">استُبدل ببلاغ أحدث</span>}
        </div>
      </div>
      {canManage && !report.superseded && (
        <div className="mt-3 flex flex-wrap items-center gap-2 border-t border-borderSoft pt-3">
          {report.status !== "resolved" && (
            <Link href={purchaseHref} className="inline-flex items-center gap-1.5 rounded-lg bg-sage px-3 py-2 text-xs font-medium text-white hover:opacity-90">
              <ShoppingCart size={14} strokeWidth={2} /> إنشاء فاتورة مشتريات
            </Link>
          )}
          <input value={note} onChange={(e) => setNote(e.target.value)} maxLength={500} placeholder="ملاحظة للمندوب (اختياري)" className="h-9 min-w-[12rem] flex-1 rounded-lg border border-borderSoft px-3 text-xs focus:border-sage focus:outline-none" />
          {report.status === "new" && (
            <button type="button" disabled={pending} onClick={() => change("in_progress")} className="rounded-lg bg-paper px-3 py-2 text-xs font-medium text-charcoal/70 hover:bg-sageSoft hover:text-sage disabled:opacity-50">جاري التجهيز</button>
          )}
          {report.status !== "new" && (
            <button type="button" disabled={pending} onClick={() => change("new")} className="rounded-lg bg-paper px-3 py-2 text-xs font-medium text-charcoal/70 hover:bg-sageSoft hover:text-sage disabled:opacity-50">إعادة فتح</button>
          )}
          {report.status !== "resolved" && (
            <button type="button" disabled={pending} onClick={() => setConfirmingResolve(true)} className="rounded-lg px-3 py-2 text-xs text-charcoal/45 hover:bg-paper hover:text-charcoal/70 disabled:opacity-50">تم توفيره من مصدر آخر</button>
          )}
          {error && <span className="w-full text-xs text-rose">{error}</span>}
        </div>
      )}
      <ConfirmDialog
        open={confirmingResolve}
        title="إغلاق البلاغ بدون فاتورة مشتريات؟"
        description="استخدم هذا الخيار فقط لو الكمية وصلت فعلًا للمخزن من مصدر آخر (مثل تحويل من مخزن). سيتحقق النظام أن المتاح للبيع (بعد خصم المحجوز لفواتير بيع مفتوحة) يغطي الكمية المطلوبة، وإلا لن يُغلق البلاغ. لو هتشتريه من مورد، أنشئ فاتورة مشتريات وسيُغلق البلاغ تلقائيًا بعد استلام أمين المخزن للكمية."
        confirmLabel="نعم، تم توفيره"
        loading={pending}
        error={error}
        onConfirm={() => { change("resolved"); setConfirmingResolve(false); }}
        onCancel={() => setConfirmingResolve(false)}
      />
    </div>
  );
}
