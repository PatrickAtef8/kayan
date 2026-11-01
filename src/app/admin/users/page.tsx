import Link from "next/link";
import { Card } from "@/components/ui/card";
import { AdminHeader } from "@/components/admin/admin-header";
import { UserActions } from "@/components/admin/user-actions";
import { requireSuperAdminPage, isSuperAdminUser } from "@/lib/admin/auth.server";
import { createAdminClient } from "@/lib/supabase/admin";
import { fmtDate, ROLE_NAME } from "@/lib/admin/format";

const PAGE = 25;
type Membership = { org_id: string; org_name: string; role_key: string; status: string };
type UserRow = { id: string; email: string | null; created_at: string; last_sign_in_at: string | null; email_confirmed_at: string | null; banned_until: string | null; memberships: Membership[] };

export default async function UsersPage({ searchParams }: { searchParams: Promise<{ q?: string; page?: string }> }) {
  const me = await requireSuperAdminPage();
  const sp = await searchParams;
  const q = (sp.q ?? "").trim().toLowerCase().slice(0, 100);
  const page = Math.max(1, Number.parseInt(sp.page ?? "1", 10) || 1);
  const admin = createAdminClient();

  // ONE database call: search + page + memberships (admin_users_page, migration 0068). Before: up to five Auth-API requests in a row
  // for a search (capped at the first 1,000 accounts) plus a second call for the memberships.
  const { data, error } = await admin.rpc("admin_users_page", { p_search: q, p_limit: PAGE, p_offset: (page - 1) * PAGE });
  const result = (error || !data ? { total: 0, rows: [] } : data) as { total: number; rows: UserRow[] };
  const users = result.rows;
  const total: number | null = result.total;
  const hasNext = total !== null ? page * PAGE < total : users.length === PAGE;
  const href = (p: number) => `/admin/users?${new URLSearchParams({ ...(q ? { q } : {}), page: String(p) })}`;
  return (
    <div>
      <AdminHeader title="المستخدمون" subtitle="كل الحسابات المسجلة. للمدير تعطيل أو حذف أي حساب، حتى لو كان عضوًا في شركة. التعطيل يمنع الدخول ويمكن التراجع عنه، أما الحذف فنهائي. الاستثناء الوحيد حسابك أنت." />
      <form className="mb-4 flex gap-2" role="search">
        <input name="q" defaultValue={q} placeholder="ابحث بالبريد الإلكتروني" dir="ltr" className="min-w-0 flex-1 rounded-xl border border-borderSoft bg-white px-4 py-2.5 text-sm outline-none focus:border-sage focus:ring-2 focus:ring-sage/20" />
        <button className="rounded-xl bg-charcoal px-5 py-2.5 text-sm font-medium text-ivory hover:bg-sage">بحث</button>
      </form>
      {error && <p className="mb-3 text-xs text-rose">تعذّر تحميل المستخدمين. تأكّد من تطبيق ترحيل قاعدة البيانات 0068.</p>}
      <Card className="overflow-hidden p-0 sm:p-0">
        <div className="overflow-x-auto"><table className="w-full min-w-[52rem] text-sm">
          <thead><tr className="text-xs text-charcoal/45"><th className="px-5 py-3 text-right font-medium">المستخدم</th><th className="px-3 py-3 text-right font-medium">الشركات والأدوار</th><th className="px-3 py-3 text-right font-medium">التسجيل</th><th className="px-3 py-3 text-right font-medium">آخر دخول</th><th className="px-3 py-3 text-right font-medium">الحالة</th><th className="px-5 py-3 text-right font-medium">إجراء</th></tr></thead>
          <tbody className="divide-y divide-borderSoft">
            {users.length === 0 && <tr><td colSpan={6} className="px-5 py-10 text-center text-charcoal/45">لا توجد نتائج.</td></tr>}
            {users.map((u) => {
              const ms = u.memberships ?? [];
              const deactivated = !!u.banned_until && new Date(u.banned_until) > new Date();
              const joined = ms.some((m) => m.status !== "invited");
              return (
                <tr key={u.id} className="align-top">
                  <td className="px-5 py-3"><span dir="ltr" className="block text-right font-medium">{u.email ?? "—"}</span>{isSuperAdminUser(u) && <span className="mt-0.5 inline-block bg-charcoal px-2 py-0.5 text-[0.6875rem] font-medium text-ivory">مدير منصة</span>}{!u.email_confirmed_at && <span className="block text-xs text-amber-800">البريد غير مؤكد</span>}</td>
                  <td className="px-3 py-3 text-charcoal/70">{ms.length === 0 ? <span className="text-charcoal/40">بلا شركة</span> : ms.map((m) => <Link key={m.org_id} href={`/admin/companies/${m.org_id}`} className="block hover:text-sage hover:underline">{m.org_name} — {ROLE_NAME[m.role_key] ?? m.role_key}{m.status !== "active" ? ` (${m.status === "invited" ? "دعوة" : "معطّل"})` : ""}</Link>)}</td>
                  <td className="px-3 py-3 text-charcoal/60">{fmtDate(u.created_at)}</td>
                  <td className="px-3 py-3 text-charcoal/60">{fmtDate(u.last_sign_in_at)}</td>
                  <td className="px-3 py-3"><span className={`inline-block px-2 py-0.5 text-xs font-medium ${deactivated ? "bg-rose/10 text-rose" : "bg-sageSoft text-sage"}`}>{deactivated ? "معطّل" : "نشط"}</span></td>
                  <td className="px-5 py-3"><UserActions userId={u.id} email={u.email ?? u.id} deactivated={deactivated} isSelf={u.id === me.id} hasCompanies={joined} /></td>
                </tr>
              );
            })}
          </tbody>
        </table></div>
        <div className="flex items-center justify-between border-t border-borderSoft px-5 py-3 text-xs text-charcoal/50">
          <span>{total !== null ? `${total} مستخدم` : ""}</span>
          <span className="flex items-center gap-3">{page > 1 && <Link href={href(page - 1)} className="font-medium text-charcoal hover:underline">السابق</Link>}<span>صفحة {page}</span>{hasNext && <Link href={href(page + 1)} className="font-medium text-charcoal hover:underline">التالي</Link>}</span>
        </div>
      </Card>
    </div>
  );
}
