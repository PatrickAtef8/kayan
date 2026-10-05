// Single source of truth for invoice arithmetic on the client. It mirrors what
// create_sales_invoice / create_purchase_invoice compute on the server (see
// supabase/migrations/0022_calculation_fixes.sql), so the total a person sees
// before saving is the total that gets stored.
//
//   line gross   = round2(quantity × unit price)
//   subtotal     = Σ line gross
//   line discounts = Σ per-line discount
//   total        = subtotal − line discounts − invoice discount + tax

export function round2(n: number): number {
  // Number.EPSILON nudges values like 1.005 to the side the database
  // (numeric, round-half-away-from-zero) lands on.
  return Math.sign(n) * Math.round((Math.abs(n) + Number.EPSILON) * 100) / 100;
}

export type InvoiceLine = { quantity: number; unit: number; discount: number };

export function invoiceTotals(lines: InvoiceLine[], invoiceDiscount: number, tax: number) {
  const subtotal = round2(lines.reduce((sum, l) => sum + round2(l.quantity * l.unit), 0));
  const lineDiscounts = round2(lines.reduce((sum, l) => sum + (l.discount || 0), 0));
  const netBeforeInvoiceDiscount = round2(subtotal - lineDiscounts);
  const net = round2(netBeforeInvoiceDiscount - (invoiceDiscount || 0));
  const total = round2(net + (tax || 0));
  return { subtotal, lineDiscounts, discountTotal: round2(lineDiscounts + (invoiceDiscount || 0)), net, total, netBeforeInvoiceDiscount };
}

// Mirrors the server's input checks so mistakes are caught before a round trip.
export function validateInvoiceInputs(
  lines: InvoiceLine[],
  invoiceDiscount: number,
  tax: number,
  paid: number,
  paidLabel: string,
): string | null {
  for (const l of lines) {
    if (l.quantity <= 0) return "يجب أن تكون الكمية أكبر من صفر";
    if (l.unit < 0) return "السعر لا يمكن أن يكون سالبًا";
    if (l.discount < 0) return "خصم الصنف لا يمكن أن يكون سالبًا";
    if (l.discount > round2(l.quantity * l.unit)) return "خصم الصنف أكبر من قيمة الصنف";
  }
  if (invoiceDiscount < 0) return "الخصم لا يمكن أن يكون سالبًا";
  if (tax < 0) return "الضريبة لا يمكن أن تكون سالبة";
  const t = invoiceTotals(lines, invoiceDiscount, tax);
  if (invoiceDiscount > t.netBeforeInvoiceDiscount) return "الخصم أكبر من قيمة الفاتورة";
  if (paid < 0) return `${paidLabel} لا يمكن أن يكون سالبًا`;
  if (paid > t.total) return `${paidLabel} أكبر من إجمالي الفاتورة`;
  return null;
}

// The part of `amount` that belongs to returning `qty` units when `already`
// of `totalQty` were returned before. Cumulative rounding, identical to the
// server's cumulative_share(): returning everything reverses exactly `amount`.
export function cumulativeShare(amount: number, already: number, qty: number, totalQty: number): number {
  if (!totalQty) return 0;
  return round2((amount * (already + qty)) / totalQty) - round2((amount * already) / totalQty);
}
