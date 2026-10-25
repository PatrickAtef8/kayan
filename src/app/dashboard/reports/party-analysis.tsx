import { Money } from "@/components/ui/money";
import { formatMoney } from "@/lib/money";
import Link from "next/link";
import { Card } from "@/components/ui/card";
import { NoteForm } from "./note-form";

export const money = (n: number | null | undefined) => formatMoney(n);

const STATUS: Record<string, string> = { paid: "مدفوعة", partial: "مدفوعة جزئيًا", unpaid: "آجلة" };

export function Stat({ label, value, tone }: { label: string; value: React.ReactNode; tone?: "rose" | "sage" }) {
  return (
    <Card className="p-4">
      <p className="text-xs text-charcoal/50">{label}</p>
      <p className={`mt-1 text-lg font-semibold tracking-tight ${tone === "rose" ? "text-rose" : tone === "sage" ? "text-sage" : "text-charcoal"}`} dir="ltr">
        {value}
      </p>
    </Card>
  );
}

export function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="mt-8">
      <h2 className="mb-3 text-sm font-semibold text-charcoal">{title}</h2>
      {children}
    </section>
  );
}

export function SimpleTable({ head, rows, empty }: { head: string[]; rows: React.ReactNode[][]; empty: string }) {
  if (rows.length === 0) return <div className="rounded-2xl border border-dashed border-borderSoft bg-white p-8 text-center text-sm text-charcoal/45">{empty}</div>;
  return (
    <div className="overflow-hidden rounded-2xl border border-borderSoft/80 bg-white">
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-borderSoft/80 bg-paper/50 text-charcoal/40">
              {head.map((h) => (
                <th key={h} className="whitespace-nowrap px-4 py-3 text-right text-[0.6875rem] font-medium">{h}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={i} className="border-b border-borderSoft/60 last:border-0">
                {r.map((c, j) => (
                  <td key={j} className="whitespace-nowrap px-4 py-3 text-charcoal">{c}</td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

type Item = { product: string; quantity: number; bonus_quantity: number; is_bonus: boolean; discount: number; allocated_discount: number; net_total: number; unit_price?: number; unit_cost?: number; effective_unit_price?: number; effective_unit_cost?: number };
export type AnalysisInvoice = {
  id: string; invoice_number: string | null; invoice_date: string; payment_method: string | null; payment_status: string;
  subtotal: number; line_discount: number; invoice_discount: number; cash_discount: number; tier_discount: number; discount_total: number;
  total: number; amount_paid: number; bonus_units: number; notes: string | null; items: Item[];
};
export type AnalysisNote = { id: string; note: string; created_at: string; invoice_id?: string | null };

export function InvoiceList({ invoices, kind, notes = [], partyId }: { invoices: AnalysisInvoice[]; kind: "sales" | "purchases"; notes?: AnalysisNote[]; partyId?: string }) {
  if (invoices.length === 0) return <div className="rounded-2xl border border-dashed border-borderSoft bg-white p-8 text-center text-sm text-charcoal/45">لا توجد فواتير</div>;
  return (
    <div className="space-y-3">
      {invoices.map((inv) => (
        <details key={inv.id} className="group rounded-2xl border border-borderSoft/80 bg-white">
          <summary className="flex cursor-pointer flex-wrap items-center justify-between gap-3 px-5 py-4 text-sm">
            <span className="font-medium text-charcoal">{inv.invoice_number ?? "بدون رقم"} <span className="mr-2 text-xs text-charcoal/40" dir="ltr">{inv.invoice_date}</span></span>
            <span className="flex flex-wrap items-center gap-4 text-xs text-charcoal/60">
              <span>{inv.payment_method ?? "—"}</span>
              <span>{STATUS[inv.payment_status] ?? inv.payment_status}</span>
              {inv.discount_total > 0 && <span>خصومات: {money(inv.discount_total)}</span>}
              {inv.bonus_units > 0 && <span>Bonus: {inv.bonus_units}</span>}
              <span className="text-sm font-semibold text-charcoal" dir="ltr"><Money value={inv.total} /></span>
            </span>
          </summary>
          <div className="border-t border-borderSoft/60 px-5 py-4">
            <SimpleTable
              empty=""
              head={["الصنف", "الكمية", "Bonus", kind === "sales" ? "سعر القطعة" : "تكلفة القطعة", "خصم الصنف", "حصة من خصم الفاتورة", "الصافي", "السعر الفعلي للقطعة"]}
              rows={inv.items.map((it) => [
                <>{it.product}{it.is_bonus && <span className="mr-2 rounded bg-sageSoft/50 px-1.5 py-0.5 text-[0.65rem] text-sage">Bonus</span>}</>,
                it.quantity, it.bonus_quantity || "—",
                money(kind === "sales" ? it.unit_price : it.unit_cost), money(it.discount), money(it.allocated_discount), money(it.net_total),
                money(kind === "sales" ? it.effective_unit_price : it.effective_unit_cost),
              ])}
            />
            <div className="mt-3 grid grid-cols-2 gap-x-6 gap-y-1 text-xs text-charcoal/60 sm:grid-cols-4">
              <span>خصم الأصناف: {money(inv.line_discount)}</span>
              <span>خصم الفاتورة: {money(inv.invoice_discount)}</span>
              <span>خصم الشريحة: {money(inv.tier_discount)}</span>
              <span>خصم دفع فوري: {money(inv.cash_discount)}</span>
              <span>المدفوع: {money(inv.amount_paid)}</span>
              {inv.notes && <span className="col-span-2">ملاحظات: {inv.notes}</span>}
            </div>
            {kind === "sales" && partyId && (
              <div className="mt-4 space-y-2 border-t border-borderSoft/60 pt-3">
                {notes.filter((n) => n.invoice_id === inv.id).map((n) => (
                  <p key={n.id} className="rounded-lg bg-paper/60 px-3 py-2 text-xs text-charcoal">{n.note}</p>
                ))}
                <NoteForm partyType="customer" partyId={partyId} invoiceId={inv.id} compact />
              </div>
            )}
          </div>
        </details>
      ))}
    </div>
  );
}

type Ret = { id: string; date: string; total: number; cash_refunded: number; invoice_number: string | null; notes: string | null; items: { product: string; quantity: number; amount: number }[] };
type Pay = { id: string; date: string; amount: number; payment_method: string | null; reference: string | null; invoice_number: string | null; notes: string | null };
type Note = AnalysisNote;

export function PaymentsReturnsNotes({ payments, returns, notes, party }: { payments: Pay[]; returns: Ret[]; notes: Note[]; party: { type: "customer" | "supplier"; id: string } }) {
  return (
    <>
      <Section title={`المدفوعات (${payments.length})`}>
        <SimpleTable empty="لا توجد مدفوعات" head={["التاريخ", "المبلغ", "الطريقة", "الفاتورة", "مرجع", "ملاحظات"]}
          rows={payments.map((p) => [<span dir="ltr" key="d">{p.date}</span>, <Money value={p.amount} suffix="" key="a" />, p.payment_method ?? "—", p.invoice_number ?? "—", p.reference ?? "—", p.notes ?? "—"])} />
      </Section>
      <Section title={`المرتجعات (${returns.length})`}>
        <SimpleTable empty="لا توجد مرتجعات" head={["التاريخ", "الفاتورة", "الأصناف", "القيمة", "استرجاع نقدي"]}
          rows={returns.map((r) => [<span dir="ltr" key="d">{r.date}</span>, r.invoice_number ?? "—", r.items.map((i) => `${i.quantity} × ${i.product}`).join("، "), <Money value={r.total} suffix="" key="t" />, <Money value={r.cash_refunded} suffix="" key="c" />])} />
      </Section>
      <Section title={`الملاحظات (${notes.length}) — للتوثيق فقط ولا تدخل في أي حسابات`}>
        <NoteForm partyType={party.type} partyId={party.id} />
        <div className="mt-3 space-y-2">
          {notes.filter((n) => !n.invoice_id).map((n) => (
            <div key={n.id} className="rounded-xl border border-borderSoft/70 bg-white px-4 py-3 text-sm">
              <p className="text-charcoal">{n.note}</p>
              <p className="mt-1 text-[0.7rem] text-charcoal/40" dir="ltr">{new Date(n.created_at).toLocaleString("ar-EG")}</p>
            </div>
          ))}
        </div>
      </Section>
    </>
  );
}

export function BackLink({ href, label }: { href: string; label: string }) {
  return <Link href={href} className="mb-5 inline-block text-xs text-sage hover:underline">← {label}</Link>;
}
