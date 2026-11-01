// What a company's subscription means RIGHT NOW. The authority is the database (billing_access_state() in migration 0063, judged
// by the database clock); this file only (a) reads that answer safely and (b) mirrors the same rules in pure form so the tests can
// pin the boundaries and the UI can count down without asking again.
//
//   none          never paid                                     closed
//   free          complimentary access granted by the platform    open
//   license_only  a license with no end date                      open
//   active        now <= paid_through                             open
//   grace         paid_through < now <= paid_through + grace      open  (the dashboard shows a warning with the time left)
//   expired       now >  paid_through + grace                     closed
// grace = grace_hours when the grace period is enabled, else 0 (0 hours also means "lock immediately").
export type AccessState = "none" | "free" | "license_only" | "active" | "grace" | "expired";

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;
export const OPEN_STATES: readonly AccessState[] = ["free", "license_only", "active", "grace"];
export const isOpenState = (s: AccessState) => OPEN_STATES.includes(s);

export type GraceSettings = { graceEnabled: boolean; graceHours: number };

/** Pure mirror of the SQL judgement (used by tests and by display code that has no database answer at hand). */
export function evaluateAccess(
  license: { complimentary?: boolean | null; access_paid_through: string | null } | null,
  now: Date,
  grace: GraceSettings,
): AccessState {
  if (!license) return "none";
  if (license.complimentary) return "free";
  if (!license.access_paid_through) return "license_only";
  const through = new Date(license.access_paid_through).getTime();
  if (Number.isNaN(through)) return "license_only";
  const hours = grace.graceEnabled ? grace.graceHours : 0;
  if (now.getTime() <= through) return "active";
  if (now.getTime() <= through + hours * HOUR) return "grace";
  return "expired";
}

/** The database's verdict (my_org_access().access), as the application uses it. */
export type DbAccess = {
  state: AccessState;
  open: boolean;
  paidThrough: string | null;
  graceEndsAt: string | null;
  secondsLeft: number | null;
  graceEnabled: boolean;
  graceHours: number;
  serverNow: string | null;
};

const STATES: readonly string[] = ["none", "free", "license_only", "active", "grace", "expired"];

export function parseDbAccess(raw: unknown): DbAccess | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  if (typeof r.state !== "string" || !STATES.includes(r.state)) return null;
  const str = (v: unknown) => (typeof v === "string" ? v : null);
  return {
    state: r.state as AccessState,
    open: r.open === true,
    paidThrough: str(r.paid_through),
    graceEndsAt: str(r.grace_ends_at),
    secondsLeft: typeof r.seconds_left === "number" ? r.seconds_left : null,
    graceEnabled: r.grace_enabled !== false,
    graceHours: typeof r.grace_hours === "number" ? r.grace_hours : 24,
    serverNow: str(r.server_now),
  };
}

/** Whole days until the paid-through date (negative once it has passed). */
export function daysUntil(iso: string | null, now: Date = new Date()): number | null {
  if (!iso) return null;
  const t = new Date(iso).getTime();
  if (Number.isNaN(t)) return null;
  return Math.ceil((t - now.getTime()) / DAY);
}

/** "٢٣ ساعة و١٥ دقيقة" style remaining time, for the grace warning. */
export function remainingText(totalSeconds: number): string {
  const s = Math.max(0, Math.floor(totalSeconds));
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  const nf = new Intl.NumberFormat("ar-EG");
  const parts: string[] = [];
  if (d) parts.push(`${nf.format(d)} ${d === 1 ? "يوم" : d === 2 ? "يومان" : "أيام"}`);
  if (h) parts.push(`${nf.format(h)} ${h === 1 ? "ساعة" : h === 2 ? "ساعتان" : h <= 10 ? "ساعات" : "ساعة"}`);
  if (!d && (m || !h)) parts.push(`${nf.format(m)} ${m === 1 ? "دقيقة" : m === 2 ? "دقيقتان" : m <= 10 ? "دقائق" : "دقيقة"}`);
  return parts.join(" و");
}
