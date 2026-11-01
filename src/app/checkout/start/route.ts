import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { loadPricingConfig } from "@/lib/billing/config";
import { checkoutPath, selectionFromMetadata } from "@/lib/billing/selection";

// The "I chose a package before I had an account" hand-off for people who confirmed their email first: the dashboard created their
// company, found it unpaid, and sent them to the billing page, which sends them here. The choice remembered in their account metadata is
// validated against the live packages, used ONCE (the metadata is cleared), and turned into the normal /checkout URL — which rebuilds
// the quote on the server. A missing / invalid choice just lands on the package chooser.
export async function GET(request: NextRequest) {
  const { origin } = new URL(request.url);
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return NextResponse.redirect(`${origin}/login`);
  const { config } = await loadPricingConfig(supabase);
  const selection = selectionFromMetadata(user.user_metadata, config);
  if (!selection) return NextResponse.redirect(`${origin}/dashboard/billing`);
  const { error } = await supabase.auth.updateUser({ data: { plan_selection: null } });
  if (error) console.error("checkout/start: could not clear the remembered package", error.message);
  return NextResponse.redirect(`${origin}${checkoutPath(selection)}`);
}
