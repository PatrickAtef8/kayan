// Production guards for the XPay configuration. Pure (no Next.js import) so plain Node can test every combination.
//
// "Real production" = NODE_ENV=production AND (not on Vercel OR VERCEL_ENV=production). Vercel *preview* deployments also run with
// NODE_ENV=production, but they are where test keys belong — so they are not treated as live.
//
// Only sends / refuses; it never reads a secret's value into a message.

export type Env = Record<string, string | undefined>;

export function isRealProduction(env: Env): boolean {
  if (env.NODE_ENV !== "production") return false;
  return !env.VERCEL_ENV || env.VERCEL_ENV === "production";
}

export type GuardReport = { realProduction: boolean; mode: "test" | "live" | "unset"; blocking: string[]; warnings: string[] };

export function checkXpayConfig(env: Env): GuardReport {
  const real = isRealProduction(env);
  const key = env.XPAY_SECRET_KEY?.trim() ?? "";
  const mode: GuardReport["mode"] = key.startsWith("sk_live_") ? "live" : key.startsWith("sk_test_") ? "test" : "unset";
  const blocking: string[] = [];
  const warnings: string[] = [];

  if (!key) blocking.push("XPAY_SECRET_KEY is not set.");
  else if (mode === "unset") blocking.push("XPAY_SECRET_KEY does not look like an XPay secret key (sk_live_… / sk_test_…).");
  if (real && mode === "test") blocking.push("XPAY_SECRET_KEY is a TEST key (sk_test_…) in production: payments would not move real money. Use the sk_live_… key.");

  const hook = env.XPAY_WEBHOOK_SECRET?.trim() ?? "";
  if (!hook) blocking.push("XPAY_WEBHOOK_SECRET is not set: payments cannot be confirmed by webhook. Create the live webhook for /api/webhooks/xpay and copy its signing secret.");
  else if (!hook.startsWith("whsec_")) warnings.push("XPAY_WEBHOOK_SECRET does not start with whsec_ — check you copied the webhook signing secret, not an API key.");

  if (real && env.BILLING_PRICES_CONFIRMED !== "true") blocking.push("BILLING_PRICES_CONFIRMED is not \"true\": checkout stays closed until the real prices in src/config/pricing.config.ts are confirmed.");
  if (real && !env.NEXT_PUBLIC_SITE_URL?.trim()) warnings.push("NEXT_PUBLIC_SITE_URL is not set: return URLs fall back to VERCEL_PROJECT_PRODUCTION_URL.");
  if (real && env.NEXT_PUBLIC_SITE_URL && !/^https:\/\//i.test(env.NEXT_PUBLIC_SITE_URL.trim())) warnings.push("NEXT_PUBLIC_SITE_URL should start with https:// in production.");

  return { realProduction: real, mode, blocking, warnings };
}

/** Throws (message safe to show) when the key may not be used in this environment. */
export function assertKeyAllowed(env: Env): void {
  const key = env.XPAY_SECRET_KEY?.trim() ?? "";
  if (isRealProduction(env) && key.startsWith("sk_test_")) {
    throw new Error("XPAY_SECRET_KEY is a test key (sk_test_…) but this is a production deployment. Set the live key (sk_live_…) in the production environment variables.");
  }
}
