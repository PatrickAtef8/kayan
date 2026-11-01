import { createClient } from "@/lib/supabase/server";
import { loadPricingConfig } from "@/lib/billing/config";
import { buildQuote } from "@/lib/billing/pricing";
import { parseSelection } from "@/lib/billing/selection";
import { OPTION_LABEL } from "@/lib/billing/labels";
import { formatMoney } from "@/lib/money";
import { SignupForm } from "./signup-form";

// /signup?package=…&option=… comes from the pricing page. The selection is validated HERE, on the server, against the live package
// configuration (an unknown package or option is simply ignored), and the price shown is the server's own current quote.
export default async function SignupPage({ searchParams }: { searchParams: Promise<{ package?: string; option?: string }> }) {
  const sp = await searchParams;
  const supabase = await createClient();
  const { config } = await loadPricingConfig(supabase);
  const selection = parseSelection(sp, config);
  let summary = null;
  if (selection) {
    try {
      const quote = buildQuote({ packageKey: selection.packageKey, option: selection.option, purpose: "initial" }, config);
      summary = { packageName: quote.packageName, optionLabel: OPTION_LABEL[selection.option], dueToday: `${formatMoney(quote.dueToday / 100, quote.dueToday % 100 === 0 ? 0 : 2)} ج.م` };
    } catch { /* an unquotable selection is dropped */ }
  }
  return <SignupForm selection={summary ? selection : null} summary={summary} />;
}
