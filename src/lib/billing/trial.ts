// The free trial — the pure part (no I/O) so the server, the screens and the tests share one set of rules.
//
// What a trial is: a company with no license can run the whole product for N days (N set by the Super Admin, default 15). The database
// judges it with its own clock (billing_access_state → state "trial" / "trial_expired"); when it ends the dashboard closes exactly like an
// unpaid company, nothing is deleted, and a verified payment opens it again with all the data. See docs/BILLING.md.
import { PACKAGE_MODULE_ORDER } from "../../config/pricing.config.ts";

export const TRIAL_DEFAULT_DAYS = 15;
export const TRIAL_MIN_DAYS = 1;
export const TRIAL_MAX_DAYS = 365;

/** The optional modules a trial switches on: the whole product (the three core modules need no switch). */
export const TRIAL_MODULES: readonly string[] = PACKAGE_MODULE_ORDER;

export type TrialSettings = { enabled: boolean; days: number };

export const isValidTrialDays = (n: unknown): n is number => typeof n === "number" && Number.isInteger(n) && n >= TRIAL_MIN_DAYS && n <= TRIAL_MAX_DAYS;

/** What the Super Admin typed, as readable Arabic sentences (empty = fine). */
export function validateTrialSettings(input: { enabled: unknown; days: unknown }): string[] {
  const errs: string[] = [];
  if (typeof input.enabled !== "boolean") errs.push("حدّد هل التجربة المجانية مفعّلة أم لا.");
  if (!isValidTrialDays(input.days)) errs.push(`مدة التجربة يجب أن تكون عددًا صحيحًا من ${TRIAL_MIN_DAYS} إلى ${TRIAL_MAX_DAYS} يومًا.`);
  return errs;
}

/** "١٥ يومًا" style, with the right Arabic number form. */
export function daysText(n: number): string {
  const nf = new Intl.NumberFormat("ar-EG");
  if (n === 1) return "يوم واحد";
  if (n === 2) return "يومان";
  if (n >= 3 && n <= 10) return `${nf.format(n)} أيام`;
  return `${nf.format(n)} يومًا`;
}

const DAY = 24 * 60 * 60 * 1000;

/** Whole days left, rounded UP (a trial with 3 hours left still has "1 day"). 0 when it is over. */
export function trialDaysLeft(trialEndsAt: string | null | undefined, now: Date = new Date()): number {
  if (!trialEndsAt) return 0;
  const end = new Date(trialEndsAt).getTime();
  if (Number.isNaN(end)) return 0;
  return Math.max(0, Math.ceil((end - now.getTime()) / DAY));
}

/** The short sentence shown in the banner while the trial runs. */
export function trialLeftText(secondsLeft: number): string {
  const days = Math.ceil(Math.max(0, secondsLeft) / 86400);
  if (secondsLeft <= 0) return "تنتهي الفترة التجريبية الآن";
  if (secondsLeft < 86400) return "تنتهي الفترة التجريبية خلال أقل من يوم";
  return `يتبقى ${daysText(days)} على انتهاء الفترة التجريبية`;
}

/** A trial that is about to end (3 days or less) is shown as a warning, not as information. */
export const trialIsUrgent = (secondsLeft: number): boolean => secondsLeft <= 3 * 86400;
