// A single invoice as a customer-facing document (PDF / Excel). It is built from the same row the invoices table already
// holds, and deliberately contains NO cost, profit or commission — an invoice is something the other party receives.

export type InvoiceKind = "sales" | "purchase";
export type PayStatus = "paid" | "partial" | "unpaid";

export type InvoiceItem = {
  name: string;
  qty: number;
  bonusQty: number;
  unitPrice: number;
  /** before line discount */
  gross: number;
  /** after line discount */
  net: number;
  isBonus: boolean;
};

export type InvoiceTotalLine = { label: string; value: number; sign?: "minus" | "plus"; strong?: boolean };

export type InvoiceDoc = {
  kind: InvoiceKind;
  number: string;
  date: string;
  partyLabel: string; // "العميل" | "المورد"
  partyName: string;
  info: { label: string; value: string }[]; // المخزن، المندوب، طريقة الدفع …
  status: PayStatus;
  items: InvoiceItem[];
  totals: InvoiceTotalLine[];
  payments: { date: string; amount: number; method: string; note: string }[];
  paid: number;
  remaining: number;
  orgName?: string;
};

export const STATUS_TEXT: Record<PayStatus, string> = { paid: "مدفوعة", partial: "مدفوعة جزئيًا", unpaid: "غير مدفوعة" };
export const KIND_TITLE: Record<InvoiceKind, string> = { sales: "فاتورة مبيعات", purchase: "فاتورة مشتريات" };

const n = (v: unknown) => Number(v ?? 0) || 0;
const r2 = (v: number) => Math.round(v * 100) / 100;

type SalesItemIn = { quantity: number; bonus_quantity: number; is_bonus: boolean; net_total: number; unit_price: number; line_total: number; products: { name: string } | null };
type SalesRowIn = {
  invoice_number: string | null;
  invoice_date: string;
  total: number;
  amount_paid: number;
  payment_status: PayStatus;
  subtotal: number;
  line_discount_total: number;
  invoice_discount: number;
  cash_discount: number;
  tier_discount: number;
  tax_total: number;
  payment_method: string | null;
  payments: { amount: number; collection_date: string; payment_method: string | null; notes: string | null }[];
  returns_total: number;
  cash_refunded: number;
  remaining: number;
  customers: { name: string } | null;
  warehouses: { name: string } | null;
  sales_representatives: { name: string } | null;
  sales_invoice_items: SalesItemIn[];
};

type PurchaseItemIn = { quantity: number; bonus_quantity: number; is_bonus: boolean; unit_cost: number; net_total: number; line_total: number; products: { name: string } | null };
type PurchaseRowIn = {
  invoice_number: string | null;
  invoice_date: string;
  total: number;
  amount_paid: number;
  payment_status: PayStatus;
  subtotal: number;
  line_discount_total: number;
  invoice_discount: number;
  cash_discount: number;
  tier_discount: number;
  payment_method: string | null;
  payments: { amount: number; payment_date: string; payment_method: string | null; notes: string | null }[];
  returns_total: number;
  cash_refunded: number;
  remaining: number;
  suppliers: { name: string } | null;
  warehouses: { name: string } | null;
  purchase_invoice_items: PurchaseItemIn[];
};

function totalsFor(
  r: { subtotal: number; line_discount_total: number; invoice_discount: number; tier_discount: number; cash_discount: number; total: number; amount_paid: number; returns_total: number; cash_refunded: number; remaining: number },
  tax: number,
  subtotalLabel: string,
): InvoiceTotalLine[] {
  const lines: InvoiceTotalLine[] = [{ label: subtotalLabel, value: n(r.subtotal) }];
  const discounts: [string, number][] = [
    ["خصم الأصناف", n(r.line_discount_total)],
    ["خصم على إجمالي الفاتورة", n(r.invoice_discount)],
    ["خصم الشريحة", n(r.tier_discount)],
    ["خصم الدفع الفوري", n(r.cash_discount)],
  ];
  for (const [label, v] of discounts) if (v > 0) lines.push({ label, value: v, sign: "minus" });
  if (tax > 0) lines.push({ label: "الضريبة", value: tax, sign: "plus" });
  lines.push({ label: "إجمالي الفاتورة", value: n(r.total), strong: true });
  if (n(r.returns_total) > 0) lines.push({ label: "مرتجعات", value: n(r.returns_total), sign: "minus" });
  if (n(r.cash_refunded) > 0) lines.push({ label: "مبالغ استُرجعت نقدًا", value: n(r.cash_refunded), sign: "plus" });
  lines.push({ label: "إجمالي المدفوع", value: n(r.amount_paid) });
  return lines;
}

const clean = (v: string | null | undefined) => (v ?? "").trim();

export function salesInvoiceDoc(r: SalesRowIn, orgName?: string): InvoiceDoc {
  const info: InvoiceDoc["info"] = [];
  if (r.warehouses?.name) info.push({ label: "المخزن", value: r.warehouses.name });
  if (r.sales_representatives?.name) info.push({ label: "المندوب", value: r.sales_representatives.name });
  if (clean(r.payment_method)) info.push({ label: "طريقة الدفع", value: clean(r.payment_method) });
  return {
    kind: "sales",
    number: clean(r.invoice_number) || "—",
    date: r.invoice_date,
    partyLabel: "العميل",
    partyName: r.customers?.name ?? "—",
    info,
    status: r.payment_status,
    items: r.sales_invoice_items.map((i) => ({
      name: i.products?.name ?? "—",
      qty: n(i.quantity),
      bonusQty: n(i.bonus_quantity),
      unitPrice: n(i.unit_price),
      gross: n(i.line_total),
      net: n(i.net_total),
      isBonus: !!i.is_bonus,
    })),
    totals: totalsFor(r, n(r.tax_total), "إجمالي المبيعات"),
    payments: r.payments.map((p) => ({ date: p.collection_date, amount: n(p.amount), method: clean(p.payment_method), note: clean(p.notes) })),
    paid: n(r.amount_paid),
    remaining: r2(n(r.remaining)),
    orgName,
  };
}

export function purchaseInvoiceDoc(r: PurchaseRowIn, orgName?: string): InvoiceDoc {
  const info: InvoiceDoc["info"] = [];
  if (r.warehouses?.name) info.push({ label: "المخزن", value: r.warehouses.name });
  if (clean(r.payment_method)) info.push({ label: "طريقة الدفع", value: clean(r.payment_method) });
  return {
    kind: "purchase",
    number: clean(r.invoice_number) || "—",
    date: r.invoice_date,
    partyLabel: "المورد",
    partyName: r.suppliers?.name ?? "—",
    info,
    status: r.payment_status,
    items: r.purchase_invoice_items.map((i) => ({
      name: i.products?.name ?? "—",
      qty: n(i.quantity),
      bonusQty: n(i.bonus_quantity),
      unitPrice: n(i.unit_cost),
      gross: n(i.line_total),
      net: n(i.net_total),
      isBonus: !!i.is_bonus,
    })),
    totals: totalsFor(r, 0, "إجمالي المشتريات"),
    payments: r.payments.map((p) => ({ date: p.payment_date, amount: n(p.amount), method: clean(p.payment_method), note: clean(p.notes) })),
    paid: n(r.amount_paid),
    remaining: r2(n(r.remaining)),
    orgName,
  };
}

export function invoiceFileName(doc: InvoiceDoc): string {
  return `${KIND_TITLE[doc.kind]} ${doc.number !== "—" ? doc.number : doc.date}`;
}
