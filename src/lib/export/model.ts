// One description of "a report to export", shared by the Excel and the PDF builders so both files always show
// the same numbers, the same columns and the same totals (§56).
//
// Call sites keep passing `headers` + `rows` (as before) and now ALSO say what each column is (`kinds`), which is
// what lets us write real numbers / real dates in Excel and align + format them properly in the PDF.

export type Cell = string | number | null | undefined;

/**
 * text    names, descriptions (right-to-left, wraps)
 * code    SKU, barcode, phone, reference — kept as text (leading zeros survive), always left-to-right
 * date    "YYYY-MM-DD" → a real Excel date
 * int     whole numbers (counts)
 * qty     quantities — decimals only when the data has them
 * money   amounts, always 2 decimals, negative in red
 * percent a share in percent points (12.5 means 12.5 %)
 */
export type ColumnKind = "text" | "code" | "date" | "int" | "qty" | "money" | "percent";
/** A kind, optionally followed by ":sum" to get a total in the last row — e.g. "money:sum". */
export type KindSpec = ColumnKind | `${ColumnKind}:sum`;

export type SummaryItem = { label: string; value: Cell; kind?: ColumnKind };

export type ExportSpec = {
  /** File name without extension (a safe version is used for the download). */
  filename: string;
  /** Report title shown at the top of the document. */
  title: string;
  /** Period / filter description under the title, e.g. "الفترة: أكتوبر ٢٠٢٦". */
  subtitle?: string;
  headers: string[];
  rows: Cell[][];
  /** One entry per header. Missing → inferred from the data. */
  kinds?: KindSpec[];
  /** Key figures shown above the table (own sheet in Excel). */
  summary?: SummaryItem[];
  /** Footnotes printed under the table. */
  notes?: string[];
  /** Company name (from the signed-in organisation). */
  orgName?: string;
};

export type Column = {
  header: string;
  kind: ColumnKind;
  sum: boolean;
  /** Digits after the decimal point (money 2, int 0, qty/percent from the data). */
  decimals: number;
  numeric: boolean;
};

/**
 * A PDF is laid out in the browser, text by text (about 20 ms per row of 9 columns), so very long reports would freeze the
 * tab for a long time. Above this many rows the PDF button explains that and points to Excel, which has no such limit.
 */
export const MAX_PDF_ROWS = 800;

/** What a list export asks the server for (the same filters the page itself uses) and what it gets back. */
export type ListFilters = { q?: string; from?: string; to?: string };
export type ListResult = { ok: true; rows: Cell[][]; note?: string } | { ok: false; error: string };

export const BRAND = "كيان";
export const PRODUCT_LINE = "كيان — نظام إدارة الأعمال";

// Control characters are illegal in XML (xlsx) and render as boxes in a PDF; direction marks (U+2066..2069, used by
// formatMoney for the on-screen text) would show up as stray glyphs in a PDF, so they are removed from every string.
const BAD_CHARS = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u2066-\u2069\u200E\u200F\u202A-\u202E]/g;
export function cleanText(value: string): string {
  return value.replace(BAD_CHARS, "").trim();
}

const ISO_DATE = /^\d{4}-\d{2}-\d{2}(?:$|[T ])/;
export const isIsoDate = (v: unknown): v is string => typeof v === "string" && ISO_DATE.test(v);
export const isoDay = (v: string) => v.slice(0, 10);

function isBlank(v: Cell): boolean {
  return v === null || v === undefined || (typeof v === "string" && v.trim() === "");
}

/** Numeric value of a cell, or null when the cell is empty / not a number. */
export function numberOf(v: Cell): number | null {
  if (typeof v === "number") return Number.isFinite(v) ? v : null;
  if (typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v))) return Number(v);
  return null;
}

/** Fewest decimals (up to `max`) that show every value exactly: [1, 2.5] → 1, [1, 2] → 0, [0.125] with max 3 → 3. */
function decimalsIn(values: number[], max: number): number {
  let needed = 0;
  for (const v of values) {
    let d = 0;
    while (d < max && Math.abs(v * 10 ** d - Math.round(v * 10 ** d)) > 1e-6) d++;
    if (d > needed) needed = d;
    if (needed >= max) break;
  }
  return needed;
}

function inferKind(values: Cell[]): ColumnKind {
  const present = values.filter((v) => !isBlank(v));
  if (present.length === 0) return "text";
  if (present.every((v) => typeof v === "number" && Number.isFinite(v))) {
    return present.every((v) => Number.isInteger(v as number)) ? "int" : "qty";
  }
  if (present.every(isIsoDate)) return "date";
  return "text";
}

export function resolveColumns(spec: Pick<ExportSpec, "headers" | "rows" | "kinds">): Column[] {
  return spec.headers.map((header, i) => {
    const raw = spec.kinds?.[i];
    const values = spec.rows.map((r) => r[i]);
    const explicit = raw ? (raw.split(":")[0] as ColumnKind) : null;
    const kind = explicit ?? inferKind(values);
    const sum = !!raw && raw.endsWith(":sum");
    const numeric = kind === "int" || kind === "qty" || kind === "money" || kind === "percent";
    const nums = numeric ? values.map(numberOf).filter((n): n is number => n !== null) : [];
    const decimals = kind === "money" ? 2 : kind === "int" ? 0 : kind === "qty" ? decimalsIn(nums, 3) : kind === "percent" ? decimalsIn(nums, 1) : 0;
    return { header: cleanText(header), kind, sum: sum && numeric, decimals, numeric };
  });
}

/** Total of a numeric column (rounded so 0.1 + 0.2 shows as 0.3). */
export function columnTotal(col: Column, rows: Cell[][], index: number): number {
  let t = 0;
  for (const r of rows) t += numberOf(r[index]) ?? 0;
  return Math.round(t * 1e6) / 1e6;
}

/** "١٬٢٥٠٫٥٠" — the app's own digit style (Arabic-Indic, see money.ts), WITHOUT direction marks (PDF fonts don't draw them). */
export function formatNumber(n: number, decimals: number): string {
  const rounded = Number(n.toFixed(decimals));
  const digits = Math.abs(rounded).toLocaleString("ar-EG", { minimumFractionDigits: decimals, maximumFractionDigits: decimals });
  return `${rounded < 0 ? "-" : ""}${digits}`;
}

/** Display text of one cell for the PDF (Excel gets real typed cells instead). Empty → "". */
export function displayCell(v: Cell, col: Column): string {
  if (isBlank(v)) return "";
  if (col.numeric) {
    const n = numberOf(v);
    if (n === null) return cleanText(String(v));
    return formatNumber(n, col.decimals) + (col.kind === "percent" ? "٪" : "");
  }
  if (col.kind === "date" && isIsoDate(v)) return isoDay(v);
  return cleanText(String(v));
}

export function isNegative(v: Cell, col: Column): boolean {
  if (!col.numeric) return false;
  const n = numberOf(v);
  return n !== null && Number(n.toFixed(col.decimals)) < 0;
}

/** A file name that every operating system accepts. */
export function safeFileName(name: string, ext: string): string {
  const base =
    cleanText(name)
      .replace(/[\\/:*?"<>|]+/g, "-")
      .replace(/\s+/g, " ")
      .replace(/^[.\s-]+|[.\s-]+$/g, "")
      .slice(0, 120) || "تقرير";
  return `${base}.${ext}`;
}

/** Title from a file name when a call site gave none: "مبيعات-الأصناف-2026-01-01-الآن" → "مبيعات الأصناف". */
export function titleFromFilename(filename: string): string {
  const t = filename
    .replace(/-?\d{4}-\d{2}(-\d{2})?.*$/, "")
    .replace(/-(الكل|الآن)(-.*)?$/, "")
    .replace(/-+/g, " ")
    .trim();
  return t || filename;
}

/** "من ٢٠٢٦-٠١-٠١ إلى ٢٠٢٦-١٠-٢٥" — the period line of a report; open ends read naturally. */
export function rangeText(from?: string | null, to?: string | null): string {
  if (from && to) return `الفترة: من ${from} إلى ${to}`;
  if (from) return `الفترة: من ${from}`;
  if (to) return `الفترة: حتى ${to}`;
  return "الفترة: كل الوقت";
}

/** "28 أكتوبر 2026 — 3:45 م" in Cairo time (the business calendar of the app). */
export function generatedAtText(now: Date = new Date()): string {
  return new Intl.DateTimeFormat("ar-EG", { dateStyle: "long", timeStyle: "short", timeZone: "Africa/Cairo" }).format(now);
}

export function recordCountText(n: number): string {
  return `عدد السجلات: ${n.toLocaleString("ar-EG")}`;
}

export function summaryDisplay(item: SummaryItem): string {
  const kind = item.kind ?? (typeof item.value === "number" ? "money" : "text");
  const col: Column = {
    header: item.label,
    kind,
    sum: false,
    numeric: kind === "int" || kind === "qty" || kind === "money" || kind === "percent",
    decimals: kind === "money" ? 2 : kind === "percent" ? 1 : kind === "int" ? 0 : 2,
  };
  return displayCell(item.value, col) || "—";
}
