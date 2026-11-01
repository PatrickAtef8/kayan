// XPay signs every webhook: header `XPay-Signature: t=<unix seconds>,v1=<hex>` where v1 = HMAC-SHA256(secret, `${t}.${rawBody}`).
// (https://docs.xpay.app/en/integrate/integration-patterns/hosted-checkout#verify-the-signature)
// Pure function over node:crypto so it is unit-tested without a server. It never throws on malformed input: it answers
// {ok:false, reason} so the route can return 400 without leaking which check failed.
import { createHmac, timingSafeEqual } from "node:crypto";

export type SignatureResult = { ok: true } | { ok: false; reason: "missing" | "malformed" | "stale" | "mismatch" };

export const SIGNATURE_TOLERANCE_SECONDS = 300;

export function verifyWebhookSignature(
  rawBody: string,
  header: string | null | undefined,
  secret: string,
  nowMs: number = Date.now(),
  toleranceSeconds: number = SIGNATURE_TOLERANCE_SECONDS,
): SignatureResult {
  if (!header || !secret) return { ok: false, reason: "missing" };

  let timestamp: string | undefined;
  const candidates: string[] = [];
  for (const part of header.split(",")) {
    const i = part.indexOf("=");
    if (i < 1) continue;
    const k = part.slice(0, i).trim();
    const v = part.slice(i + 1).trim();
    if (k === "t") timestamp = v;
    else if (k === "v1") candidates.push(v);
  }
  if (!timestamp || !/^\d{1,12}$/.test(timestamp) || candidates.length === 0) return { ok: false, reason: "malformed" };

  // replay protection: a captured, correctly signed request is useless after five minutes
  if (Math.abs(nowMs / 1000 - Number(timestamp)) > toleranceSeconds) return { ok: false, reason: "stale" };

  const expected = createHmac("sha256", secret).update(`${timestamp}.${rawBody}`).digest();
  for (const c of candidates) {
    if (!/^[0-9a-fA-F]{64}$/.test(c)) continue;
    if (timingSafeEqual(Buffer.from(c, "hex"), expected)) return { ok: true };
  }
  return { ok: false, reason: "mismatch" };
}
