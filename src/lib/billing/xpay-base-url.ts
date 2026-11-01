/**
 * XPAY_API_BASE_URL is optional (the default is https://api.xpay.app) but it is where the SECRET KEY is sent as a bearer token.
 * A wrong or tampered value would hand the key to someone else, so it is validated instead of trusted:
 *   · https only (plain http is accepted for localhost outside production, to point at a local mock);
 *   · no user:password@ part;
 *   · in production the host must be xpay.app or one of its sub-domains.
 * Pure (no Next.js import) so it is unit-tested with plain Node.
 */
export function validateXpayBaseUrl(raw: string | undefined, isProduction: boolean): string | undefined {
  const value = raw?.trim();
  if (!value) return undefined;
  let url: URL;
  try { url = new URL(value); } catch { throw new Error("XPAY_API_BASE_URL is not a valid URL"); }
  if (url.username || url.password) throw new Error("XPAY_API_BASE_URL must not contain credentials");
  const local = url.hostname === "localhost" || url.hostname === "127.0.0.1";
  if (url.protocol !== "https:" && !(url.protocol === "http:" && local && !isProduction)) {
    throw new Error("XPAY_API_BASE_URL must use https");
  }
  if (isProduction && !(url.hostname === "xpay.app" || url.hostname.endsWith(".xpay.app"))) {
    throw new Error("XPAY_API_BASE_URL must be an xpay.app host in production");
  }
  return value;
}
