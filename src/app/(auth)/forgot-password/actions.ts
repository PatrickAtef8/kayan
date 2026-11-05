"use server";

import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { getSiteUrl } from "@/lib/site-url";
import { rateLimit, RATE_POLICIES } from "@/lib/rate-limit.server";
import { sendEmail, isEmailConfigured, hasRecentSend } from "@/lib/email/service.server";
import { hashRecipient } from "@/lib/email/privacy";
import { isValidEmailAddress } from "@/lib/email/config";

const GENERIC = { error: null as string | null };

/**
 * "Forgot password" — sends the reset email through the central email service (Resend) with a token_hash link to /reset-password.
 *
 * The answer never says whether the address has an account: unknown address, rate-limited, or an email-delivery problem in production all
 * return the same "if it exists, we sent a link" success. Operational problems are logged on the server (masked address, no link).
 * In development they are shown, because there the person asking is the developer.
 * If the email service is not configured at all, it falls back to Supabase's own reset email (sent by the project's SMTP settings).
 */
export async function requestPasswordReset(email: string): Promise<{ error: string | null }> {
  const to = String(email ?? "").trim().toLowerCase();
  if (!isValidEmailAddress(to)) return { error: "أدخل بريدًا إلكترونيًا صالحًا." };

  const limit = await rateLimit(RATE_POLICIES.passwordReset, hashRecipient(to).slice(0, 32));
  if (!limit.allowed) return GENERIC;

  let origin: string;
  try {
    origin = getSiteUrl();
  } catch (e) {
    console.error("password reset: site URL not configured");
    return process.env.NODE_ENV === "production" ? GENERIC : { error: e instanceof Error ? e.message : "NEXT_PUBLIC_SITE_URL غير مضبوط" };
  }

  if (!isEmailConfigured()) {
    const supabase = await createClient();
    const { error } = await supabase.auth.resetPasswordForEmail(to, { redirectTo: `${origin}/reset-password` });
    if (error) console.error("password reset (supabase fallback) failed", { code: (error as { code?: string }).code, status: (error as { status?: number }).status });
    return GENERIC;
  }

  // a second request within two minutes would issue a new one-time link and kill the first email's link
  if (await hasRecentSend("password_reset", to, 2)) return GENERIC;

  let admin;
  try {
    admin = createAdminClient();
  } catch {
    console.error("password reset: SUPABASE_SERVICE_ROLE_KEY is not set");
    return process.env.NODE_ENV === "production" ? GENERIC : { error: "SUPABASE_SERVICE_ROLE_KEY غير مضبوط" };
  }
  const gen = await admin.auth.admin.generateLink({ type: "recovery", email: to, options: { redirectTo: `${origin}/reset-password` } });
  const hashed = gen.data?.properties?.hashed_token;
  if (gen.error || !hashed) return GENERIC; // no such account (or Auth hiccup): indistinguishable from success on purpose

  const sent = await sendEmail({ template: "password_reset", to, data: { link: `${origin}/reset-password?token_hash=${encodeURIComponent(hashed)}&type=recovery` } });
  if (!sent.ok && process.env.NODE_ENV !== "production") return { error: sent.message.ar };
  return GENERIC;
}
