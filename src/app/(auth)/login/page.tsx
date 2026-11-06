import { createClient } from "@/lib/supabase/server";
import { loadPricingConfig } from "@/lib/billing/config";
import { parseSelection } from "@/lib/billing/selection";
import { LoginForm } from "./login-form";

// /login?confirmed=1 is where the email-confirmation link lands when it cannot start a session itself.
// /login?plan=… keeps a plan chosen on /pricing (validated here, on the server) for after the login.
export default async function LoginPage({ searchParams }: { searchParams: Promise<{ confirmed?: string; plan?: string; package?: string; option?: string }> }) {
  const sp = await searchParams;
  const { config } = await loadPricingConfig(await createClient());
  return <LoginForm confirmed={sp.confirmed === "1"} selection={parseSelection(sp, config)} />;
}
