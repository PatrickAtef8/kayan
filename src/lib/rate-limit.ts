/**
 * Rate limiting — the pure part (no Next.js, no Supabase import), so it can be unit-tested with plain Node.
 *
 * The counter itself lives in the database (rate_limit_hit(), migration 0070): serverless instances share no memory, so an
 * in-process counter would limit nothing. The server wrapper in rate-limit.server.ts supplies the `rpc` function.
 *
 * Keys are built from an AUTHENTICATED subject (a user or organization id), never from a client-supplied header such as
 * X-Forwarded-For, which a caller can forge to get a fresh allowance on every request.
 */

export type RatePolicy = { readonly name: string; readonly windowSeconds: number; readonly max: number };

/** Generous for a human, tight for a script. Changing a number here is a pure policy change: no price, limit or module is involved. */
export const RATE_POLICIES = {
  /** Starting a payment (each one calls XPay and writes an order). Per user. */
  checkoutStart: { name: "checkout-start", windowSeconds: 600, max: 10 },
  /** Downloading the full company data export (reads every table). Per organization. */
  companyExport: { name: "company-export", windowSeconds: 3600, max: 3 },
  /** Asking XPay "was this paid?" while the return page is open (it polls). Per organization. */
  checkoutVerify: { name: "checkout-verify", windowSeconds: 60, max: 30 },
  /** Adding a team member — may send a real e-mail to an arbitrary address. Per organization. */
  teamInvite: { name: "team-invite", windowSeconds: 3600, max: 30 },
  /** Asking for a password-reset email. Keyed by the TARGET address (hashed), so nobody can mail-bomb one person; it cannot be dodged by changing IP. */
  passwordReset: { name: "password-reset", windowSeconds: 3600, max: 5 },
} as const satisfies Record<string, RatePolicy>;

export type RateLimitResult = {
  allowed: boolean;
  /** Seconds until the current window ends (0 when unknown). */
  retryAfter: number;
  /** True when the counter could not be reached or answered nonsense; `allowed` then follows `failClosed`. */
  degraded: boolean;
};

export type RateLimitRpc = (key: string, windowSeconds: number, max: number) => Promise<{ data: unknown; error: unknown }>;

export function rateLimitKey(policy: RatePolicy, subject: string): string {
  // the database refuses keys over 200 characters; subjects here are UUIDs, so this only guards against a mistake
  return `${policy.name}:${String(subject).slice(0, 150)}`;
}

/** Accepts only the exact shape rate_limit_hit() returns; anything else is "unknown", never "allowed by accident". */
export function parseHit(data: unknown): { allowed: boolean; retryAfter: number } | null {
  if (!data || typeof data !== "object") return null;
  const d = data as Record<string, unknown>;
  if (typeof d.allowed !== "boolean") return null;
  const retry = typeof d.retry_after === "number" && Number.isFinite(d.retry_after) ? Math.max(0, Math.ceil(d.retry_after)) : 0;
  return { allowed: d.allowed, retryAfter: retry };
}

/**
 * Counts one hit for `subject` under `policy`.
 * `failClosed: false` (default): if the counter is unreachable the request goes through (and `degraded` says so) — an outage of the
 * limiter must not stop a customer paying. `failClosed: true`: for operations where abuse is worse than an outage.
 */
export async function checkRateLimit(
  rpc: RateLimitRpc,
  policy: RatePolicy,
  subject: string,
  opts: { failClosed?: boolean; log?: (message: string, meta?: unknown) => void } = {},
): Promise<RateLimitResult> {
  const degraded = (why: string): RateLimitResult => {
    opts.log?.(`rate limit: counter unavailable (${why}) — ${opts.failClosed ? "refusing" : "allowing"} the request`, { policy: policy.name });
    return { allowed: !opts.failClosed, retryAfter: 0, degraded: true };
  };
  try {
    const { data, error } = await rpc(rateLimitKey(policy, subject), policy.windowSeconds, policy.max);
    if (error) return degraded("rpc error");
    const hit = parseHit(data);
    if (!hit) return degraded("unexpected reply");
    return { ...hit, degraded: false };
  } catch {
    return degraded("exception");
  }
}

/** Arabic, same tone as the rest of the application. */
export function tooManyRequestsMessage(retryAfterSeconds: number): string {
  const minutes = Math.max(1, Math.ceil((retryAfterSeconds || 60) / 60));
  const when = minutes === 1 ? "دقيقة" : minutes === 2 ? "دقيقتين" : minutes <= 10 ? `${minutes} دقائق` : `${minutes} دقيقة`;
  return `محاولات كثيرة في وقت قصير. حاول مرة أخرى بعد ${when}.`;
}
