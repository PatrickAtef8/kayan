"use client";

import { useMemo, useState, useTransition } from "react";
import Link from "next/link";
import clsx from "clsx";
import { m } from "framer-motion";
import { Check, Minus, ShieldCheck, TriangleAlert, ArrowLeft } from "lucide-react";
import { MotionProvider } from "@/components/motion-provider";
import { Spinner } from "@/components/ui/spinner";
import { formatMoney } from "@/lib/money";
import { PRICING_CONFIG, MODULE_FEATURES, PACKAGE_MODULE_ORDER } from "@/config/pricing.config";
import { buildQuote, fromPiasters, getPackages, type PricingConfig } from "@/lib/billing/pricing";
import type { PackageConfig } from "@/config/pricing.config";
import { useRouter } from "next/navigation";
import { FeatureMatrix } from "./feature-matrix";

// ONE pricing experience for two places. There are exactly TWO plans (a perpetual license, a monthly subscription); each card IS a plan:
//   variant="public"    → /pricing, for visitors: choose and read, buttons lead to sign-up / the billing page
//   variant="checkout"  → /dashboard/billing, for the owner: choose, see exactly what is due today and later, pay with XPay
// Amounts are computed by the same pure function the server uses (buildQuote) — but the server recomputes them itself;
// nothing the browser holds is ever trusted as a price.

const baseCfg = PRICING_CONFIG as PricingConfig;
const egp = (piasters: number) => {
  const v = fromPiasters(piasters);
  return `${formatMoney(v, Number.isInteger(v) ? 0 : 2)} ج.م`;
};
const limitText = (n: number | null, unit: string) => (n === null ? `${unit} بلا حد` : `حتى ${formatMoney(n, 0)} ${unit}`);

export function PricingExperience({
  variant,
  fit = {},
  initialPlan,
  signedIn = false,
  testMode = false,
  checkoutClosedReason = null,
  packages: livePackages,
}: {
  variant: "public" | "checkout";
  /** per plan: sentences saying why this organization cannot take it right now (checkout only) */
  fit?: Record<string, string[]>;
  initialPlan?: string;
  signedIn?: boolean;
  testMode?: boolean;
  /** when set, paying is switched off and this is shown instead (prices not confirmed, gateway not configured…) */
  checkoutClosedReason?: string | null;
  /** the plans in force right now (admin-managed); omitted → the shipped configuration */
  packages?: PackageConfig[];
}) {
  const cfg = useMemo<PricingConfig>(() => (livePackages ? { ...baseCfg, packages: livePackages } : baseCfg), [livePackages]);
  const packages = getPackages(cfg);
  const checkout = variant === "checkout";
  const [selected, setSelected] = useState<string>(
    packages.some((p) => p.key === initialPlan && !(fit[p.key]?.length)) ? initialPlan! : (packages.find((p) => !(fit[p.key]?.length)) ?? packages[0]).key,
  );
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const [redirecting, setRedirecting] = useState(false);

  const quote = useMemo(() => buildQuote({ plan: selected, purpose: "initial" }, cfg), [selected, cfg]);
  const selectedMisfit = fit[selected] ?? [];
  const busy = pending || redirecting;
  const sq = variant === "public" ? "" : "rounded-2xl";

  // Choosing a plan does NOT start a payment: it opens Kayan's own order page (/checkout), where the customer reviews the order
  // and only then continues to XPay. The price is never taken from this page — /checkout rebuilds the quote on the server.
  const router = useRouter();
  function pay() {
    if (busy || selectedMisfit.length || checkoutClosedReason) return;
    setError(null);
    setRedirecting(true);
    startTransition(() => { router.push(`/checkout?plan=${encodeURIComponent(selected)}`); });
  }

  return (
    <MotionProvider>
      <div className="space-y-8">
        {/* ---- the two plans ---------------------------------------------------------------------------- */}
        <div className="mx-auto grid max-w-4xl grid-cols-1 gap-4 md:grid-cols-2" role={checkout ? "radiogroup" : undefined} aria-label={checkout ? "الباقة" : undefined}>
          {packages.map((p, i) => {
            const q = buildQuote({ plan: p.key, purpose: "initial" }, cfg);
            const on = checkout && selected === p.key;
            const misfit = fit[p.key] ?? [];
            const included = new Set<string>(p.modules);
            const disabled = busy || misfit.length > 0;
            return (
              <m.div key={p.key} initial={{ opacity: 0, y: 14 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true, margin: "-40px" }} transition={{ delay: i * 0.06, duration: 0.5 }} className="flex">
                <div
                  {...(checkout ? {
                    role: "radio", "aria-checked": on, "aria-disabled": disabled, tabIndex: disabled ? -1 : 0,
                    onClick: () => { if (!disabled) setSelected(p.key); },
                    onKeyDown: (e: React.KeyboardEvent) => { if (!disabled && (e.key === " " || e.key === "Enter")) { e.preventDefault(); setSelected(p.key); } },
                  } : {})}
                  className={clsx(
                    "relative flex w-full flex-col border bg-white p-6 text-right transition-all duration-300 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sage/40", sq,
                    on ? "border-sage shadow-[0_18px_44px_rgba(52,78,65,0.14)] ring-1 ring-sage" : "border-borderSoft",
                    checkout && !misfit.length && !on && "cursor-pointer hover:border-sage",
                    misfit.length > 0 && "cursor-not-allowed opacity-60",
                  )}
                >
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <h3 className="text-xl font-medium tracking-tight text-charcoal">{p.name}</h3>
                      <p className="mt-2 min-h-[3.75rem] text-sm leading-6 text-charcoal/50">{p.tagline}</p>
                    </div>
                    {on ? <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-sage text-ivory"><Check size={14} strokeWidth={2.4} /></span> : null}
                  </div>

                  <div className="mt-5 border-t border-borderSoft pt-5">
                    {p.key === "one_time" ? (
                      <>
                        <p className="text-xs text-charcoal/45">رخصة دائمة — تُدفع مرة واحدة</p>
                        <p className="mt-1 text-3xl font-semibold tracking-tight text-charcoal"><span className="num">{egp(q.lines.find((l) => l.id === "license")!.amount)}</span></p>
                        {q.recurring
                          ? <p className="mt-2 text-sm text-charcoal/55">+ استضافة وصيانة <span className="num font-medium text-charcoal">{egp(q.recurring.amount)}</span> شهريًا، تُدفع بشكل منفصل</p>
                          : <p className="mt-2 text-sm font-medium text-sage">الاستضافة والصيانة مجانية — لا رسوم شهرية بعد الرخصة</p>}
                      </>
                    ) : (
                      <>
                        <p className="text-xs text-charcoal/45">اشتراك شهري</p>
                        <p className="mt-1 text-3xl font-semibold tracking-tight text-charcoal"><span className="num">{egp(q.recurring!.amount)}</span><span className="mr-1 text-sm font-normal text-charcoal/45">/ شهريًا</span></p>
                        <p className="mt-2 text-sm text-charcoal/55">يشمل الدخول للنظام والاستضافة والصيانة الأساسية</p>
                      </>
                    )}
                  </div>

                  <ul className="mt-5 space-y-2.5 border-t border-borderSoft pt-5 text-sm">
                    <li className="flex items-center gap-2 font-medium text-charcoal"><ShieldCheck size={15} className="shrink-0 text-sage" />{limitText(p.limits.maxMembers, "أعضاء فريق")}</li>
                    <li className="flex items-center gap-2 font-medium text-charcoal"><ShieldCheck size={15} className="shrink-0 text-sage" />{limitText(p.limits.maxWarehouses, "مخازن")}</li>
                    {PACKAGE_MODULE_ORDER.map((k) => {
                      const has = included.has(k);
                      return (
                        <li key={k} className={clsx("flex items-center gap-2", has ? "text-charcoal/75" : "text-charcoal/30")}>
                          {has ? <Check size={15} strokeWidth={2.2} className="shrink-0 text-sage" /> : <Minus size={15} className="shrink-0" />}
                          <span className={has ? "" : "line-through decoration-charcoal/20"}>{MODULE_FEATURES[k].label}</span>
                          {!has && <span className="sr-only">(غير مشمولة)</span>}
                        </li>
                      );
                    })}
                  </ul>

                  {misfit.length > 0 && (
                    <p className="mt-4 flex items-start gap-2 border-t border-borderSoft pt-4 text-xs leading-5 text-rose"><TriangleAlert size={14} className="mt-0.5 shrink-0" />{misfit.join(" ")}</p>
                  )}

                  {!checkout && (
                    <Link href={`${signedIn ? "/checkout" : "/signup"}?plan=${p.key}`}
                      className="mt-6 flex items-center justify-center gap-2 bg-charcoal px-4 py-3 text-sm font-medium text-ivory transition-colors hover:bg-sage">
                      {signedIn ? "اختر هذا الخيار" : "ابدأ بإنشاء حسابك"}<ArrowLeft size={15} />
                    </Link>
                  )}
                </div>
              </m.div>
            );
          })}
        </div>

        {/* ---- order summary (checkout only) ------------------------------------------------------------ */}
        {checkout && (
          <m.section initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }} aria-labelledby="summary-title" className={clsx("mx-auto max-w-3xl border border-borderSoft bg-white p-6 sm:p-8", sq)}>
            <div className="flex items-center justify-between gap-3">
              <h2 id="summary-title" className="text-lg font-semibold text-charcoal">ملخص الطلب</h2>
              {testMode && <span className="bg-amber-50 px-2.5 py-1 text-[0.6875rem] font-medium text-amber-800 ring-1 ring-amber-200">وضع تجريبي — لن يُخصم أي مبلغ حقيقي</span>}
            </div>
            <p className="mt-1 text-sm text-charcoal/50">{quote.packageName}</p>

            <dl className="mt-5 divide-y divide-borderSoft border-y border-borderSoft text-sm">
              {quote.lines.map((l) => (
                <div key={l.id} className="flex items-center justify-between gap-4 py-3"><dt className="text-charcoal/65">{l.label}</dt><dd className="num font-medium text-charcoal">{egp(l.amount)}</dd></div>
              ))}
              <div className="flex items-center justify-between gap-4 py-4"><dt className="text-base font-semibold text-charcoal">المستحق اليوم</dt><dd className="num text-2xl font-semibold tracking-tight text-charcoal">{egp(quote.dueToday)}</dd></div>
            </dl>

            {quote.hostingFree && (
              <p className="mt-4 bg-sageSoft/60 p-4 text-sm leading-6 text-charcoal/75"><span className="font-medium text-charcoal">لا رسوم بعد ذلك:</span> الاستضافة والصيانة مجانيتان، فتدفع الرخصة مرة واحدة فقط ولا يوجد تجديد شهري.</p>
            )}
            {quote.recurring && (
              <div className="mt-4 space-y-2 bg-sageSoft/60 p-4 text-sm leading-6 text-charcoal/75">
                <p><span className="font-medium text-charcoal">بعد ذلك:</span> {quote.recurring.label} <span className="num font-medium text-charcoal">{egp(quote.recurring.amount)}</span> كل شهر{selected === "one_time" && cfg.terms.includeFirstHostingWithLicense ? "، يبدأ بعد الشهر المدفوع اليوم" : ""}.</p>
                {!quote.recurring.autoCharged && (
                  <p className="text-charcoal/60">لا يتم سحب أي مبلغ من بطاقتك تلقائيًا. عند اقتراب موعد التجديد ستجد زر «جدّد الآن» في هذه الصفحة، وكل دفعة تؤكدها أنت.</p>
                )}
              </div>
            )}

            <details className="mt-4 text-sm text-charcoal/60">
              <summary className="cursor-pointer select-none font-medium text-charcoal/75">ماذا تشمل الاستضافة والصيانة؟</summary>
              <div className="mt-3 grid gap-4 sm:grid-cols-3">
                <TermList title="الاستضافة" items={cfg.copy.hostingIncludes} />
                <TermList title="الصيانة الأساسية" items={cfg.copy.maintenanceIncludes} />
                <TermList title="لا تشملها" items={cfg.copy.maintenanceExcludes} muted />
              </div>
              {selected === "one_time" && <ul className="mt-4 list-disc space-y-1 pr-5">{cfg.copy.licenseNotes.map((n) => <li key={n}>{n}</li>)}</ul>}
            </details>

            {selectedMisfit.length > 0 && <p role="alert" className="mt-4 flex items-start gap-2 text-sm text-rose"><TriangleAlert size={16} className="mt-0.5 shrink-0" />{selectedMisfit.join(" ")}</p>}
            {checkoutClosedReason && <p role="alert" className="mt-4 flex items-start gap-2 text-sm text-rose"><TriangleAlert size={16} className="mt-0.5 shrink-0" />{checkoutClosedReason}</p>}
            {error && <p role="alert" className="mt-4 flex items-start gap-2 bg-rose/5 p-3 text-sm text-rose"><TriangleAlert size={16} className="mt-0.5 shrink-0" />{error}</p>}

            <button type="button" onClick={pay} disabled={busy || selectedMisfit.length > 0 || !!checkoutClosedReason}
              className={clsx("mt-6 flex w-full items-center justify-center gap-2.5 bg-charcoal px-5 py-3.5 text-sm font-medium text-ivory transition-all duration-200 hover:bg-sage focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sage/40 disabled:cursor-not-allowed disabled:opacity-50 active:scale-[0.99]", sq)}>
              {busy ? <><Spinner />جارٍ فتح صفحة الطلب…</> : <>متابعة إلى صفحة الطلب — {egp(quote.dueToday)}<ArrowLeft size={16} /></>}
            </button>
            <p className="mt-3 text-center text-xs leading-5 text-charcoal/40">ستراجع تفاصيل الطلب في الخطوة التالية قبل التحويل إلى صفحة XPay الآمنة. لا تُفعَّل الباقة إلا بعد تأكيد الدفع.</p>
          </m.section>
        )}

        <FeatureMatrix sq={sq} packages={packages} />
      </div>
    </MotionProvider>
  );
}

function TermList({ title, items, muted }: { title: string; items: string[]; muted?: boolean }) {
  return (
    <div>
      <p className="mb-1.5 text-xs font-medium text-charcoal/75">{title}</p>
      <ul className={clsx("space-y-1 text-xs leading-5", muted && "text-charcoal/45")}>{items.map((i) => <li key={i}>• {i}</li>)}</ul>
    </div>
  );
}
