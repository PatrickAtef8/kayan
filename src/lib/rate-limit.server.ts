import "server-only";
import { createAdminClient } from "@/lib/supabase/admin";
import { checkRateLimit, type RateLimitResult, type RatePolicy } from "./rate-limit";

export { RATE_POLICIES, tooManyRequestsMessage } from "./rate-limit";

/** Counts one hit for `subject` (a user or organization id — never a client-supplied value) under `policy`. */
export async function rateLimit(policy: RatePolicy, subject: string, opts: { failClosed?: boolean } = {}): Promise<RateLimitResult> {
  const log = (m: string, meta?: unknown) => console.error(m, meta ?? {});
  let admin;
  try {
    admin = createAdminClient();
  } catch {
    log("rate limit: the server key is not configured", { policy: policy.name });
    return { allowed: !opts.failClosed, retryAfter: 0, degraded: true };
  }
  const rpc = async (key: string, windowSeconds: number, max: number) => {
    const { data, error } = await admin.rpc("rate_limit_hit", { p_key: key, p_window_seconds: windowSeconds, p_max: max });
    return { data: data as unknown, error: error as unknown };
  };
  return checkRateLimit(rpc, policy, subject, { ...opts, log });
}
