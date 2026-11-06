import Link from "next/link";
import { Card } from "@/components/ui/card";
import { AdminHeader } from "@/components/admin/admin-header";
import { requireSuperAdminPage, configuredAdmins } from "@/lib/admin/auth.server";
import { createAdminClient } from "@/lib/supabase/admin";
import { loadPricingConfig } from "@/lib/billing/config";
import { fmtDate, ADMIN_ACTION_LABEL } from "@/lib/admin/format";
import { billingReadiness } from "@/lib/billing/xpay.server";
import { loadEmailConfig, describeConfigProblem } from "@/lib/email/config";

export default async function AdminHome() {
  await requireSuperAdminPage();
  const admin = createAdminClient();
  const admins = configuredAdmins();
  const readiness = billingReadiness();
  const mail = loadEmailConfig();
  const [stats, pricing, audit, unpaid, review, trials] = await Promise.all([
    // ONE query for the four counters (companies, users, paid, free). Before: the companies function, an Auth-API call and a download
    // of every license row. If it fails the cards show «—», never a silent 0.
    admin.rpc("admin_overview_stats"),
    loadPricingConfig(admin),
    admin.from("admin_audit_log").select("action, created_at, details").order("created_at", { ascending: false }).limit(8),
    admin.rpc("admin_unpaid_company_count", { p_exclude_users: admins.ids, p_exclude_emails: admins.emails }),
    admin.from("billing_orders").select("id", { count: "exact", head: true }).eq("needs_review", true),
    admin.rpc("admin_trial_stats"),
  ]);
  const tr = (trials.error ? null : trials.data) as { active?: number; expired?: number } | null;
  const s = (stats.error ? null : stats.data) as { companies?: number; users?: number; paid?: number; complimentary?: number } | null;
  const num = (v: number | undefined) => (s && typeof v === "number" ? v : "—");
  const stat = (label: string, value: string | number, href?: string) => (
    <Card key={label} className="p-5">
      <p className="text-xs text-charcoal/45">{label}</p>
      <p className="num mt-2 text-3xl font-semibold tracking-tight">{value}</p>
      {href ? <Link href={href} className="mt-3 inline-block text-xs font-medium text-sage hover:underline">عرض</Link> : null}
    </Card>
  );
  return (
    <div>
      <AdminHeader title="نظرة عامة" subtitle="صورة سريعة عن المنصة. التعديلات من صفحات الشركات والمستخدمين والباقات." />
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6">
        {stat("الشركات", num(s?.companies), "/admin/companies")}
        {stat("المستخدمون", num(s?.users), "/admin/users")}
        {stat("شركات دفعت", num(s?.paid))}
        {stat("بانتظار الدفع", typeof unpaid.data === "number" ? unpaid.data : "—", "/admin/companies")}
        {stat("وصول مجاني", num(s?.complimentary))}
        {stat("في تجربة مجانية", tr && typeof tr.active === "number" ? tr.active : "—", "/admin/companies")}
      </div>
      <Card className="mt-4 p-5">
        <p className="text-sm font-medium">جاهزية الإنتاج</p>
        <ul className="mt-2 space-y-1 text-xs text-charcoal/70">
          <li>مدفوعات تحتاج مراجعة: <b className="num">{review.error ? "—" : review.count ?? 0}</b> {(review.count ?? 0) > 0 && <Link href="/admin/review" className="font-medium text-sage hover:underline">عرض</Link>}</li>
          <li>XPay: {readiness.mode === "unset" ? "غير مضبوط" : readiness.mode === "live" ? "مفتاح حقيقي (live)" : "مفتاح تجريبي (test)"}{readiness.blocking.length > 0 ? <span className="text-rose"> — يمنع الدفع: {readiness.blocking.join(" ")}</span> : <span className="text-sage"> — لا موانع</span>}</li>
          {readiness.warnings.map((w) => <li key={w} className="text-amber-700">{w}</li>)}
          <li>البريد (Resend): {mail.ok ? <span className="text-sage">مضبوط{mail.config.testingSender ? " — مرسل اختبار: يصل فقط لبريد حساب Resend" : ""}</span> : <span className="text-rose">{describeConfigProblem(mail.problem)}</span>}</li>
        </ul>
      </Card>
      <Card className="mt-4 flex flex-col gap-2 p-5 sm:flex-row sm:items-center sm:justify-between">
        <p className="text-sm text-charcoal/70">إعدادات الباقات الحالية: <span className="font-medium text-charcoal">{pricing.custom ? `معدّلة (آخر تعديل ${fmtDate(pricing.updatedAt)})` : "الإعدادات الأصلية كما شُحنت"}</span></p>
        <Link href="/admin/packages" className="text-sm font-medium text-sage hover:underline">الباقات والأسعار</Link>
      </Card>
      <Card className="mt-4 overflow-hidden p-0 sm:p-0">
        <h2 className="border-b border-borderSoft px-5 py-4 text-base font-semibold">آخر عمليات الإدارة</h2>
        {(audit.data ?? []).length === 0 ? <p className="px-5 py-8 text-center text-sm text-charcoal/45">لا توجد عمليات بعد.</p> : (
          <ul className="divide-y divide-borderSoft text-sm">
            {(audit.data ?? []).map((a, i) => <li key={i} className="flex items-center justify-between gap-3 px-5 py-3"><span className="text-sm text-charcoal/75">{ADMIN_ACTION_LABEL[a.action as string] ?? a.action}</span><span className="text-xs text-charcoal/45">{fmtDate(a.created_at as string)}</span></li>)}
          </ul>
        )}
      </Card>
    </div>
  );
}
