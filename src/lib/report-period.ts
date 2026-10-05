export type ReportPeriod = "month" | "year" | "all";

export const PERIOD_OPTIONS: { value: ReportPeriod; label: string }[] = [
  { value: "month", label: "هذا الشهر" },
  { value: "year", label: "هذا العام" },
  { value: "all", label: "كل الوقت" },
];

export function periodRange(period: ReportPeriod): { from: string | null; to: string | null } {
  const now = new Date();
  if (period === "month") return { from: new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString().slice(0, 10), to: null };
  if (period === "year") return { from: new Date(Date.UTC(now.getUTCFullYear(), 0, 1)).toISOString().slice(0, 10), to: null };
  return { from: null, to: null };
}
