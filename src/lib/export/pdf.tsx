import { Document, Font, Page, Text, View, pdf } from "@react-pdf/renderer";
import {
  BRAND,
  PRODUCT_LINE,
  cleanText,
  columnTotal,
  displayCell,
  formatNumber,
  generatedAtText,
  isNegative,
  recordCountText,
  resolveColumns,
  summaryDisplay,
  type Column,
  type ExportSpec,
} from "./model";

// A real PDF file (not the browser's print dialog): the same data as the Excel file, laid out as a report —
// company header, title and period, key figures, a table whose header repeats on every page, a totals row, and
// "page x of y" in the footer.
//
// Arabic works because @react-pdf shapes and joins Arabic letters and applies the bidi algorithm; the one thing it
// does not do is the direction isolates used by formatMoney() on screen, so numbers here are formatted by
// ./model.ts (same digits, no marks) and laid out as their own left-to-right Text (sign first).

export const C = {
  brand: "#344E41",
  brandDark: "#243830",
  ink: "#1C1C1A",
  muted: "#6B6B66",
  line: "#E5E3DD",
  zebra: "#F7F6F2",
  soft: "#E7EDE8",
  rose: "#9C4F45",
  white: "#FFFFFF",
  bandMuted: "#CBD8D0",
};

// @react-pdf keeps loaded fonts (and the glyph subsets built from them) for the lifetime of the page, and a later
// document can then lose letters the previous one already used (seen: "شهر" printed as "ر"). Every build therefore
// registers its own fresh copy of the fonts under a unique family name and a unique URL, so no state is shared.
let build = 0;

export function registerFonts(base = "/fonts", bust = true): string[] {
  const id = ++build;
  const family = (name: string) => `${name}${id}`;
  const src = (file: string) => (bust ? `${base}/${file}?v=${id}` : `${base}/${file}`);
  Font.register({
    family: family("KayanArabic"),
    fonts: [
      { src: src("IBMPlexSansArabic-Arabic-Regular.woff"), fontWeight: 400 },
      { src: src("IBMPlexSansArabic-Arabic-Bold.woff"), fontWeight: 700 },
    ],
  });
  Font.register({
    family: family("KayanLatin"),
    fonts: [
      { src: src("IBMPlexSansArabic-Latin-Regular.woff"), fontWeight: 400 },
      { src: src("IBMPlexSansArabic-Latin-Bold.woff"), fontWeight: 700 },
    ],
  });
  // Never split a word (a SKU, a name) across lines with a hyphen.
  Font.registerHyphenationCallback((word) => [word]);
  return [family("KayanArabic"), family("KayanLatin")];
}

const MARGIN = 28;
const A4 = { w: 595.28, h: 841.89 };

type Layout = { landscape: boolean; fontSize: number; width: number; widths: number[] };

function fontSizeFor(count: number): number {
  if (count <= 6) return 9.5;
  if (count <= 9) return 8.5;
  if (count <= 12) return 7.8;
  return 7;
}

// Column widths: proportional to what the column needs (header words wrap, so only the longest word counts for the
// header), never narrower than its longest unbreakable word, scaled to fill the page exactly.
function layoutFor(spec: ExportSpec, cols: Column[]): Layout {
  const landscape = cols.length > 6;
  const width = (landscape ? A4.h : A4.w) - MARGIN * 2;
  const fontSize = fontSizeFor(cols.length);
  const charW = fontSize * 0.52;
  const pad = 9;

  const need: number[] = [];
  const min: number[] = [];
  cols.forEach((c, i) => {
    const longestWord = Math.max(...c.header.split(/\s+/).map((w) => w.length), 1);
    let content = 0;
    let longestContentWord = 0;
    for (const r of spec.rows) {
      const text = displayCell(r[i], c);
      if (!text) continue;
      content = Math.max(content, Math.min(text.length, 34));
      if (!c.numeric) longestContentWord = Math.max(longestContentWord, ...text.split(/\s+/).map((w) => Math.min(w.length, 22)));
      else longestContentWord = Math.max(longestContentWord, text.length);
    }
    const totalLen = c.sum ? formatNumber(columnTotal(c, spec.rows, i), c.decimals).length + 1 : 0;
    content = Math.max(content, totalLen);
    const headerNeed = Math.max(longestWord, Math.min(c.header.length, 14) * 0.7);
    need[i] = Math.max(headerNeed, content, 4) * charW + pad;
    min[i] = Math.max(longestWord, longestContentWord, totalLen, 3) * charW + pad * 0.8;
  });

  // Scale to the page width, then lift any column that fell under its minimum and shrink the others to pay for it.
  const sum = need.reduce((a, b) => a + b, 0);
  let widths = need.map((n) => (n / sum) * width);
  for (let pass = 0; pass < 4; pass++) {
    const fixed = widths.map((w, i) => w < min[i]);
    if (!fixed.some(Boolean)) break;
    const fixedTotal = widths.reduce((a, w, i) => a + (fixed[i] ? min[i] : 0), 0);
    const freeNeed = need.reduce((a, n, i) => a + (fixed[i] ? 0 : n), 0);
    if (freeNeed <= 0 || fixedTotal >= width) break;
    widths = widths.map((w, i) => (fixed[i] ? min[i] : (need[i] / freeNeed) * (width - fixedTotal)));
  }
  const total = widths.reduce((a, b) => a + b, 0);
  widths = widths.map((w) => (w / total) * width);
  return { landscape, fontSize, width, widths };
}

// RTL text is written right-to-left and aligned to the right; numbers are their own left-to-right run so "-1,250.50"
// keeps its sign on the left; dates and codes (always left-to-right) sit centred.
type TextStyle = { direction: "ltr" | "rtl"; textAlign: "left" | "right" | "center" };
function cellTextStyle(col: Column): TextStyle {
  if (col.numeric) return { direction: "ltr", textAlign: "right" };
  if (col.kind === "date" || col.kind === "code") return { direction: "ltr", textAlign: "center" };
  return { direction: "rtl" as const, textAlign: "right" };
}

function Cell({ width, children, style, fontSize, bold, color, align, fonts, divider }: { width: number; children: string; style: TextStyle; fontSize: number; bold?: boolean; color?: string; align?: "center"; fonts: string[]; divider?: string }) {
  return (
    <View style={{ width, paddingVertical: 5, paddingHorizontal: 6, justifyContent: "center", ...(divider ? { borderLeftWidth: 0.5, borderLeftColor: divider } : {}) }}>
      <Text style={{ ...style, ...(align ? { textAlign: align } : {}), fontFamily: fonts, fontSize, fontWeight: bold ? 700 : 400, color: color ?? C.ink, lineHeight: 1.35 }}>{children}</Text>
    </View>
  );
}

// Dates inside Arabic text ("الفترة: من 2026-10-01 إلى 2026-10-25"): the bidi algorithm can turn a date around
// ("25-10-2026"). A left-to-right mark (U+200E, zero width, present in the Arabic font) on both sides of every date keeps it
// whole. NOTE: right-to-left <Text> inside a flex ROW loses its width in this renderer, so never build a line out of pieces.
const DATE_ANYWHERE = /(\d{4}-\d{2}-\d{2})/g;
export const bidiSafe = (text: string) => cleanText(text).replace(DATE_ANYWHERE, "\u200E$1\u200E");

function SummaryStrip({ spec, width }: { spec: ExportSpec; width: number }) {
  const items = spec.summary ?? [];
  if (items.length === 0) return null;
  const perRow = Math.min(items.length, width > 600 ? 5 : 3);
  const gap = 6;
  const boxW = (width - gap * (perRow - 1)) / perRow;
  return (
    <View style={{ flexDirection: "row-reverse", flexWrap: "wrap", marginBottom: 12 }}>
      {items.map((item, i) => {
        const negative = typeof item.value === "number" && item.value < 0 && (item.kind ?? "money") !== "text";
        return (
          <View key={i} wrap={false} style={{ width: boxW, marginLeft: i % perRow === perRow - 1 ? 0 : gap, marginBottom: gap, backgroundColor: C.soft, borderRadius: 4, paddingVertical: 7, paddingHorizontal: 9, borderRightWidth: 2.5, borderRightColor: C.brand }}>
            <Text style={{ fontSize: 8, color: C.muted, textAlign: "right", direction: "rtl" }}>{cleanText(item.label)}</Text>
            <Text style={{ fontSize: 13, fontWeight: 700, color: negative ? C.rose : C.ink, textAlign: "right", direction: "ltr", marginTop: 2 }}>{summaryDisplay(item)}</Text>
          </View>
        );
      })}
    </View>
  );
}

// The renderer lays out one long flowing table in time that grows with the SQUARE of its rows (500 rows ≈ 20 s,
// 2 000 ≈ 3 min — a frozen browser tab). So rows are split into pages here, from an estimate of each row's height, and
// every <Page> only ever holds one page worth of rows: layout time then grows linearly (see the notes in docs/EXPORTS.md).
const ARABIC = /[\u0600-\u06FF]/;
const LINE = 1.35;
const CELL_PAD = 9; // 4.5 above + 4.5 below

function rowHeight(row: ExportSpec["rows"][number], cols: Column[], widths: number[], fontSize: number): number {
  let lines = 1;
  cols.forEach((c, i) => {
    const text = displayCell(row[i], c);
    if (!text) return;
    const perLine = Math.max(2, Math.floor((widths[i] - CELL_PAD) / (fontSize * 0.56)));
    // words never split, so a long word on its own line can waste space: count whole words
    let used = 0;
    let n = 1;
    for (const w of text.split(/\s+/)) {
      const len = Math.min(w.length, perLine);
      if (used === 0) used = len;
      else if (used + 1 + len <= perLine) used += 1 + len;
      else {
        n++;
        used = len;
      }
    }
    lines = Math.max(lines, n);
  });
  return lines * fontSize * LINE + CELL_PAD + 0.6;
}

function paginate(spec: ExportSpec, cols: Column[], layout: Layout): ExportSpec["rows"][] {
  const { fontSize, widths, landscape } = layout;
  const pageH = landscape ? A4.w : A4.h; // (height of the sheet = width of the portrait one)
  const usable = (pageH - MARGIN - 46) * 0.95;
  const headerH = Math.max(...cols.map((c, i) => Math.ceil(c.header.length * fontSize * 0.56 / Math.max(10, widths[i] - CELL_PAD)))) * fontSize * LINE + CELL_PAD + 2;
  const summaryRows = spec.summary?.length ? Math.ceil(spec.summary.length / (layout.width > 600 ? 5 : 3)) : 0;
  const firstReserve = 150 + summaryRows * 54 + (spec.subtitle ? 14 : 0);
  const totalsReserve = cols.some((c) => c.sum) ? 30 : 0;
  const notesReserve = spec.notes?.length ? 14 * spec.notes.length + 12 : 0;

  const pages: ExportSpec["rows"][] = [];
  let cur: ExportSpec["rows"] = [];
  let room = usable - firstReserve - headerH;
  for (const row of spec.rows) {
    const h = rowHeight(row, cols, widths, fontSize);
    if (h > room && cur.length > 0) {
      pages.push(cur);
      cur = [];
      room = usable - headerH;
    }
    cur.push(row);
    room -= h;
  }
  // The totals row and the notes belong under the last rows. If they do not fit under them, the last three rows move to
  // the final page with them, so the closing page never holds a lone totals row.
  if (cur.length > 0 && room < totalsReserve + notesReserve) {
    const carry = cur.splice(Math.max(0, cur.length - 3));
    if (cur.length > 0) pages.push(cur);
    cur = carry;
  }
  pages.push(cur);
  return pages;
}

export function ReportDocument({ spec, fonts }: { spec: ExportSpec; fonts: string[] }) {
  const cols = resolveColumns(spec);
  const layout = layoutFor(spec, cols);
  const { fontSize, widths } = layout;
  const org = cleanText(spec.orgName || BRAND);
  const title = cleanText(spec.title);
  const hasTotals = cols.some((c) => c.sum) && spec.rows.length > 0;
  const issued = generatedAtText();
  const pages = paginate(spec, cols, layout);

  const headerRow = (
    <View fixed style={{ flexDirection: "row-reverse", backgroundColor: C.brand, borderRadius: 3 }}>
      {cols.map((c, i) => (
        <Cell key={i} fonts={fonts} width={widths[i]} fontSize={fontSize - 0.3} bold color={C.white} divider={i < cols.length - 1 ? "#52705F" : undefined} style={{ direction: "rtl", textAlign: cellTextStyle(c).textAlign }}>
          {c.header}
        </Cell>
      ))}
    </View>
  );

  return (
    <Document title={title} author={org} creator={PRODUCT_LINE} producer={PRODUCT_LINE} subject={cleanText(spec.subtitle ?? title)} language="ar">
      {pages.map((pageRows, pi) => {
        const first = pi === 0;
        const last = pi === pages.length - 1;
        return (
          <Page key={pi} size="A4" orientation={layout.landscape ? "landscape" : "portrait"} style={{ fontFamily: fonts, fontSize, color: C.ink, paddingTop: MARGIN, paddingBottom: 46, paddingHorizontal: MARGIN }}>
            {first ? (
              <>
                {/* Company band */}
                <View style={{ flexDirection: "row-reverse", justifyContent: "space-between", alignItems: "center", backgroundColor: C.brand, borderRadius: 5, paddingVertical: 11, paddingHorizontal: 14 }}>
                  <View>
                    <Text style={{ fontSize: 14, fontWeight: 700, color: C.white, textAlign: "right", direction: "rtl" }}>{org}</Text>
                    <Text style={{ fontSize: 8, color: C.bandMuted, textAlign: "right", direction: "rtl", marginTop: 2 }}>{PRODUCT_LINE}</Text>
                  </View>
                  <View style={{ flexShrink: 0, marginRight: 16 }}>
                    <Text style={{ fontSize: 7.5, color: C.bandMuted, textAlign: "left", direction: "rtl" }}>تاريخ الإصدار</Text>
                    <Text style={{ fontSize: 9, color: C.white, textAlign: "left", direction: "rtl", marginTop: 2 }}>{issued}</Text>
                  </View>
                </View>

                {/* Title block */}
                <View style={{ marginTop: 14, marginBottom: 12, paddingBottom: 9, borderBottomWidth: 1, borderBottomColor: C.line }}>
                  <Text style={{ fontSize: 19, fontWeight: 700, textAlign: "right", direction: "rtl" }}>{title}</Text>
                  {spec.subtitle ? <Text style={{ fontSize: 9.5, color: C.muted, textAlign: "right", direction: "rtl", marginTop: 4 }}>{bidiSafe(spec.subtitle)}</Text> : null}
                  <Text style={{ fontSize: 9.5, color: C.muted, textAlign: "right", direction: "rtl", marginTop: 2 }}>{recordCountText(spec.rows.length)}</Text>
                </View>

                <SummaryStrip spec={spec} width={layout.width} />
              </>
            ) : null}

            <View>
              {headerRow}

              {spec.rows.length === 0 ? (
                <View style={{ paddingVertical: 26, borderBottomWidth: 0.6, borderBottomColor: C.line }}>
                  <Text style={{ fontSize: 11, color: C.muted, textAlign: "center", direction: "rtl" }}>لا توجد بيانات في هذه الفترة</Text>
                </View>
              ) : (
                pageRows.map((row, ri) => {
                  const zebra = (pages.slice(0, pi).reduce((n, p) => n + p.length, 0) + ri) % 2 === 1;
                  return (
                    <View key={ri} wrap={false} style={{ flexDirection: "row-reverse", backgroundColor: zebra ? C.zebra : C.white, borderBottomWidth: 0.6, borderBottomColor: C.line }}>
                      {cols.map((c, ci) => {
                        const text = displayCell(row[ci], c);
                        const empty = text === "";
                        return (
                          <Cell key={ci} fonts={fonts} width={widths[ci]} fontSize={fontSize} divider={ci < cols.length - 1 ? "#ECE9E1" : undefined} style={c.kind === "text" && text && !ARABIC.test(text) ? { direction: "ltr", textAlign: "right" } : cellTextStyle(c)} color={empty ? "#B5B2A9" : isNegative(row[ci], c) ? C.rose : C.ink}>
                            {empty ? "—" : text}
                          </Cell>
                        );
                      })}
                    </View>
                  );
                })
              )}

              {last && hasTotals ? (
                <View wrap={false} style={{ flexDirection: "row-reverse", backgroundColor: C.soft, borderTopWidth: 1.4, borderTopColor: C.brand, borderBottomWidth: 1.4, borderBottomColor: C.brand }}>
                  {cols.map((c, i) => {
                    if (!c.sum) {
                      return (
                        <Cell key={i} fonts={fonts} width={widths[i]} fontSize={fontSize} bold style={{ direction: "rtl", textAlign: "right" }}>
                          {i === 0 ? "الإجمالي" : ""}
                        </Cell>
                      );
                    }
                    const t = columnTotal(c, spec.rows, i);
                    return (
                      <Cell key={i} fonts={fonts} width={widths[i]} fontSize={fontSize} bold style={cellTextStyle(c)} color={t < 0 ? C.rose : C.ink}>
                        {displayCell(t, c)}
                      </Cell>
                    );
                  })}
                </View>
              ) : null}
            </View>

            {last && spec.notes && spec.notes.length > 0 ? (
              <View style={{ marginTop: 10 }}>
                {spec.notes.map((n, i) => (
                  <Text key={i} style={{ fontSize: 8, color: C.muted, textAlign: "right", direction: "rtl", marginBottom: 2 }}>
                    {cleanText(n)}
                  </Text>
                ))}
              </View>
            ) : null}

            {/* Footer on every page */}
            <View fixed style={{ position: "absolute", left: MARGIN, right: MARGIN, bottom: 16, flexDirection: "row-reverse", justifyContent: "space-between", alignItems: "center", borderTopWidth: 0.6, borderTopColor: C.line, paddingTop: 6 }}>
              <Text style={{ fontSize: 7.5, color: C.muted, direction: "rtl", textAlign: "right" }}>{`${org} — ${title}`}</Text>
              <Text
                fixed
                style={{ fontSize: 8, color: C.muted, direction: "rtl", textAlign: "left" }}
                render={({ pageNumber, totalPages }) => (pageNumber && totalPages ? `صفحة ${pageNumber.toLocaleString("ar-EG")} من ${totalPages.toLocaleString("ar-EG")}` : " ")}
              />
            </View>
          </Page>
        );
      })}
    </Document>
  );
}

export async function buildPdfBlob(spec: ExportSpec, fontBase = "/fonts"): Promise<Blob> {
  const fonts = registerFonts(fontBase);
  return pdf(<ReportDocument spec={spec} fonts={fonts} />).toBlob();
}
