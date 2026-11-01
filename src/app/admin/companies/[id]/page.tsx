import Link from "next/link";
import { notFound } from "next/navigation";
import { Card } from "@/components/ui/card";
import { AdminHeader } from "@/components/admin/admin-header";
import { CompanyLicenseActions } from "@/components/admin/company-license-actions";
import { requireSuperAdminPage } from "@/lib/admin/auth.server";
import { createAdminClient } from "@/lib/supabase/admin";
import { fmtDate, paymentStatus, PKG_NAME, OPTION_NAME, ROLE_NAME, TONE } from "@/lib/admin/format";
import { formatMoney } from "@/lib/money";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
type Member = { user_id: string; email: string | null; name: string | null; role_key: string; role_name: string; status: string; joined_at: string };

export default async function CompanyDetail({ params }: { params: Promise<{ id: string }> }) {
  await requireSuperAdminPage();
  const { id } = await params;
  if (!UUID.test(id)) notFound();
  const admin = createAdminClient();
  const [org, members, lic, orders, wh, stateRes] = await Promise.all([
    admin.from("organizations").select("id, name, business_type, country, currency, created_at").eq("id", id).maybeSingle(),
    admin.rpc("admin_company_members", { p_org: id }),
    admin.from("organization_licenses").select("package_key, payment_option, complimentary, access_paid_through, licensed_at, entitlements").eq("organization_id", id).maybeSingle(),
    admin.from("billing_orders").select("id, status, purpose, package_key, payment_option, amount_total, created_at, paid_at, needs_review").eq("organization_id", id).order("created_at", { ascending: false }).limit(10),
    admin.from("warehouses").select("id, name, is_active").eq("organization_id", id),
    admin.rpc("billing_access_state", { p_org: id, p_at: new Date().toISOString() }),   // same batch: it only needs the id
  ]);
  if (!org.data) notFound();
  const o = org.data;
  const team = (members.data ?? []) as Member[];
  const license = lic.data;
  const owners = team.filter((m) => m.role_key === "owner" && m.status === "active");
  const accessState = (stateRes.data as { state?: string } | null)?.state ?? null;
  const st = paymentStatus({ package_key: license?.package_key ?? null, payment_option: license?.payment_option, complimentary: license?.complimentary, access_paid_through: license?.access_paid_through, access_state: accessState }, orders.data?.[0]?.status, { ownerless: owners.length === 0 });
  const warehouses = wh.data ?? [];
  const ent = license?.entitlements as { max_members: number | null; max_warehouses: number | null; modules: string[] } | undefined;
  return (
    <div>
      <AdminHeader title={o.name} subtitle={`سُجّلت في ${fmtDate(o.created_at)} — ${o.country} · ${o.currency}`} action={<Link href="/admin/companies" className="text-sm font-medium text-sage hover:underline">كل الشركات</Link>} />
      <div className="grid gap-4 lg:grid-cols-2">
        <Card className="p-5">
          <h2 className="mb-3 text-base font-semibold">الباقة والدفع</h2>
          <div className="mb-4"><span className={`inline-block px-2.5 py-1 text-xs font-medium ${TONE[st.tone]}`}>{st.text}</span></div>
          {license ? (
            <dl className="space-y-2 text-sm">
              <div className="flex justify-between gap-4"><dt className="text-charcoal/50">الباقة</dt><dd className="font-medium">{PKG_NAME[license.package_key] ?? license.package_key}</dd></div>
              <div className="flex justify-between gap-4"><dt className="text-charcoal/50">النوع</dt><dd>{license.complimentary ? "وصول مجاني من الإدارة" : OPTION_NAME[license.payment_option]}</dd></div>
              <div className="flex justify-between gap-4"><dt className="text-charcoal/50">مدفوعة حتى</dt><dd>{license.complimentary ? "بلا انتهاء" : license.access_paid_through ? fmtDate(license.access_paid_through) : "لم تُدفع"}</dd></div>
              <div className="flex justify-between gap-4"><dt className="text-charcoal/50">حد الفريق / المخازن</dt><dd>{ent ? `${ent.max_members ?? "بلا حد"} / ${ent.max_warehouses ?? "بلا حد"}` : "—"}</dd></div>
            </dl>
          ) : <p className="text-sm leading-6 text-charcoal/55">{owners.length === 0 ? "لا مالك لهذه الشركة (حُذف حسابه)، ولا يمكن لأحد الدخول إليها." : "لم تدفع الشركة بعد، فلا يمكن لمالكها ولا لفريقها فتح لوحة التحكم حتى يُكمل الدفع. يمكنك منحها وصولًا مجانيًا من الأسفل."}</p>}
          <div className="mt-5 border-t border-borderSoft pt-4">{<CompanyLicenseActions orgId={o.id} name={o.name} complimentary={!!license?.complimentary} hasPaidLicense={!!license && !license.complimentary} />}</div>
        </Card>
        <Card className="p-5">
          <h2 className="mb-3 text-base font-semibold">المخازن ({warehouses.filter((w) => w.is_active).length} نشطة)</h2>
          {warehouses.length === 0 ? <p className="text-sm text-charcoal/55">لا توجد مخازن.</p> : (
            <ul className="space-y-1.5 text-sm">{warehouses.map((w) => <li key={w.id} className="flex items-center justify-between"><span>{w.name}</span><span className="text-xs text-charcoal/45">{w.is_active ? "نشط" : "غير نشط"}</span></li>)}</ul>
          )}
        </Card>
      </div>
      <Card className="mt-4 overflow-hidden p-0 sm:p-0">
        <h2 className="border-b border-borderSoft px-5 py-4 text-base font-semibold">الفريق ({team.filter((m) => m.status === "active").length} نشط)</h2>
        <div className="overflow-x-auto"><table className="w-full min-w-[34rem] text-sm">
          <thead><tr className="text-xs text-charcoal/45"><th className="px-5 py-3 text-right font-medium">الاسم</th><th className="px-3 py-3 text-right font-medium">البريد</th><th className="px-3 py-3 text-right font-medium">الدور</th><th className="px-3 py-3 text-right font-medium">الحالة</th><th className="px-5 py-3 text-right font-medium">الانضمام</th></tr></thead>
          <tbody className="divide-y divide-borderSoft">{team.map((m) => (
            <tr key={m.user_id}><td className="px-5 py-3">{m.name ?? "—"}</td><td dir="ltr" className="px-3 py-3 text-right text-charcoal/65">{m.email}</td><td className="px-3 py-3">{ROLE_NAME[m.role_key] ?? m.role_name}</td><td className="px-3 py-3 text-xs">{m.status === "active" ? "نشط" : m.status === "invited" ? "دعوة معلّقة" : "معطّل"}</td><td className="px-5 py-3 text-charcoal/55">{fmtDate(m.joined_at)}</td></tr>
          ))}</tbody>
        </table></div>
      </Card>
      <Card className="mt-4 overflow-hidden p-0 sm:p-0">
        <h2 className="border-b border-borderSoft px-5 py-4 text-base font-semibold">آخر المدفوعات</h2>
        {(orders.data ?? []).length === 0 ? <p className="px-5 py-8 text-center text-sm text-charcoal/45">لا توجد مدفوعات.</p> : (
          <ul className="divide-y divide-borderSoft text-sm">{(orders.data ?? []).map((b) => (
            <li key={b.id} className="flex flex-wrap items-center justify-between gap-2 px-5 py-3"><span>{b.purpose === "renewal" ? "تجديد" : "شراء"} — {PKG_NAME[b.package_key] ?? b.package_key} ({OPTION_NAME[b.payment_option]})</span><span className="flex items-center gap-3"><span className="num font-medium">{formatMoney(b.amount_total / 100, 0)} ج.م</span><span className="text-xs text-charcoal/50">{{ paid: "مدفوع", pending: "بانتظار الدفع", failed: "فشل", expired: "انتهى", canceled: "ملغي" }[b.status as string] ?? b.status}{b.needs_review ? " · يحتاج مراجعة" : ""}</span><span className="text-xs text-charcoal/40">{fmtDate((b.paid_at ?? b.created_at) as string)}</span></span></li>
          ))}</ul>
        )}
      </Card>
    </div>
  );
}
