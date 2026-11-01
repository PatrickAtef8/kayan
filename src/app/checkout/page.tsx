import Link from "next/link";
import { redirect } from "next/navigation";
import { Check, Lock, ShieldCheck, TriangleAlert } from "lucide-react";
import { Card } from "@/components/ui/card";
import { CheckoutButton } from "@/components/pricing/checkout-button";
import { getCheckoutContext } from "@/lib/billing/checkout-context.server";
import { getSupabase } from "@/lib/org-context";
import { createAdminClient } from "@/lib/supabase/admin";
import { loadPricingConfig } from "@/lib/billing/config";
import { buildQuote, describeFitViolations, getPackage, isPaymentOption, type FitViolation, type Quote } from "@/lib/billing/pricing";
import { pricesConfirmed, xpayIsConfigured, xpayIsTestMode } from "@/lib/billing/xpay.server";
import { OPTION_LABEL, PURPOSE_LABEL } from "@/lib/billing/labels";
import { MODULE_FEATURES, PACKAGE_MODULE_ORDER, INCLUDED_IN_EVERY_PACKAGE } from "@/config/pricing.config";
import { formatMoney } from "@/lib/money";
import { loadAcceptableVersions } from "@/lib/legal/legal.server";

const egp = (piasters: number) => `${formatMoney(piasters / 100, piasters % 100 === 0 ? 0 : 2)} ج.م`;
const limit = (n: number | null) => (n === null ? "بلا حد" : formatMoney(n, 0));

// Kayan's own order page: review what you are buying, then continue to XPay. Nothing here is a source of truth for money — the
// quote shown is rebuilt on the server from the saved package configuration (or from the company's license for a renewal), and the
// button's action rebuilds it AGAIN before an order is created, so what is displayed can never differ from what is charged.
export default async function CheckoutPage({ searchParams }: { searchParams: Promise<{ package?: string; option?: string; renew?: string }> }) {
  const sp = await searchParams;
  const ctx = await getCheckoutContext();

  if (ctx.isAdmin) return <Notice icon="shield" title="حساب إدارة المنصة لا يخضع للدفع">لا حاجة إلى إتمام طلب بهذا الحساب. يمكنك استخدام لوحة التحكم ولوحة تحكم الأدمن مباشرة.<Back href="/dashboard" label="لوحة التحكم" /></Notice>;
  if (!ctx.orgId) redirect("/dashboard");
  if (ctx.roleKey !== "owner") return <Notice icon="lock" title="إتمام الدفع لمالك الحساب فقط">يرجى التواصل مع مالك الحساب لإتمام الاشتراك.</Notice>;

  const license = ctx.access?.license ?? null;
  if (license?.complimentary) return <Notice icon="shield" title="هذه الشركة تتمتع بوصول مجاني">لا يلزم أي دفع.<Back href="/dashboard" label="لوحة التحكم" /></Notice>;

  const supabase = await getSupabase();
  // Independent reads in ONE batch (they used to run one after another, with the fit check in between).
  const [{ config: cfg }, { data: pendingOrder }, legalVersions] = await Promise.all([
    loadPricingConfig(supabase),
    supabase.from("billing_orders").select("id, amount_total").eq("organization_id", ctx.orgId).eq("status", "pending").maybeSingle(),
    loadAcceptableVersions(),   // the versions the checkbox will accept (null when the documents are not available)
  ]);
  const renewal = !!license;
  let packageKey: string | undefined;
  let option: string | undefined;
  if (license) { packageKey = license.package_key ?? undefined; option = license.payment_option ?? undefined; }   // a renewal is of what the company already has
  else { packageKey = sp.package; option = sp.option; }
  const pkg = packageKey ? getPackage(packageKey, cfg) : null;
  if (!pkg || !isPaymentOption(option)) redirect("/dashboard/billing");

  let quote: Quote;
  try { quote = buildQuote({ packageKey: pkg.key, option, purpose: renewal ? "renewal" : "initial" }, cfg); } catch { redirect("/dashboard/billing"); }

  // before the first payment: does the company already outgrow this package? (the database answers from live data)
  let misfit: string[] = [];
  if (!renewal) {
    try {
      const { data } = await createAdminClient().rpc("billing_fit_report", { p_org: ctx.orgId, p_entitlements: quote.entitlements });
      misfit = describeFitViolations(((data as { violations?: FitViolation[] } | null)?.violations ?? []));
    } catch (e) { console.error("checkout: fit check unavailable", e instanceof Error ? e.message : e); }
  }
  const closedReason = !pricesConfirmed() ? "الأسعار قيد المراجعة، والدفع غير متاح حاليًا. تواصل مع فريق كيان."
    : !xpayIsConfigured() ? "بوابة الدفع غير مفعّلة بعد. تواصل مع فريق كيان لإتمام التفعيل."
    : !legalVersions ? "الصفحات القانونية غير متاحة حاليًا، ولا يمكن بدء الدفع الآن. تواصل مع فريق كيان." : null;
  const legal = cfg.legal;
  const state = ctx.access?.access?.state;

  return (
    <div className="mx-auto max-w-5xl">
      <h1 className="text-2xl font-semibold tracking-tight text-charcoal">{renewal ? "تجديد الاشتراك" : "إتمام الطلب"}</h1>
      <p className="mt-1 text-sm text-charcoal/55">{renewal ? "راجع التجديد ثم تابع إلى الدفع. لا يُسحب أي مبلغ تلقائيًا." : "راجع طلبك ثم تابع إلى الدفع. لا تُفعَّل الباقة إلا بعد تأكيد الدفع."}</p>
      {renewal && state === "expired" && <p role="alert" className="mt-4 flex items-start gap-2 rounded-xl bg-rose/5 p-3 text-sm text-rose"><TriangleAlert size={16} className="mt-0.5 shrink-0" />انتهى اشتراكك وتوقّف الوصول إلى النظام. يعود الوصول فور تأكيد دفع التجديد.</p>}

      <div className="mt-6 grid gap-5 lg:grid-cols-[1fr_22rem]">
        {/* ---- the package -------------------------------------------------------------------------------- */}
        <Card className="p-5 sm:p-7">
          <p className="text-xs text-charcoal/45">{renewal ? "الباقة الحالية" : "الباقة المختارة"}</p>
          <h2 className="mt-1 text-2xl font-semibold text-charcoal">{pkg.name}</h2>
          <p className="mt-1 text-sm text-charcoal/55">{OPTION_LABEL[option]}</p>
          <dl className="mt-5 grid grid-cols-2 gap-4 border-t border-borderSoft pt-5 text-sm">
            <div><dt className="text-charcoal/45">أعضاء الفريق</dt><dd className="num mt-1 font-medium text-charcoal">{limit(pkg.limits.maxMembers)}</dd></div>
            <div><dt className="text-charcoal/45">المخازن</dt><dd className="num mt-1 font-medium text-charcoal">{limit(pkg.limits.maxWarehouses)}</dd></div>
          </dl>
          <p className="mb-2 mt-5 text-xs font-medium text-charcoal/60">الوحدات المشمولة</p>
          <ul className="grid gap-x-6 gap-y-1.5 text-sm text-charcoal/75 sm:grid-cols-2">
            {PACKAGE_MODULE_ORDER.filter((m) => (pkg.modules as string[]).includes(m)).map((m) => <li key={m} className="flex items-start gap-2"><Check size={15} strokeWidth={2.2} className="mt-1 shrink-0 text-sage" />{MODULE_FEATURES[m].label}</li>)}
          </ul>
          <p className="mb-2 mt-5 text-xs font-medium text-charcoal/60">في كل الباقات</p>
          <ul className="grid gap-x-6 gap-y-1.5 text-sm text-charcoal/65 sm:grid-cols-2">
            {INCLUDED_IN_EVERY_PACKAGE.map((f) => <li key={f} className="flex items-start gap-2"><Check size={15} strokeWidth={2.2} className="mt-1 shrink-0 text-sage" />{f}</li>)}
          </ul>
          {!renewal && <p className="mt-6 text-xs text-charcoal/45">لتغيير الباقة لاحقًا تواصل مع فريق كيان. <Link href="/pricing" className="underline underline-offset-4">قارن الباقات</Link></p>}
        </Card>

        {/* ---- the order ---------------------------------------------------------------------------------- */}
        <Card className="h-fit p-5 sm:p-6">
          <h2 className="text-base font-semibold text-charcoal">ملخص الطلب</h2>
          <p className="mt-1 text-xs text-charcoal/45">{PURPOSE_LABEL[quote.purpose]} — {pkg.name}</p>
          <ul className="mt-4 space-y-2.5 border-t border-borderSoft pt-4 text-sm">
            {quote.lines.map((l) => <li key={l.id} className="flex items-start justify-between gap-3"><span className="text-charcoal/70">{l.label}</span><span className="num shrink-0 font-medium text-charcoal">{egp(l.amount)}</span></li>)}
          </ul>
          <div className="mt-4 flex items-center justify-between border-t border-borderSoft pt-4"><span className="font-medium text-charcoal">الإجمالي المطلوب الآن</span><span className="num text-lg font-semibold text-charcoal">{egp(quote.dueToday)}</span></div>
          {quote.recurring && <p className="mt-3 text-xs leading-5 text-charcoal/50">{quote.recurring.label}: {egp(quote.recurring.amount)} شهريًا بعد ذلك، تدفعها بنفسك عند كل تجديد. لا يُسحب أي مبلغ تلقائيًا.</p>}

          <div className="mt-4 space-y-1 border-t border-borderSoft pt-4 text-xs text-charcoal/55">
            <p>الشركة: <span className="font-medium text-charcoal">{ctx.access?.orgName ?? "—"}</span></p>
            <p dir="ltr" className="text-right">{ctx.user.email}</p>
          </div>

          {misfit.length > 0 && <p role="alert" className="mt-4 flex items-start gap-2 text-sm text-rose"><TriangleAlert size={16} className="mt-0.5 shrink-0" />{misfit.join(" ")}</p>}
          {closedReason && <p role="alert" className="mt-4 flex items-start gap-2 text-sm text-rose"><TriangleAlert size={16} className="mt-0.5 shrink-0" />{closedReason}</p>}
          {pendingOrder && <p className="mt-4 bg-sageSoft/50 p-3 text-xs leading-5 text-charcoal/65">لديك عملية دفع مفتوحة لهذه الشركة؛ سنستكملها بدل إنشاء طلب جديد حتى لا يتكرر الدفع.</p>}

          <div className="mt-5">
            {renewal
              ? <CheckoutButton kind="renew" legal={legalVersions} disabled={!!closedReason}>متابعة إلى الدفع</CheckoutButton>
              : <CheckoutButton kind="purchase" legal={legalVersions} packageKey={pkg.key} option={option} disabled={!!closedReason || misfit.length > 0}>متابعة إلى الدفع</CheckoutButton>}
          </div>
          <p className="mt-3 flex items-start gap-1.5 text-xs leading-5 text-charcoal/45"><ShieldCheck size={14} className="mt-0.5 shrink-0" />يتم الدفع في صفحة XPay الآمنة؛ لا تمرّ بيانات بطاقتك بخوادم كيان.{xpayIsTestMode() ? " (وضع تجريبي)" : ""}</p>
          {legal.supportUrl && <p className="mt-3 text-xs text-charcoal/55"><a href={legal.supportUrl} className="underline underline-offset-4">تواصل مع الدعم</a></p>}
        </Card>
      </div>
      <p className="mt-6 text-center text-xs text-charcoal/40"><Link href="/dashboard/billing" className="underline underline-offset-4">الباقة والمدفوعات</Link></p>
    </div>
  );
}

function Back({ href, label }: { href: string; label: string }) {
  return <Link href={href} className="mt-5 inline-block rounded-xl bg-charcoal px-5 py-2.5 text-sm font-medium text-ivory hover:bg-sage">{label}</Link>;
}
function Notice({ icon, title, children }: { icon: "shield" | "lock"; title: string; children: React.ReactNode }) {
  const I = icon === "shield" ? ShieldCheck : Lock;
  return (
    <Card className="mx-auto mt-8 max-w-xl p-8 text-center">
      <span className="mx-auto flex h-12 w-12 items-center justify-center rounded-full bg-sageSoft text-sage"><I size={22} /></span>
      <h1 className="mt-4 text-xl font-semibold text-charcoal">{title}</h1>
      <p className="mt-2 text-sm leading-7 text-charcoal/55">{children}</p>
    </Card>
  );
}
