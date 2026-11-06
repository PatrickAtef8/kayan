import { createClient } from "@/lib/supabase/server";
import { LandingPage } from "@/components/marketing/landing-page";
import { loadTrialOffer } from "@/lib/billing/trial.server";

// Public marketing page. It is reachable by everyone, signed in or not: a signed-in visitor sees the same page,
// but its buttons lead to the dashboard instead of login / signup — so «الصفحة التعريفية» can be opened from
// the dashboard and from the login / signup screens and there is always a way back to it.
export default async function RootPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // the «ابدأ مجانًا» button exists only while the Super Admin has the free trial switched on (and only for visitors who are not signed in)
  const offer = user ? null : await loadTrialOffer();
  return <LandingPage signedIn={!!user} trialDays={offer?.enabled ? offer.days : null} />;
}
