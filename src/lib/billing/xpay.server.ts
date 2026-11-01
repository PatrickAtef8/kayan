import { validateXpayBaseUrl } from "./xpay-base-url";
import "server-only";
import { createXpayClient, type XpayApi } from "./xpay-client.ts";

// The ONLY place the XPay secrets are read. "server-only" makes the build fail if a client component ever imports this
// file (directly or through another module), so a secret can never be bundled into browser code. Neither variable
// has the NEXT_PUBLIC_ prefix, so Next.js would not expose them to the browser either.
//
//   XPAY_SECRET_KEY      sk_test_… (test mode) or sk_live_… — Dashboard → Developer → API Keys
//   XPAY_WEBHOOK_SECRET  whsec_…  — the signing secret of the webhook endpoint you create for /api/webhooks/xpay
//   XPAY_API_BASE_URL    optional, defaults to https://api.xpay.app

export class BillingConfigError extends Error {}

export function xpaySecretKey(): string {
  const key = process.env.XPAY_SECRET_KEY?.trim();
  if (!key) throw new BillingConfigError("XPAY_SECRET_KEY is not set");
  if (!/^sk_(test|live)_[A-Za-z0-9_-]+$/.test(key)) throw new BillingConfigError("XPAY_SECRET_KEY does not look like an XPay secret key (sk_test_… / sk_live_…)");
  return key;
}

export function xpayWebhookSecret(): string {
  const secret = process.env.XPAY_WEBHOOK_SECRET?.trim();
  if (!secret) throw new BillingConfigError("XPAY_WEBHOOK_SECRET is not set");
  return secret;
}

/** true when the configured key is a TEST key (no real money moves) */
export function xpayIsTestMode(): boolean {
  try { return xpaySecretKey().startsWith("sk_test_"); } catch { return false; }
}

export function xpayIsConfigured(): boolean {
  try { xpaySecretKey(); return true; } catch { return false; }
}

/** The validated override, or undefined for the default (https://api.xpay.app). */
function xpayBaseUrl(): string | undefined {
  try {
    return validateXpayBaseUrl(process.env.XPAY_API_BASE_URL, process.env.NODE_ENV === "production");
  } catch (e) {
    throw new BillingConfigError(e instanceof Error ? e.message : "XPAY_API_BASE_URL is invalid");
  }
}

let cached: { key: string; client: XpayApi } | null = null;

export function getXpay(): XpayApi {
  const key = xpaySecretKey();
  if (!cached || cached.key !== key) {
    cached = { key, client: createXpayClient({ secretKey: key, baseUrl: xpayBaseUrl() }) };
  }
  return cached.client;
}

/**
 * In production, checkout stays closed until the owner of the product confirms that the prices in
 * src/config/pricing.config.ts are the real ones (the ones shipped in the repository are placeholders).
 */
export function pricesConfirmed(): boolean {
  return process.env.NODE_ENV !== "production" || process.env.BILLING_PRICES_CONFIRMED === "true";
}
