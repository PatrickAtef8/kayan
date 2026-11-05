// Subscription-expiry reminders — the pure planning part (no database, no email), so the Cairo day boundaries can be pinned by tests.
//
// A company's access runs until `access_paid_through` (an instant). People think in calendar days in Cairo, so "days left" is counted on
// the Cairo calendar: the licence ending at 23:30 Cairo time on the 10th is "ending today" for the whole of the 10th, in every season.
//
// Reminders go out once per threshold: 7, 3 and 1 day before, on the day itself, and once after it ended. The threshold is the
// smallest one the company has already reached, so a day the job did not run (deploy, outage) does not skip a reminder — and the
// email log's unique key (template + organization + end date + threshold) guarantees no repeat. Paying extends the end date,
// which changes the key and re-arms the cycle by itself.

export const REMINDER_THRESHOLDS = [7, 3, 1, 0] as const;
export type ReminderThreshold = (typeof REMINDER_THRESHOLDS)[number] | "ended";
/** How long after the end date the single "it has ended" notice may still be sent. */
export const ENDED_NOTICE_DAYS = 7;

export const cairoDayOf = (instant: Date): string => instant.toLocaleDateString("en-CA", { timeZone: "Africa/Cairo" }); // YYYY-MM-DD

/** Whole calendar days from `fromDay` to `toDay` (both YYYY-MM-DD); positive when toDay is later. */
export function daysBetween(fromDay: string, toDay: string): number {
  const a = Date.parse(`${fromDay}T00:00:00Z`);
  const b = Date.parse(`${toDay}T00:00:00Z`);
  return Math.round((b - a) / 86_400_000);
}

export type ReminderPlan = { daysLeft: number; endsOn: string; threshold: ReminderThreshold; dedupeKey: string };

export function planReminder(orgId: string, paidThrough: string | null | undefined, now: Date): ReminderPlan | null {
  if (!paidThrough) return null;
  const end = new Date(paidThrough);
  if (Number.isNaN(end.getTime())) return null;
  const endsOn = cairoDayOf(end);
  const daysLeft = daysBetween(cairoDayOf(now), endsOn);

  let threshold: ReminderThreshold | null = null;
  if (daysLeft < 0) {
    if (-daysLeft <= ENDED_NOTICE_DAYS) threshold = "ended";
  } else {
    // smallest threshold the company has reached: 5 days left → 7, 2 → 3, 1 → 1, 0 → 0
    threshold = [...REMINDER_THRESHOLDS].reverse().find((t) => daysLeft <= t) ?? null;
  }
  if (threshold === null) return null;
  return { daysLeft, endsOn, threshold, dedupeKey: `renewal:${orgId}:${endsOn}:${threshold}` };
}
