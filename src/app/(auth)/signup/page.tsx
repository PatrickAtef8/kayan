import { createClient } from "@/lib/supabase/server";
import { loadPricingConfig } from "@/lib/billing/config";
import { buildQuote } from "@/lib/billing/pricing";
import { parseSelection } from "@/lib/billing/selection";
import { formatMoney } from "@/lib/money";
import { loadTrialOffer } from "@/lib/billing/trial.server";
import { SignupForm } from "./signup-form";

// /signup?plan=… comes from the pricing page. The selection is validated HERE, on the server, against the live plan
// configuration (an unknown plan is simply ignored), and the price shown is the server's own current quote.
export default async function SignupPage({ searchParams }: { searchParams: Promise<{ plan?: string; package?: string; option?: string; trial?: string }> }) {
  const sp = await searchParams;
  const supabase = await createClient();
  const [{ config }, offer] = await Promise.all([loadPricingConfig(supabase), sp.trial === "1" ? loadTrialOffer() : Promise.resolve(null)]);
  const selection = parseSelection(sp, config);
  // /signup?trial=1 is the «ابدأ مجانًا» button. It is honoured only while the Super Admin has the trial switched on (the database decides again
  // when the trial actually starts), and never together with a chosen paid plan.
  const trial = offer && offer.enabled && !selection ? { days: offer.days } : null;
  let summary = null;
  if (selection) {
    try {
      const quote = buildQuote({ plan: selection.plan, purpose: "initial" }, config);
      summary = { packageName: quote.packageName, dueToday: `${formatMoney(quote.dueToday / 100, quote.dueToday % 100 === 0 ? 0 : 2)} ج.م` };
    } catch { /* an unquotable selection is dropped */ }
  }
  return <SignupForm selection={summary ? selection : null} summary={summary} trial={trial} />;
}
