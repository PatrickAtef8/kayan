import Link from "next/link";
import { Card } from "@/components/ui/card";
import { AdminHeader } from "@/components/admin/admin-header";
import { requireSuperAdminPage } from "@/lib/admin/auth.server";
import { createAdminClient } from "@/lib/supabase/admin";
import { fmtDate, PKG_NAME, OPTION_NAME } from "@/lib/admin/format";
import { STATUS_LABEL, PURPOSE_LABEL } from "@/lib/billing/labels";

// Payments that arrived but need a human (amount mismatch, a second payment for an existing licence…), across ALL companies.
// Authorization: requireSuperAdminPage() — anyone else gets a 404 before a single row is read. Reads use the service role because
// these rows belong to many companies; the page is read-only (nothing here can change an order).
const PAGE = 25;
type Row = { id: string; organization_id: string; status: string; purpose: string; package_key: string; payment_option: string; amount_total: number; review_note: string | null; failure_reason: string | null; created_at: string; paid_at: string | null; organizations: { name: string } | { name: string }[] | null };

export default async function ReviewPage({ searchParams }: { searchParams: Promise<{ page?: string }> }) {
  await requireSuperAdminPage();
  const sp = await searchParams;
  const page = Math.max(1, Math.min(10000, Number.parseInt(sp.page ?? "1", 10) || 1));
  const { data, count, error } = await createAdminClient()
    .from("billing_orders")
    .select("id, organization_id, status, purpose, package_key, payment_option, amount_total, review_note, failure_reason, created_at, paid_at, organizations(name)", { count: "exact" })
    .eq("needs_review", true)
    .order("created_at", { ascending: false })
    .range((page - 1) * PAGE, page * PAGE - 1);
  const rows = (data ?? []) as unknown as Row[];
  const total = count ?? 0;
  const pages = Math.max(1, Math.ceil(total / PAGE));
  const href = (p: number) => `/admin/review?page=${p}`;
  const orgName = (r: Row) => (Array.isArray(r.organizations) ? r.organizations[0]?.name : r.organizations?.name) ?? "—";
  return (
    <div>
      <AdminHeader title="مدفوعات تحتاج مراجعة" subtitle="دفعات وصلت لكنها لا تتطابق تمامًا مع الطلب (مبلغ مختلف، دفعة ثانية…). لم يُمنح أي شيء مرتين ولم يضع أي مبلغ. راجعها مع لوحة XPay." />
      {error ? <Card className="p-5 text-sm text-rose">تعذّر تحميل القائمة.</Card> : (
        <Card className="overflow-hidden p-0 sm:p-0">
          <div className="overflow-x-auto">
            <table className="w-full min-w-[56rem] text-sm">
              <thead><tr className="text-xs text-charcoal/45">{["الشركة", "الطلب", "المبلغ", "الحالة", "سبب المراجعة", "التاريخ"].map((h) => <th key={h} className="px-3 py-3 text-start font-medium first:px-5">{h}</th>)}</tr></thead>
              <tbody className="divide-y divide-borderSoft">
                {rows.length === 0 && <tr><td colSpan={6} className="px-5 py-10 text-center text-charcoal/45">لا توجد مدفوعات تحتاج مراجعة.</td></tr>}
                {rows.map((r) => (
                  <tr key={r.id} className="hover:bg-paper/60">
                    <td className="px-5 py-3 font-medium"><Link href={`/admin/companies/${r.organization_id}`} className="hover:text-sage hover:underline">{orgName(r)}</Link></td>
                    <td className="px-3 py-3 text-charcoal/70">{PURPOSE_LABEL[r.purpose] ?? r.purpose} — {PKG_NAME[r.package_key] ?? r.package_key} ({OPTION_NAME[r.payment_option] ?? r.payment_option})<span dir="ltr" className="block text-xs text-charcoal/40">{r.id.slice(0, 8).toUpperCase()}</span></td>
                    <td className="num px-3 py-3">{(r.amount_total / 100).toLocaleString("en-US", { maximumFractionDigits: 2 })} ج.م</td>
                    <td className="px-3 py-3">{STATUS_LABEL[r.status] ?? r.status}</td>
                    <td className="px-3 py-3 text-charcoal/70">{r.review_note ?? r.failure_reason ?? "—"}</td>
                    <td className="px-3 py-3 text-charcoal/60">{fmtDate(r.paid_at ?? r.created_at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="flex items-center justify-between border-t border-borderSoft px-5 py-3 text-xs text-charcoal/50">
            <span>{total} طلب</span>
            <span className="flex items-center gap-3">
              {page > 1 && <Link href={href(page - 1)} className="font-medium text-charcoal hover:underline">السابق</Link>}
              <span>صفحة {page} من {pages}</span>
              {page < pages && <Link href={href(page + 1)} className="font-medium text-charcoal hover:underline">التالي</Link>}
            </span>
          </div>
        </Card>
      )}
    </div>
  );
}
