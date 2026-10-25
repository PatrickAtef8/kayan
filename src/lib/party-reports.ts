import { formatMoney } from "@/lib/money";
// Shared by the Phase 5 account reports (debts sub-pages and the statement).
export const money = (n: number | null | undefined) => formatMoney(n);
export const qty = (n: number | null | undefined) => Number(n ?? 0).toLocaleString("ar-EG", { maximumFractionDigits: 3 });
export const dateText = (d: string | null | undefined) =>
  d ? new Date(d + "T00:00:00").toLocaleDateString("ar-EG", { year: "numeric", month: "short", day: "numeric" }) : "—";

export const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;
export const isoOrNull = (v: string | undefined) => (v && ISO_DATE.test(v) ? v : null);
export const cairoToday = () => new Date().toLocaleDateString("en-CA", { timeZone: "Africa/Cairo" });

export const STATUS_LABEL: Record<string, string> = {
  opening: "رصيد افتتاحي",
  credit: "رصيد دائن (دفعة مقدمة)",
  settled: "مسدّدة",
  open: "مفتوحة",
  overdue: "متأخرة",
};
export const STATUS_STYLE: Record<string, string> = {
  opening: "bg-paper text-charcoal/60",
  credit: "bg-sageSoft text-sage",
  settled: "bg-sageSoft text-sage",
  open: "bg-paper text-charcoal/60",
  overdue: "bg-rose/10 text-rose",
};
