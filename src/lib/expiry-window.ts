// Expiry windows are stored as a number of days (what the database takes) but people think in months and years:
// a product can legitimately expire in three years. These helpers turn days into natural Arabic and back.

const arNum = (n: number) => n.toLocaleString("ar-EG", { useGrouping: false });

export const MAX_WINDOW_DAYS = 3650; // 10 years — the limit the database accepts

export const WINDOW_PRESETS: { days: number; label: string }[] = [
  { days: 30, label: "شهر" },
  { days: 90, label: "٣ أشهر" },
  { days: 180, label: "٦ أشهر" },
  { days: 365, label: "سنة" },
  { days: 730, label: "سنتان" },
  { days: 1095, label: "٣ سنوات" },
  { days: 1825, label: "٥ سنوات" },
];

function monthsText(m: number): string {
  if (m === 1) return "شهر";
  if (m === 2) return "شهران";
  return m <= 10 ? `${arNum(m)} أشهر` : `${arNum(m)} شهرًا`;
}
function yearsText(y: number): string {
  if (y === 1) return "سنة";
  if (y === 2) return "سنتان";
  return y <= 10 ? `${arNum(y)} سنوات` : `${arNum(y)} سنة`;
}
function daysText(d: number): string {
  if (d === 1) return "يوم";
  if (d === 2) return "يومان";
  return d <= 10 ? `${arNum(d)} أيام` : `${arNum(d)} يومًا`;
}

/** The size of a window: 365 → "سنة", 1095 → "٣ سنوات", 90 → "٣ أشهر", 45 → "٤٥ يومًا". */
export function windowLabel(days: number): string {
  if (days >= 365 && days % 365 === 0) return yearsText(days / 365);
  if (days >= 30 && days % 30 === 0) return monthsText(days / 30);
  return daysText(days);
}

/** A time left (or passed) in the most natural unit: "٤٥ يومًا", "٨ أشهر", "سنتان و٣ أشهر". */
export function spanLabel(days: number): string {
  const d = Math.abs(Math.round(days));
  if (d < 60) return daysText(d);
  if (d < 365) return monthsText(Math.round(d / 30));
  let y = Math.floor(d / 365);
  let m = Math.round((d - y * 365) / 30);
  if (m >= 12) { y += 1; m = 0; }
  return m > 0 ? `${yearsText(y)} و${monthsText(m)}` : yearsText(y);
}

/** Custom value + unit → days, clamped to 1 … MAX_WINDOW_DAYS. */
export function toDays(value: number, unit: "day" | "month" | "year"): number {
  const per = unit === "year" ? 365 : unit === "month" ? 30 : 1;
  return Math.min(Math.max(Math.round(value * per), 1), MAX_WINDOW_DAYS);
}
