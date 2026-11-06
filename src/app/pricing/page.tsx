import type { Metadata } from "next";
import { getCurrentUser, getSupabase } from "@/lib/org-context";
import { Navbar } from "@/components/marketing/navbar";
import { MarketingFooter } from "@/components/marketing/footer";
import { loadPricingConfig } from "@/lib/billing/config";
import { PricingExperience } from "@/components/pricing/pricing-experience";
import { loadTrialOffer } from "@/lib/billing/trial.server";
import { daysText } from "@/lib/billing/trial";
import Link from "next/link";

export const metadata: Metadata = {
  title: "الأسعار والباقات — كيان",
  description: "اختر طريقة الدفع المناسبة لكيان: رخصة دائمة مع استضافة وصيانة شهرية، أو اشتراك شهري شامل.",
};

// Public: visitors can read everything; paying happens inside the account (/dashboard/billing), by the owner.
export default async function PricingPage() {
  // Only "is someone signed in?" is needed here, so the session token is read locally (no Auth round trip) and the price list is
  // loaded alongside it. Paying is protected by the server, not by this flag.
  const supabase = await getSupabase();
  const [user, { config }, offer] = await Promise.all([getCurrentUser(), loadPricingConfig(supabase), loadTrialOffer()]);
  const signedIn = !!user;   // admin-managed values, or the shipped ones
  return (
    <div className="min-h-screen bg-ivory text-charcoal" dir="rtl">
      <Navbar signedIn={signedIn} trialDays={offer.enabled ? offer.days : null} />
      <main className="px-5 pb-24 pt-32 sm:px-6 sm:pt-40">
        <div className="mx-auto max-w-6xl">
          <header className="mx-auto mb-12 max-w-2xl text-center">
            <p className="mb-4 text-xs font-medium tracking-[0.16em] text-sage">الأسعار</p>
            <h1 className="text-4xl font-medium leading-tight tracking-[-0.04em] text-charcoal sm:text-5xl">خياران بسيطان: ادفع مرة واحدة أو شهريًا.</h1>
            <p className="mt-5 text-sm leading-7 text-charcoal/55">ادفع رخصة دائمة مرة واحدة واستضافة وصيانة بشكل منفصل، أو اشترك شهريًا بسعر واحد شامل. السعر بالجنيه المصري، والدفع عبر XPay.</p>
          </header>
          {!signedIn && offer.enabled && (
            <div className="mx-auto mb-8 flex max-w-4xl flex-col items-center justify-between gap-3 border border-sage/30 bg-sageSoft/50 px-5 py-4 text-center sm:flex-row sm:text-right">
              <p className="text-sm leading-6 text-charcoal/75"><span className="font-medium text-charcoal">جرّب مجانًا لمدة {daysText(offer.days)}</span> — كل الوحدات وبدون بطاقة ائتمان، وتبقى بياناتك عند الاشتراك.</p>
              <Link href="/signup?trial=1" className="shrink-0 bg-sage px-5 py-2.5 text-sm font-medium text-ivory transition-colors hover:bg-charcoal">ابدأ مجانًا</Link>
            </div>
          )}
          <PricingExperience variant="public" signedIn={signedIn} packages={config.packages} />
        </div>
      </main>
      <MarketingFooter signedIn={signedIn} />
    </div>
  );
}
