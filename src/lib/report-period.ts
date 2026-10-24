// One period model for the dashboard home and every report that has a period picker.
//
// URL contract (all optional, anything invalid falls back to the current month):
//   ?period=month&m=2025-03   one specific month      (no `m` → this month)
//   ?period=year&y=2025       one specific year       (no `y` → this year)
//   ?period=all               every period
//
// Dates are the business calendar in Cairo, not UTC, and the "current" month/year keep `to = null`
// (open-ended) exactly as before, so today's numbers don't change. A past month/year gets a closed range,
// which is what lets people open data they entered for months before the system was in use.

export type ReportPeriod = "month" | "year" | "all";

export type PeriodParams = { period?: string; m?: string; y?: string };

export type PeriodSel = {
  kind: ReportPeriod;
  from: string | null;
  to: string | null;
  /** YYYY-MM when kind = month */
  month: string | null;
  /** YYYY when kind = year */
  year: string | null;
  /** true for the current month / current year (open-ended range) */
  isCurrent: boolean;
  /** short, for card notes: "هذا الشهر" / "مارس ٢٠٢٥" */
  label: string;
  /** always explicit, for the picker button and headings: "أكتوبر ٢٠٢٦" */
  title: string;
};

export const MIN_YEAR = 2000;

export const MONTH_NAMES: string[] = Array.from({ length: 12 }, (_, i) => new Date(Date.UTC(2020, i, 1)).toLocaleDateString("ar-EG", { month: "long", timeZone: "UTC" }));

export const cairoDate = () => new Date().toLocaleDateString("en-CA", { timeZone: "Africa/Cairo" }); // YYYY-MM-DD

export const yearText = (y: number | string) => Number(y).toLocaleString("ar-EG", { useGrouping: false });
export const monthTitle = (ym: string) => `${MONTH_NAMES[Number(ym.slice(5, 7)) - 1]} ${yearText(ym.slice(0, 4))}`;
export const yearTitle = (y: number | string) => `عام ${yearText(y)}`;

export function resolvePeriod(sp: PeriodParams, today: string = cairoDate()): PeriodSel {
  const cy = Number(today.slice(0, 4));
  const curMonth = today.slice(0, 7);

  if (sp.period === "all") {
    return { kind: "all", from: null, to: null, month: null, year: null, isCurrent: false, label: "كل الوقت", title: "كل الوقت" };
  }

  if (sp.period === "year") {
    const asked = /^\d{4}$/.test(sp.y ?? "") ? Number(sp.y) : cy;
    const y = Math.min(cy, Math.max(MIN_YEAR, asked));
    const isCurrent = y === cy;
    return {
      kind: "year",
      from: `${y}-01-01`,
      to: isCurrent ? null : `${y}-12-31`,
      month: null,
      year: String(y),
      isCurrent,
      label: isCurrent ? "هذا العام" : yearTitle(y),
      title: yearTitle(y),
    };
  }

  let ym = /^\d{4}-(0[1-9]|1[0-2])$/.test(sp.m ?? "") ? (sp.m as string) : curMonth;
  if (Number(ym.slice(0, 4)) < MIN_YEAR || ym > curMonth) ym = curMonth; // YYYY-MM compares correctly as text
  const isCurrent = ym === curMonth;
  const last = new Date(Date.UTC(Number(ym.slice(0, 4)), Number(ym.slice(5, 7)), 0)).getUTCDate();
  return {
    kind: "month",
    from: `${ym}-01`,
    to: isCurrent ? null : `${ym}-${String(last).padStart(2, "0")}`,
    month: ym,
    year: null,
    isCurrent,
    label: isCurrent ? "هذا الشهر" : monthTitle(ym),
    title: monthTitle(ym),
  };
}

/** The query string that reproduces this period — for links that must keep it (tabs, group switchers…). */
export function periodQuery(sel: PeriodSel): string {
  if (sel.kind === "all") return "period=all";
  if (sel.kind === "year") return sel.isCurrent ? "period=year" : `period=year&y=${sel.year}`;
  return sel.isCurrent ? "period=month" : `period=month&m=${sel.month}`;
}

export function periodRange(sel: PeriodSel): { from: string | null; to: string | null } {
  return { from: sel.from, to: sel.to };
}
