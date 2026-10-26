import type { Sheet, SheetData, Row } from "write-excel-file/universal";
import {
  BRAND,
  PRODUCT_LINE,
  cleanText,
  columnTotal,
  generatedAtText,
  isIsoDate,
  isoDay,
  numberOf,
  recordCountText,
  resolveColumns,
  summaryDisplay,
  type Column,
  type ExportSpec,
} from "./model";
import { excelExtras, type SheetExtras } from "./excel-extras";

// Palette of the app (tailwind.config.ts) so an exported file looks like part of the same product.
const C = {
  brand: "#344E41",
  brandDark: "#243830",
  ink: "#1C1C1A",
  muted: "#6B6B66",
  line: "#D9D6CD",
  zebra: "#F7F6F2",
  soft: "#E7EDE8",
  white: "#FFFFFF",
};

const FONT = "Arial"; // present on every Windows / Mac / Android / iOS Excel; draws Arabic properly

const NUMBER_FORMAT = (decimals: number) => {
  const body = decimals > 0 ? `#,##0.${"0".repeat(decimals)}` : "#,##0";
  return `${body};[Red]-${body}`; // negatives in red, minus sign first
};

type Style = Record<string, unknown>;
type Cell = Row[number];

const bottomLine: Style = { bottomBorderStyle: "thin", bottomBorderColor: C.line };

function bannerRows(spec: ExportSpec, width: number, sheetTitle: string, recordCount?: number): Row[] {
  const span = Math.max(1, width);
  const fill = (cell: Style): Cell[] => [{ ...cell, columnSpan: span } as Cell, ...Array.from({ length: span - 1 }, () => null)];
  const metaParts = [spec.subtitle, recordCount !== undefined ? recordCountText(recordCount) : null, `تاريخ الإصدار: ${generatedAtText()}`].filter(Boolean);
  return [
    fill({ value: cleanText(spec.orgName || BRAND), fontWeight: "bold", fontSize: 14, textColor: C.white, backgroundColor: C.brand, alignVertical: "center", indent: 1, height: 28 }),
    fill({ value: cleanText(sheetTitle), fontWeight: "bold", fontSize: 16, textColor: C.ink, alignVertical: "center", indent: 1, height: 30 }),
    fill({ value: cleanText(metaParts.join("   •   ")), fontSize: 9, textColor: C.muted, alignVertical: "center", indent: 1, wrap: true, height: 18, bottomBorderStyle: "medium", bottomBorderColor: C.brand }),
    fill({ value: "", height: 8 }),
  ];
}

const KIND_ALIGN: Record<string, "right" | "center" | undefined> = { int: "right", qty: "right", money: "right", percent: "right", date: "center", code: "center" };

function dataCell(value: ExportSpec["rows"][number][number], col: Column, zebra: boolean): Cell {
  const style: Style = { fontSize: 10, textColor: C.ink, alignVertical: "center", ...bottomLine };
  if (zebra) style.backgroundColor = C.zebra;
  const align = KIND_ALIGN[col.kind];
  if (align) style.align = align;

  const blank = value === null || value === undefined || (typeof value === "string" && value.trim() === "");
  if (blank) return { ...style, value: "" } as Cell;

  if (col.numeric) {
    const n = numberOf(value);
    if (n === null) return { ...style, value: cleanText(String(value)), wrap: true } as Cell; // e.g. a note inside a numeric column
    if (col.kind === "percent") return { ...style, value: n / 100, type: Number, format: `0${col.decimals > 0 ? "." + "0".repeat(col.decimals) : ""}%;[Red]-0${col.decimals > 0 ? "." + "0".repeat(col.decimals) : ""}%` } as Cell;
    return { ...style, value: n, type: Number, format: NUMBER_FORMAT(col.decimals) } as Cell;
  }
  if (col.kind === "date" && isIsoDate(value)) {
    const [y, m, d] = isoDay(value).split("-").map(Number);
    return { ...style, value: new Date(Date.UTC(y, m - 1, d)), type: Date, format: "yyyy-mm-dd" } as Cell;
  }
  if (col.kind === "code") return { ...style, value: cleanText(String(value)), type: String, format: "@" } as Cell; // "@" keeps 0100… as text
  return { ...style, value: cleanText(String(value)), wrap: true } as Cell;
}

function textWidth(s: string): number {
  // Arabic letters are about as wide as Latin ones in Arial; digits a little narrower. 1.1 keeps a small margin.
  return Math.ceil(s.length * 1.1);
}

function columnWidths(cols: Column[], spec: ExportSpec, totals: (string | null)[]): number[] {
  return cols.map((col, i) => {
    const words = col.header.split(/\s+/);
    const longestWord = Math.max(...words.map((w) => w.length), 1);
    const headerW = Math.max(longestWord + 3, Math.min(textWidth(col.header), 20));
    let contentW = 0;
    for (const r of spec.rows) {
      const v = r[i];
      if (v === null || v === undefined || v === "") continue;
      const n = col.numeric ? numberOf(v) : null;
      const len = n !== null ? n.toFixed(col.decimals).length + Math.floor(Math.abs(n).toFixed(0).length / 3) + 1 : textWidth(cleanText(String(v)));
      if (len > contentW) contentW = len;
    }
    if (totals[i]) contentW = Math.max(contentW, totals[i]!.length + 2);
    const min = col.numeric ? 13 : col.kind === "date" ? 12 : 10;
    return Math.min(46, Math.max(min, headerW, contentW) + 2);
  });
}

function headerHeight(cols: Column[], widths: number[]): number {
  let lines = 1;
  cols.forEach((c, i) => {
    const perLine = Math.max(4, widths[i] - 2);
    lines = Math.max(lines, Math.ceil(textWidth(c.header) / perLine));
  });
  return Math.min(4, lines) * 14 + 12;
}

function sheetName(wanted: string, used: Set<string>): string {
  let base = cleanText(wanted).replace(/[\\/?*[\]:]/g, " ").replace(/^'+|'+$/g, "").replace(/\s+/g, " ").trim().slice(0, 31) || "تقرير";
  let name = base;
  let n = 2;
  while (used.has(name.toLowerCase())) {
    const suffix = ` ${n++}`;
    name = base.slice(0, 31 - suffix.length) + suffix;
  }
  used.add(name.toLowerCase());
  return name;
}

/** Builds the workbook (details sheet, plus a summary sheet first when the report has key figures). */
export async function buildExcelBlob(spec: ExportSpec): Promise<Blob> {
  // "universal" builds the file on the page itself (no Web Worker), so it also works under a strict CSP.
  const { default: writeExcelFile } = await import("write-excel-file/universal");

  const cols = resolveColumns(spec);
  const used = new Set<string>();
  const sheets: Sheet<Blob>[] = [];
  const extras: SheetExtras[] = [];
  const names: string[] = [];
  const footerLeft = PRODUCT_LINE;

  // ---- summary sheet -------------------------------------------------------------------------------------------
  if (spec.summary && spec.summary.length > 0) {
    const name = sheetName("الملخص", used);
    const data: SheetData = [
      ...bannerRows(spec, 2, spec.title),
      [
        { value: "البند", fontWeight: "bold", textColor: C.white, backgroundColor: C.brandDark, alignVertical: "center", indent: 1, height: 24 },
        { value: "القيمة", fontWeight: "bold", textColor: C.white, backgroundColor: C.brandDark, align: "center", alignVertical: "center", height: 24 },
      ] as Row,
      ...spec.summary.map((item, i): Row => {
        const zebra = i % 2 === 1;
        const base: Style = { fontSize: 11, alignVertical: "center", height: 22, ...bottomLine, ...(zebra ? { backgroundColor: C.zebra } : {}) };
        const kind = item.kind ?? (typeof item.value === "number" ? "money" : "text");
        const n = kind === "text" || kind === "code" || kind === "date" ? null : numberOf(item.value);
        const valueCell: Cell =
          n !== null
            ? ({ ...base, value: kind === "percent" ? n / 100 : n, type: Number, align: "center", fontWeight: "bold", format: kind === "percent" ? "0.0%" : NUMBER_FORMAT(kind === "money" ? 2 : kind === "int" ? 0 : 2) } as Cell)
            : ({ ...base, value: summaryDisplay(item), align: "center", fontWeight: "bold" } as Cell);
        return [{ ...base, value: cleanText(item.label), indent: 1, wrap: true } as Cell, valueCell];
      }),
    ];
    sheets.push({ data, sheet: name, columns: [{ width: 38 }, { width: 24 }], rightToLeft: true, showGridLines: false });
    extras.push({ tabColor: "344E41", footerLeft });
    names.push(name);
  }

  // ---- details sheet -------------------------------------------------------------------------------------------
  const totalsRow = cols.some((c) => c.sum);
  const totalText: (string | null)[] = cols.map((c, i) => (c.sum ? (c.kind === "money" ? columnTotal(c, spec.rows, i).toFixed(2) : String(columnTotal(c, spec.rows, i))) : null));
  const widths = columnWidths(cols, spec, totalText);
  const banner = bannerRows(spec, cols.length, spec.summary?.length ? `${spec.title} — التفاصيل` : spec.title, spec.rows.length);

  const headerRow: Row = cols.map((c) => ({
    value: c.header,
    fontWeight: "bold",
    fontSize: 10,
    textColor: C.white,
    backgroundColor: C.brand,
    align: "center",
    alignVertical: "center",
    wrap: true,
    height: headerHeight(cols, widths),
    rightBorderStyle: "thin",
    rightBorderColor: C.brandDark,
    leftBorderStyle: "thin",
    leftBorderColor: C.brandDark,
  })) as Row;

  const body: Row[] = spec.rows.map((r, ri) => cols.map((c, ci) => dataCell(r[ci], c, ri % 2 === 1)));

  if (spec.rows.length === 0) {
    body.push([{ value: "لا توجد بيانات في هذه الفترة", columnSpan: cols.length, align: "center", fontSize: 11, textColor: C.muted, height: 36, alignVertical: "center", ...bottomLine } as Cell, ...Array.from({ length: cols.length - 1 }, () => null)]);
  }

  const totals: Row[] = [];
  if (totalsRow && spec.rows.length > 0) {
    totals.push(
      cols.map((c, i): Cell => {
        const style: Style = { fontWeight: "bold", fontSize: 10, backgroundColor: C.soft, textColor: C.ink, alignVertical: "center", height: 24, topBorderStyle: "medium", topBorderColor: C.brand, bottomBorderStyle: "medium", bottomBorderColor: C.brand };
        if (c.sum) {
          const t = columnTotal(c, spec.rows, i);
          return { ...style, value: c.kind === "percent" ? t / 100 : t, type: Number, align: "right", format: c.kind === "percent" ? "0.0%" : NUMBER_FORMAT(c.decimals) } as Cell;
        }
        return { ...style, value: i === 0 ? "الإجمالي" : "", indent: i === 0 ? 1 : 0 } as Cell;
      }),
    );
  }

  const noteRows: Row[] = [];
  if (spec.notes && spec.notes.length > 0) {
    noteRows.push([{ value: "", columnSpan: cols.length } as Cell, ...Array.from({ length: cols.length - 1 }, () => null)]);
    for (const note of spec.notes) {
      noteRows.push([{ value: cleanText(note), columnSpan: cols.length, fontSize: 9, textColor: C.muted, wrap: true, indent: 1 } as Cell, ...Array.from({ length: cols.length - 1 }, () => null)]);
    }
  }

  const headerRowNumber = banner.length + 1;
  const dataEnd = headerRowNumber + Math.max(spec.rows.length, 1);
  const detailsName = sheetName(spec.summary?.length ? "التفاصيل" : spec.title, used);
  sheets.push({
    data: [...banner, headerRow, ...body, ...totals, ...noteRows],
    sheet: detailsName,
    columns: widths.map((width) => ({ width })),
    rightToLeft: true,
    showGridLines: false,
    stickyRowsCount: headerRowNumber, // title + header stay visible while scrolling
    ...(cols.length > 6 ? { orientation: "landscape" as const } : {}),
  });
  extras.push({
    table: spec.rows.length > 0 ? { headerRow: headerRowNumber, lastRow: dataEnd, firstCol: 1, lastCol: cols.length } : undefined,
    landscape: cols.length > 6,
    tabColor: "344E41",
    printTitleRow: headerRowNumber,
    footerLeft,
  });
  names.push(detailsName);

  return writeExcelFile(sheets, { fontFamily: FONT, fontSize: 10, features: [excelExtras(extras, names)] }).toBlob();
}

