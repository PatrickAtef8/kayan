// Email configuration — the pure part (no Next.js / Supabase imports) so it can be unit-tested with plain Node.
//
// Two environment variables drive everything (see .env.example and docs/EMAIL.md):
//   RESEND_API_KEY      the Resend API key (server only — never NEXT_PUBLIC_)
//   RESEND_FROM_EMAIL   the sender, either "no-reply@your-domain.com" or "Kayan <no-reply@your-domain.com>"
// The sender is NEVER hardcoded. Changing RESEND_FROM_EMAIL in Vercel (and redeploying) is all it takes to move from Resend's shared
// testing sender to your own verified domain.

export type EmailConfig = {
  apiKey: string;
  /** The exact value for the Resend `from` field, including a display name. */
  from: string;
  /** The bare address, e.g. no-reply@example.com. */
  fromAddress: string;
  /** True when the sender is on Resend's shared testing domain (resend.dev): Resend delivers those ONLY to the Resend account owner's address. */
  testingSender: boolean;
  replyTo: string | null;
};

export type EmailConfigProblem = "missing_api_key" | "missing_from" | "invalid_from" | "invalid_reply_to";

export type EmailConfigResult = { ok: true; config: EmailConfig } | { ok: false; problem: EmailConfigProblem };

const ADDRESS = /^[A-Za-z0-9._%+'-]{1,64}@([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$/;
const NO_CONTROL = /[\r\n\u0000-\u001f]/;
export const DEFAULT_SENDER_NAME = "Kayan | كيان";

export function isValidEmailAddress(value: unknown): value is string {
  return typeof value === "string" && value.length <= 254 && !NO_CONTROL.test(value) && ADDRESS.test(value.trim());
}

/** "Kayan <a@b.com>" → { name, address }; "a@b.com" → { name: null, address }. null when the shape is wrong. */
export function parseSender(value: string): { name: string | null; address: string } | null {
  const v = value.trim();
  if (!v || NO_CONTROL.test(v)) return null;
  const m = /^(.*?)\s*<([^<>]+)>$/.exec(v);
  if (m) {
    const address = m[2].trim();
    const name = m[1].trim().replace(/^"(.*)"$/, "$1").trim();
    if (!isValidEmailAddress(address)) return null;
    if (/[<>"]/.test(name)) return null;
    return { name: name || null, address };
  }
  return isValidEmailAddress(v) ? { name: null, address: v } : null;
}

export function loadEmailConfig(env: Record<string, string | undefined> = process.env): EmailConfigResult {
  const apiKey = env.RESEND_API_KEY?.trim();
  if (!apiKey) return { ok: false, problem: "missing_api_key" };
  const rawFrom = env.RESEND_FROM_EMAIL?.trim();
  if (!rawFrom) return { ok: false, problem: "missing_from" };
  const sender = parseSender(rawFrom);
  if (!sender) return { ok: false, problem: "invalid_from" };

  const replyRaw = env.RESEND_REPLY_TO?.trim();
  if (replyRaw && !isValidEmailAddress(replyRaw)) return { ok: false, problem: "invalid_reply_to" };

  const name = sender.name ?? DEFAULT_SENDER_NAME;
  return {
    ok: true,
    config: {
      apiKey,
      from: `${name} <${sender.address}>`,
      fromAddress: sender.address,
      testingSender: sender.address.toLowerCase().endsWith("@resend.dev"),
      replyTo: replyRaw || null,
    },
  };
}

/** What to tell a developer / the owner about a configuration problem (no secrets involved). */
export function describeConfigProblem(problem: EmailConfigProblem): string {
  switch (problem) {
    case "missing_api_key": return "RESEND_API_KEY is not set — add it in the environment variables (Vercel → Settings → Environment Variables) and redeploy.";
    case "missing_from": return "RESEND_FROM_EMAIL is not set — for development use Resend's testing sender, after domain verification use an address on your domain.";
    case "invalid_from": return "RESEND_FROM_EMAIL is not a valid address. Use name@domain.com or \"Kayan <name@domain.com>\".";
    case "invalid_reply_to": return "RESEND_REPLY_TO is not a valid email address.";
  }
}
