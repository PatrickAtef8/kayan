import "server-only";
import { createAdminClient } from "@/lib/supabase/admin";
import { TRIAL_DEFAULT_DAYS, TRIAL_MODULES, isValidTrialDays, type TrialSettings } from "./trial.ts";

// The server side of the free trial. Starting a trial is NEVER done from a browser: the database function is executable by the service
// role alone, and it re-checks that the caller is an active OWNER of the company, that trials are switched on, that the company has no
// license and no earlier trial, and that this account has not already spent its one trial.

export type StartTrialResult =
  | { ok: true; endsAt: string; days: number }
  | { ok: false; reason: "not_owner" | "disabled" | "has_license" | "already_started" | "trial_used" | "unavailable"; error: string };

const MSG: Record<string, string> = {
  not_owner: "بدء التجربة المجانية متاح لمالك الحساب فقط.",
  disabled: "التجربة المجانية غير متاحة حاليًا.",
  has_license: "لدى شركتك باقة بالفعل، فلا حاجة إلى تجربة مجانية.",
  already_started: "بدأت تجربتك المجانية من قبل ولا يمكن بدء تجربة ثانية لنفس الشركة.",
  trial_used: "استخدم هذا الحساب تجربته المجانية من قبل.",
  unavailable: "تعذّر بدء التجربة المجانية الآن. حاول مرة أخرى بعد قليل.",
};

/** The caller must already have been authenticated; `userId` is that user. Idempotent: a company that already has a trial gets "already_started". */
export async function startTrialForOwner(input: { userId: string; organizationId: string }): Promise<StartTrialResult> {
  try {
    const { data, error } = await createAdminClient().rpc("billing_start_trial", {
      p_org: input.organizationId, p_user: input.userId, p_modules: [...TRIAL_MODULES],
    });
    if (error || !data) {
      console.error("trial: billing_start_trial failed (is migration 0074 applied?)", error?.message);
      return { ok: false, reason: "unavailable", error: MSG.unavailable };
    }
    const r = data as { result?: string; ends_at?: string; days?: number };
    if (r.result === "started" && typeof r.ends_at === "string") return { ok: true, endsAt: r.ends_at, days: typeof r.days === "number" ? r.days : TRIAL_DEFAULT_DAYS };
    const reason = (["not_owner", "disabled", "has_license", "already_started", "trial_used"] as const).find((k) => k === r.result);
    return reason ? { ok: false, reason, error: MSG[reason] } : { ok: false, reason: "unavailable", error: MSG.unavailable };
  } catch (e) {
    console.error("trial: could not start", e instanceof Error ? e.message : e);
    return { ok: false, reason: "unavailable", error: MSG.unavailable };
  }
}

/**
 * Is the free trial on offer, and for how many days? Used by PUBLIC pages (home, pricing, sign-up), so it reads the platform settings with
 * the service role. Any problem (migration not applied, database unreachable) means "not offered": a button promising a trial is never shown
 * unless the database said yes.
 */
export async function loadTrialOffer(): Promise<TrialSettings> {
  try {
    const { data, error } = await createAdminClient().from("platform_billing_settings").select("trial_enabled, trial_days").eq("id", 1).maybeSingle();
    if (error || !data) return { enabled: false, days: TRIAL_DEFAULT_DAYS };
    const days = isValidTrialDays(data.trial_days) ? data.trial_days : TRIAL_DEFAULT_DAYS;
    return { enabled: data.trial_enabled === true, days };
  } catch {
    return { enabled: false, days: TRIAL_DEFAULT_DAYS };
  }
}
