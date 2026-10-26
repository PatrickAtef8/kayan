import { Document, Page, Text, View, pdf } from "@react-pdf/renderer";
import { C, registerFonts } from "./pdf";
import { PRODUCT_LINE, BRAND, cleanText, formatNumber, generatedAtText } from "./model";
import { KIND_TITLE, STATUS_TEXT, type InvoiceDoc, type InvoiceItem } from "./invoice-model";

// One invoice as a document the other party can receive: header, who/when, items, totals, payments, balance, signatures.
// Layout rules learned the hard way (see docs/EXPORTS.md): every right-to-left <Text> sits inside a <View> (never directly
// in a flex row), numbers are their own left-to-right <Text>, and columns have fixed widths so headers and values line up.

const MARGIN = 32;

const qtyText = (q: number) => formatNumber(q, Math.min(3, (String(q).split(".")[1] ?? "").length));
const money = (v: number) => formatNumber(v, 2);
// Text with no Arabic letters (an English name ending in a full stop) must be laid out left-to-right or its punctuation jumps sides.
const dirOf = (t: string): "rtl" | "ltr" => (/[\u0600-\u06FF]/.test(t) ? "rtl" : "ltr");

const STATUS_COLOR: Record<InvoiceDoc["status"], { bg: string; fg: string }> = {
  paid: { bg: "#E7EDE8", fg: "#344E41" },
  partial: { bg: "#FBEFD5", fg: "#8A5A00" },
  unpaid: { bg: "#F5E3E0", fg: "#9C4F45" },
};

type Align = "right" | "center";
type Col = { key: "idx" | "name" | "qty" | "unit" | "gross" | "disc" | "net"; header: string; w: number; align: Align };

function columnsFor(hasDiscount: boolean): Col[] {
  return hasDiscount
    ? [
        { key: "idx", header: "#", w: 5, align: "center" },
        { key: "name", header: "الصنف", w: 33, align: "right" },
        { key: "qty", header: "الكمية", w: 11, align: "center" },
        { key: "unit", header: "سعر الوحدة", w: 12.5, align: "right" },
        { key: "gross", header: "الإجمالي", w: 13, align: "right" },
        { key: "disc", header: "الخصم", w: 11.5, align: "right" },
        { key: "net", header: "الصافي", w: 14, align: "right" },
      ]
    : [
        { key: "idx", header: "#", w: 6, align: "center" },
        { key: "name", header: "الصنف", w: 42, align: "right" },
        { key: "qty", header: "الكمية", w: 14, align: "center" },
        { key: "unit", header: "سعر الوحدة", w: 18, align: "right" },
        { key: "net", header: "الإجمالي", w: 20, align: "right" },
      ];
}

const num = (align: Align) => ({ direction: "ltr" as const, textAlign: align });

function ItemRow({ item, index, cols, zebra }: { item: InvoiceItem; index: number; cols: Col[]; zebra: boolean }) {
  const disc = Math.max(0, item.gross - item.net);
  return (
    <View wrap={false} style={{ flexDirection: "row-reverse", backgroundColor: zebra ? C.zebra : C.white, borderBottomWidth: 0.6, borderBottomColor: C.line }}>
      {cols.map((c, i) => {
        const cell = { width: `${c.w}%`, paddingVertical: 4.5, paddingHorizontal: 6, justifyContent: "center" as const, ...(i < cols.length - 1 ? { borderLeftWidth: 0.5, borderLeftColor: "#ECE9E1" } : {}) };
        let body: React.ReactNode;
        switch (c.key) {
          case "idx":
            body = <Text style={{ ...num("center"), fontSize: 8.5, color: C.muted }}>{(index + 1).toLocaleString("ar-EG")}</Text>;
            break;
          case "name":
            body = (
              <View>
                <Text style={{ direction: dirOf(item.name), textAlign: "right", fontSize: 9.5, lineHeight: 1.35 }}>{cleanText(item.name)}</Text>
                {item.isBonus ? <Text style={{ direction: "rtl", textAlign: "right", fontSize: 7.5, color: C.brand, marginTop: 1 }}>بونص (مجاني)</Text> : null}
              </View>
            );
            break;
          case "qty":
            body = (
              <View>
                <Text style={{ ...num("center"), fontSize: 9.5 }}>{qtyText(item.qty)}</Text>
                {item.bonusQty > 0 ? <Text style={{ direction: "rtl", textAlign: "center", fontSize: 7.5, color: C.brand, marginTop: 1 }}>{`+ ${qtyText(item.bonusQty)} بونص`}</Text> : null}
              </View>
            );
            break;
          case "unit":
            body = <Text style={{ ...num("right"), fontSize: 9.5 }}>{money(item.unitPrice)}</Text>;
            break;
          case "gross":
            body = <Text style={{ ...num("right"), fontSize: 9.5 }}>{money(item.gross)}</Text>;
            break;
          case "disc":
            body = <Text style={{ ...num("right"), fontSize: 9.5, color: disc > 0 ? C.rose : C.muted }}>{disc > 0 ? `-${money(disc)}` : "—"}</Text>;
            break;
          case "net":
            body = <Text style={{ ...num("right"), fontSize: 9.5, fontWeight: 700 }}>{money(item.net)}</Text>;
            break;
        }
        return (
          <View key={c.key} style={cell}>
            {body}
          </View>
        );
      })}
    </View>
  );
}

function InfoRow({ label, value, ltr }: { label: string; value: string; ltr?: boolean }) {
  return (
    <View style={{ flexDirection: "row-reverse", paddingVertical: 3 }}>
      <View style={{ width: "38%" }}>
        <Text style={{ direction: "rtl", textAlign: "right", fontSize: 8.5, color: C.muted }}>{label}</Text>
      </View>
      <View style={{ width: "62%" }}>
        <Text style={{ direction: ltr ? "ltr" : dirOf(value), textAlign: "right", fontSize: 9.5, fontWeight: 700 }}>{cleanText(value)}</Text>
      </View>
    </View>
  );
}

const box = { width: "49%", borderWidth: 0.8, borderColor: C.line, borderRadius: 5, padding: 9 } as const;

export function InvoiceDocument({ doc, fonts }: { doc: InvoiceDoc; fonts: string[] }) {
  const org = cleanText(doc.orgName || BRAND);
  const hasDiscount = doc.items.some((i) => i.gross - i.net > 0.004);
  const cols = columnsFor(hasDiscount);
  const status = STATUS_COLOR[doc.status];
  const title = KIND_TITLE[doc.kind];

  return (
    <Document title={`${title} ${doc.number}`} author={org} creator={PRODUCT_LINE} producer={PRODUCT_LINE} language="ar">
      <Page size="A4" style={{ fontFamily: fonts, fontSize: 9.5, color: C.ink, paddingTop: MARGIN - 4, paddingBottom: 52, paddingHorizontal: MARGIN }}>
        {/* Header band */}
        <View style={{ flexDirection: "row-reverse", justifyContent: "space-between", alignItems: "center", backgroundColor: C.brand, borderRadius: 6, paddingVertical: 12, paddingHorizontal: 16 }}>
          <View>
            <Text style={{ fontSize: 15, fontWeight: 700, color: C.white, direction: "rtl", textAlign: "right" }}>{org}</Text>
            <Text style={{ fontSize: 8, color: C.bandMuted, direction: "rtl", textAlign: "right", marginTop: 2 }}>{PRODUCT_LINE}</Text>
          </View>
          <View style={{ flexShrink: 0, marginRight: 16 }}>
            <Text style={{ fontSize: 17, fontWeight: 700, color: C.white, direction: "rtl", textAlign: "left" }}>{title}</Text>
            <Text style={{ fontSize: 10, color: C.bandMuted, direction: "ltr", textAlign: "left", marginTop: 3 }}>{doc.number}</Text>
          </View>
        </View>

        {/* Invoice data + party */}
        <View style={{ flexDirection: "row-reverse", justifyContent: "space-between", marginTop: 12 }}>
          <View style={box}>
            <Text style={{ direction: "rtl", textAlign: "right", fontSize: 8, fontWeight: 700, color: C.brand, marginBottom: 4 }}>بيانات الفاتورة</Text>
            <InfoRow label="رقم الفاتورة" value={doc.number} ltr />
            <InfoRow label="التاريخ" value={doc.date} ltr />
            {doc.info.map((r, i) => (
              <InfoRow key={i} label={r.label} value={r.value} />
            ))}
          </View>
          <View style={box}>
            <Text style={{ direction: "rtl", textAlign: "right", fontSize: 8, fontWeight: 700, color: C.brand, marginBottom: 4 }}>{doc.partyLabel}</Text>
            <Text style={{ direction: dirOf(doc.partyName), textAlign: "right", fontSize: 13, fontWeight: 700, lineHeight: 1.3 }}>{cleanText(doc.partyName)}</Text>
            <View style={{ marginTop: 10, alignItems: "flex-end" }}>
              <View style={{ width: 96, backgroundColor: status.bg, borderRadius: 10, paddingVertical: 3 }}>
                <Text style={{ direction: "rtl", textAlign: "center", fontSize: 9, fontWeight: 700, color: status.fg }}>{STATUS_TEXT[doc.status]}</Text>
              </View>
            </View>
          </View>
        </View>

        {/* Items */}
        <View style={{ marginTop: 12 }}>
          <View fixed style={{ flexDirection: "row-reverse", backgroundColor: C.brand, borderRadius: 3 }}>
            {cols.map((c, i) => (
              <View key={c.key} style={{ width: `${c.w}%`, paddingVertical: 6, paddingHorizontal: 6, justifyContent: "center", ...(i < cols.length - 1 ? { borderLeftWidth: 0.5, borderLeftColor: "#52705F" } : {}) }}>
                <Text style={{ direction: "rtl", textAlign: c.align, fontSize: 8.8, fontWeight: 700, color: C.white }}>{c.header}</Text>
              </View>
            ))}
          </View>
          {doc.items.length === 0 ? (
            <View style={{ paddingVertical: 20, borderBottomWidth: 0.6, borderBottomColor: C.line }}>
              <Text style={{ direction: "rtl", textAlign: "center", color: C.muted }}>لا توجد أصناف في هذه الفاتورة</Text>
            </View>
          ) : (
            doc.items.map((item, i) => <ItemRow key={i} item={item} index={i} cols={cols} zebra={i % 2 === 1} />)
          )}
          <Text style={{ direction: "rtl", textAlign: "right", fontSize: 7.5, color: C.muted, marginTop: 5 }}>جميع المبالغ بالجنيه المصري (ج.م)</Text>
        </View>

        {/* Payments (right) + totals (left) */}
        <View wrap={false} style={{ flexDirection: "row-reverse", justifyContent: "space-between", alignItems: "flex-start", marginTop: 10 }}>
          <View style={{ width: "52%" }}>
            {doc.payments.length > 0 ? (
              <View>
                <Text style={{ direction: "rtl", textAlign: "right", fontSize: 8.5, fontWeight: 700, color: C.brand, marginBottom: 4 }}>سجل الدفعات</Text>
                <View style={{ flexDirection: "row-reverse", backgroundColor: C.soft, borderRadius: 3 }}>
                  {[["التاريخ", "30%", "center"], ["الطريقة / ملاحظات", "42%", "right"], ["المبلغ", "28%", "right"]].map(([h, w, a]) => (
                    <View key={h} style={{ width: w, paddingVertical: 4, paddingHorizontal: 5 }}>
                      <Text style={{ direction: "rtl", textAlign: a as Align, fontSize: 8, fontWeight: 700, color: C.brand }}>{h}</Text>
                    </View>
                  ))}
                </View>
                {doc.payments.map((p, i) => (
                  <View key={i} wrap={false} style={{ flexDirection: "row-reverse", borderBottomWidth: 0.6, borderBottomColor: C.line }}>
                    <View style={{ width: "30%", paddingVertical: 4, paddingHorizontal: 5 }}>
                      <Text style={{ ...num("center"), fontSize: 8.5 }}>{p.date}</Text>
                    </View>
                    <View style={{ width: "42%", paddingVertical: 4, paddingHorizontal: 5 }}>
                      <Text style={{ direction: "rtl", textAlign: "right", fontSize: 8.5 }}>{cleanText([p.method, p.note].filter(Boolean).join(" — ")) || "—"}</Text>
                    </View>
                    <View style={{ width: "28%", paddingVertical: 4, paddingHorizontal: 5 }}>
                      <Text style={{ ...num("right"), fontSize: 8.5, fontWeight: 700 }}>{money(p.amount)}</Text>
                    </View>
                  </View>
                ))}
              </View>
            ) : null}
          </View>

          <View style={{ width: "44%" }}>
            {doc.totals.map((t, i) => (
              <View key={i} style={{ flexDirection: "row-reverse", alignItems: "center", paddingVertical: t.strong ? 6 : 3.5, paddingHorizontal: 6, ...(t.strong ? { backgroundColor: C.soft, borderTopWidth: 1, borderTopColor: C.brand, marginVertical: 2 } : {}) }}>
                <View style={{ width: "56%" }}>
                  <Text style={{ direction: "rtl", textAlign: "right", fontSize: t.strong ? 10 : 9, fontWeight: t.strong ? 700 : 400, color: t.strong ? C.ink : C.muted }}>{t.label}</Text>
                </View>
                <View style={{ width: "44%" }}>
                  <Text style={{ ...num("right"), fontSize: t.strong ? 10.5 : 9.5, fontWeight: t.strong ? 700 : 400, color: t.sign === "minus" ? C.rose : C.ink }}>
                    {`${t.sign === "minus" ? "-" : t.sign === "plus" ? "+" : ""}${money(t.value)}`}
                  </Text>
                </View>
              </View>
            ))}
            <View style={{ flexDirection: "row-reverse", alignItems: "center", marginTop: 6, paddingVertical: 8, paddingHorizontal: 8, borderRadius: 4, backgroundColor: doc.remaining > 0 ? "#F5E3E0" : C.soft }}>
              <View style={{ width: doc.remaining > 0 ? "50%" : "100%" }}>
                <Text style={{ direction: "rtl", textAlign: "right", fontSize: 10.5, fontWeight: 700, color: doc.remaining > 0 ? C.rose : C.brand }}>{doc.remaining > 0 ? "المتبقي" : "تم السداد بالكامل"}</Text>
              </View>
              {doc.remaining > 0 ? (
                <View style={{ width: "50%" }}>
                  <Text style={{ ...num("right"), fontSize: 12, fontWeight: 700, color: C.rose }}>{money(doc.remaining)}</Text>
                </View>
              ) : null}
            </View>
          </View>
        </View>

        {/* Signatures */}
        <View wrap={false} style={{ flexDirection: "row-reverse", justifyContent: "space-between", marginTop: 28 }}>
          {[doc.kind === "sales" ? "توقيع المستلم" : "توقيع المورد", "ختم وتوقيع الشركة"].map((t) => (
            <View key={t} style={{ width: "40%", borderTopWidth: 0.8, borderTopColor: C.muted, paddingTop: 5 }}>
              <Text style={{ direction: "rtl", textAlign: "center", fontSize: 8.5, color: C.muted }}>{t}</Text>
            </View>
          ))}
        </View>

        {/* Footer */}
        <View fixed style={{ position: "absolute", left: MARGIN, right: MARGIN, bottom: 18, flexDirection: "row-reverse", justifyContent: "space-between", alignItems: "center", borderTopWidth: 0.6, borderTopColor: C.line, paddingTop: 6 }}>
          <View>
            <Text style={{ fontSize: 7.5, color: C.muted, direction: "rtl", textAlign: "right" }}>{`صدرت إلكترونيًا من نظام كيان — ${generatedAtText()}`}</Text>
          </View>
          <View>
            <Text
              fixed
              style={{ fontSize: 8, color: C.muted, direction: "rtl", textAlign: "left" }}
              render={({ pageNumber, totalPages }) => (pageNumber && totalPages ? `صفحة ${pageNumber.toLocaleString("ar-EG")} من ${totalPages.toLocaleString("ar-EG")}` : " ")}
            />
          </View>
        </View>
      </Page>
    </Document>
  );
}

export async function buildInvoicePdfBlob(doc: InvoiceDoc, fontBase = "/fonts"): Promise<Blob> {
  const fonts = registerFonts(fontBase);
  return pdf(<InvoiceDocument doc={doc} fonts={fonts} />).toBlob();
}
