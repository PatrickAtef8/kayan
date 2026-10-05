import "server-only";
import { createClient as createSupabaseClient } from "@supabase/supabase-js";

/**
 * A Supabase client authenticated with the SERVICE ROLE key — it bypasses
 * Row Level Security entirely. Only ever call this from server actions or
 * route handlers, never from a Client Component, and never send its
 * result to the browser.
 *
 * Used for exactly one thing in this app: inviting a brand-new person
 * (someone with no existing Supabase Auth account) via
 * `admin.inviteUserByEmail`, which is the one operation that genuinely
 * requires elevated privileges — creating an auth.users row is not
 * possible through the normal anon-key client. See
 * src/app/dashboard/settings/team/actions.ts.
 *
 * Requires SUPABASE_SERVICE_ROLE_KEY in the environment (server-side
 * only — do NOT prefix it with NEXT_PUBLIC_). Get it from Supabase
 * dashboard → Project Settings → API → service_role key.
 */
export function createAdminClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !serviceRoleKey) {
    throw new Error(
      "SUPABASE_SERVICE_ROLE_KEY is not set. Add it to .env.local (Supabase dashboard → Project Settings → API → service_role key) to enable inviting brand-new team members."
    );
  }

  return createSupabaseClient(url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}
