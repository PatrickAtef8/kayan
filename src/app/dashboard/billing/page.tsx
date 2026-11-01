import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { PricingExperience } from "@/components/pricing/pricing-experience";
import { getMembership, getSupabase, getOrgAccess } from "@/lib/org-context";
import { createAdminClient } from "@/lib/supabase/admin";
import { PRICING_CONFIG } from "@/config/pricing.config";
import { loadPricingConfig } from "@/lib/billing/config";
import { buildQuote, describeFitViolations, getPackage, getPackages, isPaymentOption, type FitViolation, type PricingConfig } from "@/lib/billing/pricing";
import { selectionFromMetadata } from "@/lib/billing/selection";
import { daysUntil, parseDbAccess, type AccessState } from "@/lib/billing/license-status";
import { STATUS_LABEL, PURPOSE_LABEL, OPTION_LABEL } from "@/lib/billing/labels";
import { pricesConfirmed, xpayIsConfigured, xpayIsTestMode } from "@/lib/billing/xpay.server";
import { formatMoney } from "@/lib/money";
import { CalendarClock, CircleCheck, ShieldCheck, TriangleAlert } from "lucide-react";
import Link from "next/link";
import { getCurrentUser } from "@/lib/org-context";
import { isSuperAdminSession } from "@/lib/admin/auth.server";

const baseCfg = PRICING_CONFIG as PricingConfig;
const date = (iso: string | null) => (iso ? new Intl.DateTimeFormat("ar-EG", { dateStyle: "medium" }).format(new Date(iso)) : "—");
const egp = (piasters: number) => `${formatMoney(piasters / 100, piasters % 100 === 0 ? 0 : 2)} ج.م`;

type License = { complimentary: boolean; package_key: string; payment_option: string; licensed_at: string; access_paid_through: string | null };
type Order = { id: string; package_key: string; payment_option: string; purpose: string; status: string; amount_total: number; created_at: string; paid_at: string | null; needs_review: boolean };

export default async function BillingPage({ searchParams }: { searchParams: Promise<{ package?: string; option?: string }> }) {
  const sp = await searchParams;
  const supabase = await getSupabase();
  const membership = await getMembership();
  if (!membership) return null;
  const orgId = membership.organization_id;

  // One batch for everything this page needs. Before, the administrator check, the pricing configuration and the three company queries
  // ran one after another (and my_org_access was asked twice: here and in the layout). The administrator branch below discards the
  // rest, which costs an administrator a few cheap reads and everyone else several round trips less.
  const me = await getCurrentUser();
  const [isAdmin, { config: cfg }, { data: licenseRow }, { data: orderRows }, { data: accessJson }] = await Promise.all([
    me ? isSuperAdminSession(me) : Promise.resolve(false),
    loadPricingConfig(supabase),   // admin-managed values, or the shipped ones
    supabase.from("organization_licenses").select("package_key, payment_option, licensed_at, access_paid_through, complimentary").eq("organization_id", orgId).maybeSingle(),
    supabase.from("billing_orders").select("id, package_key, payment_option, purpose, status, amount_total, created_at, paid_at, needs_review").eq("organization_id", orgId).order("created_at", { ascending: false }).limit(10),
    getOrgAccess(orgId),
  ]);

  // A platform administrator is never asked to pay: this page only explains that.
  if (isAdmin) {
    return (
      <div>
        <PageHeader title="الباقة والمدفوعات" />
        <Card className="max-w-2xl p-6 sm:p-8">
          <span className="flex h-11 w-11 items-center justify-center rounded-full bg-sageSoft text-sage"><ShieldCheck size={22} /></span>
          <h2 className="mt-4 text-xl font-semibold text-charcoal">حساب إدارة المنصة</h2>
          <p className="mt-2 text-sm leading-7 text-charcoal/60">هذا الحساب لا يخضع لأي دفع ولا يتطلب باقة: يعمل بكل الوحدات وبلا حدود، لتجربة النظام كاملًا قبل الإطلاق. أي مستخدم آخر لا يدخل لوحة التحكم قبل أن يدفع.</p>
          <Link href="/admin/packages" className="mt-5 inline-block rounded-xl bg-charcoal px-5 py-2.5 text-sm font-medium text-ivory hover:bg-sage">إدارة الباقات والأسعار</Link>
        </Card>
      </div>
    );
  }
  const license = licenseRow as License | null;
  // A package chosen on /pricing before the account existed (remembered with the account) is only PRE-SELECTED below: the page opens
  // normally and the owner presses the button to go on. (It used to redirect straight to the order page, so this page flashed by.)
  const remembered = !license && me ? selectionFromMetadata(me.user_metadata, cfg) : null;
  const orders = (orderRows ?? []) as Order[];

  const configured = xpayIsConfigured();
  const closedReason = !pricesConfirmed() ? "الأسعار قيد المراجعة، والدفع غير متاح حاليًا. تواصل مع فريق كيان."
    : !configured ? "بوابة الدفع غير مفعّلة بعد. تواصل مع فريق كيان لإتمام التفعيل." : null;
  const testMode = xpayIsTestMode();

  // Before anyone pays: does this organization already outgrow a package? (the database answers, from live data)
  const fit: Record<string, string[]> = {};
  if (!license) {
    try {
      const admin = createAdminClient();
      await Promise.all(getPackages(cfg).map(async (p) => {
        const q = buildQuote({ packageKey: p.key, option: "monthly", purpose: "initial" }, cfg);
        const { data } = await admin.rpc("billing_fit_report", { p_org: orgId, p_entitlements: q.entitlements });
        const v = ((data as { violations?: FitViolation[] } | null)?.violations ?? []);
        if (v.length) fit[p.key] = describeFitViolations(v);
      }));
    } catch (e) { console.error("billing: fit check unavailable", e instanceof Error ? e.message : e); }
  }

  const dbAccess = parseDbAccess((accessJson as { access?: unknown } | null)?.access);
  const state: AccessState = dbAccess?.state ?? "none";
  const pkg = license ? getPackage(license.package_key, cfg) : null;
  const left = daysUntil(license?.access_paid_through ?? null);
  const pending = orders.find((o) => o.status === "pending");

  return (
    <div>
      <PageHeader title="الباقة والمدفوعات" />

      {license && pkg ? (
        <Card className="mb-6 p-5 sm:p-7">
          <div className="flex flex-col gap-5 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <p className="text-xs text-charcoal/45">باقتك الحالية</p>
              <h2 className="mt-1 text-2xl font-semibold tracking-tight text-charcoal">{pkg.name}</h2>
              <p className="mt-1 text-sm text-charcoal/55">{OPTION_LABEL[license.payment_option] ?? license.payment_option} — منذ {date(license.licensed_at)}</p>
            </div>
            <StateBadge state={state} />
          </div>
          <dl className="mt-5 grid gap-4 border-t border-borderSoft pt-5 text-sm sm:grid-cols-3">
            <div><dt className="text-charcoal/45">{license.payment_option === "monthly" ? "الاشتراك مدفوع حتى" : "الاستضافة والصيانة مدفوعتان حتى"}</dt><dd className="mt-1 font-medium text-charcoal">{license.complimentary ? "بلا انتهاء" : license.access_paid_through ? date(license.access_paid_through) : "لم تُدفع بعد"}</dd></div>
            <div><dt className="text-charcoal/45">المتبقي</dt><dd className="mt-1 font-medium text-charcoal">{license.complimentary ? "—" : left === null ? "—" : left >= 0 ? `${formatMoney(left, 0)} يومًا` : `انتهى منذ ${formatMoney(-left, 0)} يومًا`}</dd></div>
            <div><dt className="text-charcoal/45">الرخصة</dt><dd className="mt-1 font-medium text-charcoal">{license.complimentary ? "مجانية من إدارة المنصة" : license.payment_option === "one_time" ? "دائمة" : "سارية ما دام الاشتراك مدفوعًا"}</dd></div>
          </dl>
          <div className="mt-6 flex flex-col gap-3 border-t border-borderSoft pt-5 sm:flex-row sm:items-center sm:justify-between">
            <p className="text-sm leading-6 text-charcoal/55">
              {license.complimentary
                ? "هذه الباقة مجانية ولا تحتاج إلى أي دفع."
                : <>لا يُسحب أي مبلغ تلقائيًا. جدّد قبل الموعد لتبقى الفترة متصلة — الشهر المدفوع يُضاف إلى تاريخ انتهاء الفترة الحالية ولا يضيع منه شيء. لتغيير الباقة تواصل مع فريق كيان.</>}
            </p>
            {license.complimentary ? null : closedReason ? <p className="text-sm text-rose">{closedReason}</p> : (
              <Link href="/checkout?renew=1" className="inline-flex items-center justify-center rounded-xl bg-charcoal px-6 py-3 text-sm font-medium text-ivory hover:bg-sage">{license.payment_option === "monthly"
                ? `جدّد الاشتراك — ${egp(buildQuote({ packageKey: license.package_key, option: "monthly", purpose: "renewal" }, cfg).dueToday)}`
                : `جدّد الاستضافة — ${egp(buildQuote({ packageKey: license.package_key, option: "one_time", purpose: "renewal" }, cfg).dueToday)}`}</Link>
            )}
          </div>
        </Card>
      ) : (
        <>
          {pending && (
            <Card className="mb-6 flex flex-col gap-3 border-sage/40 bg-sageSoft/40 p-5 sm:flex-row sm:items-center sm:justify-between">
              <p className="text-sm leading-6 text-charcoal/70">لديك عملية دفع مفتوحة بقيمة <span className="num font-medium text-charcoal">{egp(pending.amount_total)}</span>. إن كنت دفعت للتو فسيُفعَّل حسابك خلال لحظات، وإلا يمكنك استكمالها.</p>
              <Link href={pending.purpose === "renewal" ? "/checkout?renew=1" : `/checkout?package=${encodeURIComponent(pending.package_key)}&option=${encodeURIComponent(pending.payment_option)}`} className="inline-flex items-center justify-center rounded-xl border border-borderSoft bg-white px-5 py-2.5 text-sm font-medium text-charcoal hover:border-sage">استكمل الدفع</Link>
            </Card>
          )}
          <p className="mb-6 max-w-2xl text-sm leading-7 text-charcoal/55">لتفعيل حسابك اختر الباقة وطريقة الدفع. بعد تأكيد الدفع تُفتح لك لوحة التحكم مباشرة، وتحدد الباقة الوحدات وحجم الفريق والمخازن المتاحة لك.</p>
          <PricingExperience variant="checkout" fit={fit} testMode={testMode} checkoutClosedReason={closedReason}
            packages={cfg.packages} initialPackage={sp.package ?? remembered?.packageKey} initialOption={sp.package ? (isPaymentOption(sp.option) ? sp.option : undefined) : remembered?.option} />
        </>
      )}

      <Card className="mt-8 overflow-hidden p-0 sm:p-0">
        <h2 className="border-b border-borderSoft px-5 py-4 text-base font-semibold text-charcoal">سجل المدفوعات</h2>
        {orders.length === 0 ? <p className="px-5 py-8 text-center text-sm text-charcoal/45">لا توجد عمليات دفع بعد.</p> : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[34rem] text-sm">
              <thead><tr className="text-xs text-charcoal/45"><th className="px-5 py-3 text-right font-medium">التاريخ</th><th className="px-3 py-3 text-right font-medium">الطلب</th><th className="px-3 py-3 text-right font-medium">المبلغ</th><th className="px-5 py-3 text-right font-medium">الحالة</th></tr></thead>
              <tbody className="divide-y divide-borderSoft">
                {orders.map((o) => (
                  <tr key={o.id}>
                    <td className="px-5 py-3 text-charcoal/65">{date(o.paid_at ?? o.created_at)}</td>
                    <td className="px-3 py-3 text-charcoal">{PURPOSE_LABEL[o.purpose]} — {getPackage(o.package_key, cfg)?.name ?? o.package_key} <span className="text-charcoal/40">({OPTION_LABEL[o.payment_option]})</span></td>
                    <td className="num px-3 py-3 font-medium text-charcoal">{egp(o.amount_total)}</td>
                    <td className="px-5 py-3"><span className={`inline-block px-2 py-0.5 text-xs font-medium ${o.status === "paid" ? "bg-sageSoft text-sage" : o.status === "pending" ? "bg-amber-50 text-amber-800" : "bg-rose/10 text-rose"}`}>{STATUS_LABEL[o.status] ?? o.status}</span>{o.needs_review && <span className="mr-2 text-xs text-charcoal/45">قيد المراجعة</span>}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </div>
  );
}

function StateBadge({ state }: { state: AccessState }) {
  const map = {
    active: { t: "سارية", c: "bg-sageSoft text-sage", I: CircleCheck },
    free: { t: "مجانية", c: "bg-sageSoft text-sage", I: CircleCheck },
    license_only: { t: "الاستضافة لم تُدفع بعد", c: "bg-amber-50 text-amber-800", I: CalendarClock },
    grace: { t: "فترة سماح — جدّد الآن", c: "bg-amber-50 text-amber-800", I: CalendarClock },
    expired: { t: "منتهية — الوصول موقوف حتى التجديد", c: "bg-rose/10 text-rose", I: TriangleAlert },
    none: { t: "", c: "", I: CircleCheck },
  }[state];
  const I = map.I;
  return <span className={`inline-flex items-center gap-1.5 self-start px-3 py-1.5 text-xs font-medium ${map.c}`}><I size={14} />{map.t}</span>;
}
