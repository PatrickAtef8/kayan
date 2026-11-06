import Link from "next/link";
import { Card } from "@/components/ui/card";
import { AdminHeader } from "@/components/admin/admin-header";
import { requireSuperAdminPage } from "@/lib/admin/auth.server";
import { createAdminClient } from "@/lib/supabase/admin";
import { fmtDate, paymentStatus, PKG_NAME, TONE } from "@/lib/admin/format";

const PAGE = 25;
type Row = { id: string; name: string; created_at: string; owner_id: string | null; owner_confirmed: boolean; access_state: string | null; owner_email: string | null; owner_name: string | null; reps: number; keepers: number; others: number; members: number; invited: number; warehouses: number; package_key: string | null; payment_option: string | null; complimentary: boolean | null; access_paid_through: string | null; last_order_status: string | null };

export default async function CompaniesPage({ searchParams }: { searchParams: Promise<{ q?: string; page?: string }> }) {
  await requireSuperAdminPage();
  const sp = await searchParams;
  const q = (sp.q ?? "").slice(0, 100);
  const page = Math.max(1, Number.parseInt(sp.page ?? "1", 10) || 1);
  const { data, error } = await createAdminClient().rpc("admin_companies_overview", { p_search: q, p_limit: PAGE, p_offset: (page - 1) * PAGE });
  const result = (data ?? { total: 0, rows: [] }) as { total: number; rows: Row[] };
  const pages = Math.max(1, Math.ceil(result.total / PAGE));
  const href = (p: number) => `/admin/companies?${new URLSearchParams({ ...(q ? { q } : {}), page: String(p) })}`;
  return (
    <div>
      <AdminHeader title="الشركات" subtitle="كل الشركات المسجلة، ومالكها، وحجم فريقها، وباقتها وحالة دفعها." />
      <form className="mb-4 flex gap-2" role="search">
        <input name="q" defaultValue={q} placeholder="ابحث باسم الشركة أو بريد المالك" className="min-w-0 flex-1 rounded-xl border border-borderSoft bg-white px-4 py-2.5 text-sm outline-none focus:border-sage focus:ring-2 focus:ring-sage/20" />
        <button className="rounded-xl bg-charcoal px-5 py-2.5 text-sm font-medium text-ivory hover:bg-sage">بحث</button>
      </form>
      {error ? <Card className="p-5 text-sm text-rose">تعذّر تحميل الشركات.</Card> : (
        <Card className="overflow-hidden p-0 sm:p-0">
          <div className="overflow-x-auto">
            <table className="w-full min-w-[60rem] text-sm">
              <thead><tr className="text-xs text-charcoal/45">{["الشركة", "المالك", "التسجيل", "مناديب", "أمناء مخازن", "آخرون", "المخازن", "الباقة", "الدفع"].map((h) => <th key={h} className="px-3 py-3 text-right font-medium first:px-5">{h}</th>)}</tr></thead>
              <tbody className="divide-y divide-borderSoft">
                {result.rows.length === 0 && <tr><td colSpan={9} className="px-5 py-10 text-center text-charcoal/45">لا توجد نتائج.</td></tr>}
                {result.rows.map((r) => {
                  const st = paymentStatus(r, r.last_order_status, { ownerless: !r.owner_id });
                  return (
                    <tr key={r.id} className="hover:bg-paper/60">
                      <td className="px-5 py-3 font-medium"><Link href={`/admin/companies/${r.id}`} className="text-charcoal hover:text-sage hover:underline">{r.name}</Link></td>
                      <td className="px-3 py-3 text-charcoal/70"><span className="block">{r.owner_name ?? "—"}</span><span dir="ltr" className="block text-xs text-charcoal/45">{r.owner_email ?? ""}</span></td>
                      <td className="px-3 py-3 text-charcoal/60">{fmtDate(r.created_at)}</td>
                      <td className="num px-3 py-3">{r.reps}</td><td className="num px-3 py-3">{r.keepers}</td><td className="num px-3 py-3">{r.others}</td><td className="num px-3 py-3">{r.warehouses}</td>
                      <td className="px-3 py-3 text-charcoal/70">{r.package_key ? <>{PKG_NAME[r.package_key] ?? r.package_key}{r.complimentary ? <span className="block text-xs text-charcoal/40">مجانية</span> : null}</> : "—"}</td>
                      <td className="px-3 py-3"><span className={`inline-block px-2 py-0.5 text-xs font-medium ${TONE[st.tone]}`}>{st.text}</span></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          <div className="flex items-center justify-between border-t border-borderSoft px-5 py-3 text-xs text-charcoal/50">
            <span>{result.total} شركة</span>
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
