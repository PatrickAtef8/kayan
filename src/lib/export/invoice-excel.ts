import type { Row, Sheet } from "write-excel-file/universal";
import { PRODUCT_LINE, BRAND, cleanText, generatedAtText } from "./model";
import { excelExtras } from "./excel-extras";
import { KIND_TITLE, STATUS_TEXT, type InvoiceDoc } from "./invoice-model";

const C = { brand: "#344E41", brandDark: "#243830", ink: "#1C1C1A", muted: "#6B6B66", line: "#D9D6CD", zebra: "#F7F6F2", soft: "#E7EDE8", white: "#FFFFFF", rose: "#9C4F45", roseSoft: "#F5E3E0" };
const MONEY = "#,##0.00;[Red]-#,##0.00";
type Style = Record<string, unknown>;
type Cell = Row[number];

const isoDate = (v: string): Date | string => {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(v);
  return m ? new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]))) : v;
};

/** Builds one invoice as a workbook with a single, print-ready sheet. */
export async function buildInvoiceExcelBlob(doc: InvoiceDoc): Promise<Blob> {
  const { default: writeExcelFile } = await import("write-excel-file/universal");

  const hasDiscount = doc.items.some((i) => i.gross - i.net > 0.004);
  // # | الصنف | الكمية | سعر الوحدة | [الإجمالي | الخصم] | الصافي
  const heads = hasDiscount ? ["#", "الصنف", "الكمية", "سعر الوحدة", "الإجمالي", "الخصم", "الصافي"] : ["#", "الصنف", "الكمية", "سعر الوحدة", "الإجمالي"];
  const widths = hasDiscount ? [6, 40, 13, 15, 15, 13, 16] : [6, 44, 14, 18, 18];
  const n = heads.length;
  const span = (value: string, style: Style, cols = n): Cell[] => [{ value, columnSpan: cols, ...style } as Cell, ...Array.from({ length: cols - 1 }, () => null)];

  const org = cleanText(doc.orgName || BRAND);
  const title = `${KIND_TITLE[doc.kind]} رقم ${doc.number}`;
  const rows: Row[] = [
    span(org, { fontWeight: "bold", fontSize: 14, textColor: C.white, backgroundColor: C.brand, alignVertical: "center", indent: 1, height: 28 }),
    span(title, { fontWeight: "bold", fontSize: 16, textColor: C.ink, alignVertical: "center", indent: 1, height: 30 }),
    span(`تاريخ الإصدار: ${generatedAtText()}`, { fontSize: 9, textColor: C.muted, alignVertical: "center", indent: 1, height: 18, bottomBorderStyle: "medium", bottomBorderColor: C.brand }),
    span("", { height: 8 }),
  ];

  // --- who / when -----------------------------------------------------------------------------------------------
  const infoRow = (label: string, value: string | Date, bold = true): Row => [
    { value: label, columnSpan: 2, fontSize: 10, textColor: C.muted, indent: 1, alignVertical: "center", height: 20, bottomBorderStyle: "thin", bottomBorderColor: C.line } as Cell,
    null,
    value instanceof Date
      ? ({ value, type: Date, format: "yyyy-mm-dd", columnSpan: n - 2, align: "right", fontSize: 11, fontWeight: bold ? "bold" : undefined, alignVertical: "center", bottomBorderStyle: "thin", bottomBorderColor: C.line } as Cell)
      : ({ value: cleanText(value), columnSpan: n - 2, align: "right", fontSize: 11, fontWeight: bold ? "bold" : undefined, alignVertical: "center", bottomBorderStyle: "thin", bottomBorderColor: C.line } as Cell),
    ...Array.from({ length: n - 3 }, () => null),
  ];
  rows.push(infoRow(doc.partyLabel, doc.partyName));
  rows.push(infoRow("رقم الفاتورة", doc.number));
  rows.push(infoRow("التاريخ", isoDate(doc.date)));
  for (const i of doc.info) rows.push(infoRow(i.label, i.value));
  rows.push(infoRow("الحالة", STATUS_TEXT[doc.status]));
  rows.push(span("", { height: 10 }));

  // --- items ----------------------------------------------------------------------------------------------------
  rows.push(
    heads.map((h, i): Cell => ({ value: h, fontWeight: "bold", fontSize: 10, textColor: C.white, backgroundColor: C.brand, align: i === 1 ? undefined : "center", alignVertical: "center", height: 24, wrap: true } as Cell)) as Row,
  );
  doc.items.forEach((it, idx) => {
    const base: Style = { fontSize: 10, alignVertical: "center", bottomBorderStyle: "thin", bottomBorderColor: C.line, ...(idx % 2 === 1 ? { backgroundColor: C.zebra } : {}) };
    const qtyFmt = Number.isInteger(it.qty) ? "#,##0" : "#,##0.###";
    const cells: Cell[] = [
      { ...base, value: idx + 1, type: Number, align: "center", textColor: C.muted } as Cell,
      { ...base, value: cleanText(it.name) + (it.isBonus ? "  (بونص — مجاني)" : ""), wrap: true, align: "right" } as Cell,
      { ...base, value: it.qty, type: Number, format: qtyFmt, align: "center" } as Cell,
      { ...base, value: it.unitPrice, type: Number, format: MONEY, align: "right" } as Cell,
    ];
    if (hasDiscount) {
      cells.push({ ...base, value: it.gross, type: Number, format: MONEY, align: "right" } as Cell);
      cells.push({ ...base, value: Math.max(0, Math.round((it.gross - it.net) * 100) / 100), type: Number, format: "#,##0.00;[Red]-#,##0.00;\"—\"", align: "right" } as Cell);
    }
    cells.push({ ...base, value: it.net, type: Number, format: MONEY, align: "right", fontWeight: "bold" } as Cell);
    rows.push(cells as Row);
    if (it.bonusQty > 0) {
      rows.push([
        { ...base, value: "" } as Cell,
        { ...base, value: `بونص: + ${it.bonusQty.toLocaleString("ar-EG")} قطعة مجانية`, fontSize: 9, textColor: C.brand } as Cell,
        ...Array.from({ length: n - 2 }, () => ({ ...base, value: "" }) as Cell),
      ] as Row);
    }
  });
  if (doc.items.length === 0) rows.push(span("لا توجد أصناف في هذه الفاتورة", { align: "center", textColor: C.muted, height: 30, alignVertical: "center" }));
  rows.push(span("جميع المبالغ بالجنيه المصري (ج.م)", { fontSize: 8, textColor: C.muted, indent: 1 }));
  rows.push(span("", { height: 6 }));

  // --- totals ---------------------------------------------------------------------------------------------------
  const totalRow = (label: string, value: number, style: Style): Row => [
    { value: label, columnSpan: n - 1, align: "right", indent: 1, alignVertical: "center", ...style } as Cell,
    ...Array.from({ length: n - 2 }, () => null),
    { value, type: Number, format: MONEY, align: "right", alignVertical: "center", ...style } as Cell,
  ];
  for (const t of doc.totals) {
    const signed = t.sign === "minus" ? -t.value : t.value;
    rows.push(
      totalRow(t.label, signed, t.strong ? { fontWeight: "bold", fontSize: 11, backgroundColor: C.soft, topBorderStyle: "medium", topBorderColor: C.brand, height: 24 } : { fontSize: 10, textColor: C.muted, bottomBorderStyle: "thin", bottomBorderColor: C.line, height: 19 }),
    );
  }
  rows.push(
    totalRow(doc.remaining > 0 ? "المتبقي" : "تم السداد بالكامل", doc.remaining, {
      fontWeight: "bold",
      fontSize: 12,
      textColor: doc.remaining > 0 ? C.rose : C.brand,
      backgroundColor: doc.remaining > 0 ? C.roseSoft : C.soft,
      height: 28,
    }),
  );

  // --- payments -------------------------------------------------------------------------------------------------
  if (doc.payments.length > 0) {
    rows.push(span("", { height: 12 }));
    rows.push(span("سجل الدفعات", { fontWeight: "bold", fontSize: 11, textColor: C.brand, indent: 1 }));
    rows.push([
      { value: "التاريخ", columnSpan: 2, fontWeight: "bold", backgroundColor: C.soft, textColor: C.brandDark, align: "center", height: 20 } as Cell,
      null,
      { value: "الطريقة / ملاحظات", columnSpan: n - 3, fontWeight: "bold", backgroundColor: C.soft, textColor: C.brandDark, height: 20 } as Cell,
      ...Array.from({ length: n - 4 }, () => null),
      { value: "المبلغ", fontWeight: "bold", backgroundColor: C.soft, textColor: C.brandDark, align: "center", height: 20 } as Cell,
    ] as Row);
    for (const p of doc.payments) {
      const base: Style = { fontSize: 10, alignVertical: "center", bottomBorderStyle: "thin", bottomBorderColor: C.line };
      const d = isoDate(p.date);
      rows.push([
        d instanceof Date ? ({ ...base, value: d, type: Date, format: "yyyy-mm-dd", columnSpan: 2, align: "center" } as Cell) : ({ ...base, value: d, columnSpan: 2, align: "center" } as Cell),
        null,
        { ...base, value: cleanText([p.method, p.note].filter(Boolean).join(" — ")) || "—", columnSpan: n - 3, wrap: true } as Cell,
        ...Array.from({ length: n - 4 }, () => null),
        { ...base, value: p.amount, type: Number, format: MONEY, align: "right", fontWeight: "bold" } as Cell,
      ] as Row);
    }
  }

  const name = "فاتورة";
  const sheet: Sheet<Blob> = { data: rows, sheet: name, columns: widths.map((width) => ({ width })), rightToLeft: true, showGridLines: false } as Sheet<Blob>;
  return writeExcelFile([sheet], { fontFamily: "Arial", fontSize: 10, features: [excelExtras([{ landscape: false, tabColor: "344E41", footerLeft: PRODUCT_LINE }], [name])] }).toBlob();
}
