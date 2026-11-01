import type { Metadata } from "next";
import { getCurrentUser, getSupabase } from "@/lib/org-context";
import { Navbar } from "@/components/marketing/navbar";
import { MarketingFooter } from "@/components/marketing/footer";
import { loadPricingConfig } from "@/lib/billing/config";
import { PricingExperience } from "@/components/pricing/pricing-experience";

export const metadata: Metadata = {
  title: "الأسعار والباقات — كيان",
  description: "اختر باقة كيان المناسبة: رخصة دائمة مع استضافة وصيانة شهرية، أو اشتراك شهري شامل.",
};

// Public: visitors can read everything; paying happens inside the account (/dashboard/billing), by the owner.
export default async function PricingPage() {
  // Only "is someone signed in?" is needed here, so the session token is read locally (no Auth round trip) and the price list is
  // loaded alongside it. Paying is protected by the server, not by this flag.
  const supabase = await getSupabase();
  const [user, { config }] = await Promise.all([getCurrentUser(), loadPricingConfig(supabase)]);
  const signedIn = !!user;   // admin-managed values, or the shipped ones
  return (
    <div className="min-h-screen bg-ivory text-charcoal" dir="rtl">
      <Navbar signedIn={signedIn} />
      <main className="px-5 pb-24 pt-32 sm:px-6 sm:pt-40">
        <div className="mx-auto max-w-6xl">
          <header className="mx-auto mb-12 max-w-2xl text-center">
            <p className="mb-4 text-xs font-medium tracking-[0.16em] text-sage">الأسعار</p>
            <h1 className="text-4xl font-medium leading-tight tracking-[-0.04em] text-charcoal sm:text-5xl">باقة واحدة تناسب حجم شركتك.</h1>
            <p className="mt-5 text-sm leading-7 text-charcoal/55">ادفع رخصة دائمة مرة واحدة واستضافة وصيانة بشكل منفصل، أو اشترك شهريًا بسعر واحد شامل. السعر بالجنيه المصري، والدفع عبر XPay.</p>
          </header>
          <PricingExperience variant="public" signedIn={signedIn} packages={config.packages} />
        </div>
      </main>
      <MarketingFooter signedIn={signedIn} />
    </div>
  );
}
