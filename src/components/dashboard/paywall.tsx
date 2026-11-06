import { Suspense } from "react";
import Link from "next/link";
import { Lock, LogOut } from "lucide-react";
import { Card } from "@/components/ui/card";
import { NavigationProgress } from "./navigation-progress";
import { StartTrialButton } from "./start-trial-button";
import { daysText } from "@/lib/billing/trial";

// What a company that has not paid (or whose paid period ended, when the configuration locks lapsed companies) sees instead
// of the dashboard: a plain frame — no menu, no data — around the billing pages for its owner, and a notice for everyone else.

export function PaywallShell({ orgName, userEmail, children }: { orgName?: string; userEmail?: string; children: React.ReactNode }) {
  return (
    <div className="min-h-dvh bg-[radial-gradient(circle_at_10%_0%,rgba(52,78,65,0.06),transparent_28rem),#F7F6F2]">
      <Suspense fallback={null}><NavigationProgress /></Suspense>
      <header className="border-b border-borderSoft/70 bg-white/70 backdrop-blur">
        <div className="mx-auto flex max-w-6xl items-center justify-between gap-3 px-4 py-3.5 sm:px-6">
          <div className="flex min-w-0 items-center gap-3">
            <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-charcoal text-sm font-semibold text-ivory">ك</span>
            <span className="truncate text-sm font-semibold text-charcoal">{orgName ?? "كيان"}</span>
          </div>
          <div className="flex shrink-0 items-center gap-3 text-xs text-charcoal/50">
            {userEmail ? <span className="hidden sm:inline" dir="ltr">{userEmail}</span> : null}
            <form action="/api/auth/signout" method="post">
              <button className="inline-flex items-center gap-1.5 rounded-lg border border-borderSoft px-3 py-1.5 text-charcoal/70 hover:border-rose/40 hover:text-rose"><LogOut size={14} />تسجيل الخروج</button>
            </form>
          </div>
        </div>
      </header>
      <main data-page-content className="mx-auto w-full max-w-6xl px-4 pb-12 pt-8 sm:px-6">{children}</main>
    </div>
  );
}

/** For anyone who is not the owner (rep, storekeeper) of a company that is not active. */
export function WorkspaceNotActive({ lapsed, trialEnded = false }: { lapsed: boolean; trialEnded?: boolean }) {
  return (
    <Card className="mx-auto mt-10 max-w-xl p-8 text-center">
      <span className="mx-auto flex h-12 w-12 items-center justify-center rounded-full bg-amber-50 text-amber-800"><Lock size={22} /></span>
      <h1 className="mt-4 text-xl font-semibold text-charcoal">{trialEnded ? "انتهت الفترة التجريبية للشركة" : lapsed ? "اشتراك الشركة منتهٍ" : "حساب الشركة لم يُفعَّل بعد"}</h1>
      <p className="mt-2 text-sm leading-7 text-charcoal/55">
        {trialEnded ? "انتهت الفترة التجريبية المجانية لهذه الشركة. بياناتها محفوظة بالكامل، وتعود لوحة التحكم للعمل فور اشتراك مالك الحساب."
          : lapsed ? "انتهت الفترة المدفوعة لهذه الشركة. يمكنك استخدام النظام فور تجديد مالك الحساب للاشتراك." : "لم يُكمل مالك الحساب الدفع بعد، لذلك لا تتوفر لوحة التحكم حاليًا. ستتمكن من الدخول فور إتمامه الدفع."}
      </p>
      <p className="mt-1 text-sm text-charcoal/45">يرجى التواصل مع مالك الحساب.</p>
    </Card>
  );
}

/** The gate could not read the company's subscription state. It fails CLOSED (never opens by mistake), and says so. */
export function GateUnavailable() {
  return (
    <Card className="mx-auto mt-10 max-w-xl p-8 text-center">
      <h1 className="text-xl font-semibold text-charcoal">تعذّر التحقق من حالة الاشتراك</h1>
      <p className="mt-2 text-sm leading-7 text-charcoal/55">حدث خلل مؤقت أثناء التحقق من اشتراك الشركة. لم يتأثر شيء من بياناتك. حدّث الصفحة بعد لحظات.</p>
      <Link href="/dashboard" className="mt-5 inline-block rounded-xl bg-charcoal px-5 py-2.5 text-sm font-medium text-ivory hover:bg-sage">إعادة المحاولة</Link>
    </Card>
  );
}

/** What the owner of a closed company is told. `trial_ended` = the free trial is over; `trial` = a trial can be started now. */
export type PromptReason = "never_paid" | "expired" | "trial_ended";
export type PromptTrial = { eligible: boolean; days: number };

/** Owner of an unpaid company when the page could not be identified: never redirects (so it can never loop). */
export function OwnerPayPrompt({ reason = "never_paid", trial }: { reason?: PromptReason; trial?: PromptTrial }) {
  const offer = reason === "never_paid" && trial?.eligible ? trial : null;
  const title = reason === "trial_ended" ? "انتهت فترتك التجريبية" : reason === "expired" ? "انتهى اشتراكك" : "فعّل حسابك لبدء الاستخدام";
  const body = reason === "trial_ended"
    ? "للاستمرار في استخدام لوحة التحكم اشترك الآن. بياناتك كلها محفوظة، وتجدها كما تركتها فور تأكيد الدفع."
    : reason === "expired" ? "جدّد اشتراكك لتعود لوحة التحكم للعمل. بياناتك محفوظة كما هي."
    : offer ? `جرّب كيان مجانًا لمدة ${daysText(offer.days)} بكل وحداته ودون أي دفع، أو اختر الباقة وأكمل الدفع مباشرة.`
    : "اختر الباقة وأكمل الدفع، وتُفتح لك لوحة التحكم مباشرة.";
  const cta = reason === "trial_ended" || reason === "expired" ? "اشترك الآن" : "اختيار الباقة والدفع";
  return (
    <Card className="mx-auto mt-10 max-w-xl p-8 text-center">
      <span className="mx-auto flex h-12 w-12 items-center justify-center rounded-full bg-amber-50 text-amber-800"><Lock size={22} /></span>
      <h1 className="mt-4 text-xl font-semibold text-charcoal">{title}</h1>
      <p className="mt-2 text-sm leading-7 text-charcoal/55">{body}</p>
      <div className="mt-5 flex flex-col items-center justify-center gap-3 sm:flex-row">
        {offer && <StartTrialButton label={`ابدأ تجربة مجانية ${daysText(offer.days)}`} />}
        <Link href="/dashboard/billing" className={offer ? "inline-block rounded-xl border border-borderSoft bg-white px-5 py-3 text-sm font-medium text-charcoal hover:border-sage" : "inline-block rounded-xl bg-charcoal px-5 py-2.5 text-sm font-medium text-ivory hover:bg-sage"}>{cta}</Link>
      </div>
    </Card>
  );
}
