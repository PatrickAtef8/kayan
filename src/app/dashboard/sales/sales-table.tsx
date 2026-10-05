"use client";

import { useState } from "react";
import { Eye, Undo2 } from "lucide-react";
import { DataTable } from "@/components/ui/data-table";
import { Modal } from "@/components/ui/modal";
import { COMMISSION_BASIS_LABELS } from "../representatives/commission-basis";
import { ReturnFormModal } from "./returns/return-form-modal";
import type { SalesInvoiceRow } from "./page";

const STATUS_LABEL: Record<SalesInvoiceRow["payment_status"], string> = {
  paid: "مدفوعة",
  partial: "مدفوعة جزئيًا",
  unpaid: "غير مدفوعة",
};
const STATUS_CLASS: Record<SalesInvoiceRow["payment_status"], string> = {
  paid: "bg-sageSoft text-sage",
  partial: "bg-amber-100 text-amber-700",
  unpaid: "bg-rose/10 text-rose",
};

function money(n: number) {
  return n.toLocaleString("ar-EG", { minimumFractionDigits: 2 });
}

export function SalesTable({ invoices, canViewFinancial }: { invoices: SalesInvoiceRow[]; canViewFinancial: boolean }) {
  const [viewing, setViewing] = useState<SalesInvoiceRow | null>(null);
  const [returning, setReturning] = useState<SalesInvoiceRow | null>(null);

  return (
    <>
      <DataTable<SalesInvoiceRow>
        rows={invoices}
        getRowKey={(inv) => inv.id}
        emptyLabel="لا توجد فواتير بيع بعد — أضف أول فاتورة أعلاه"
        columns={[
          { header: "التاريخ", render: (inv) => <span dir="ltr">{inv.invoice_date}</span> },
          { header: "رقم الفاتورة", render: (inv) => <span dir="ltr">{inv.invoice_number ?? "—"}</span> },
          { header: "العميل", render: (inv) => inv.customers?.name ?? "—" },
          { header: "المندوب", render: (inv) => inv.sales_representatives?.name ?? "—" },
          { header: "المخزن", render: (inv) => inv.warehouses?.name ?? "—" },
          { header: "الإجمالي", render: (inv) => <span dir="ltr">{money(inv.total)} ج.م</span> },
          ...(canViewFinancial
            ? [
                {
                  header: "الربح",
                  render: (inv: SalesInvoiceRow) => (
                    <span dir="ltr" className={inv.profit_total >= 0 ? "text-sage" : "text-rose"}>
                      {money(inv.profit_total)} ج.م
                    </span>
                  ),
                },
              ]
            : []),
          {
            header: "الحالة",
            render: (inv) => (
              <span className={`rounded-full px-2.5 py-1 text-[0.6875rem] font-medium ${STATUS_CLASS[inv.payment_status]}`}>{STATUS_LABEL[inv.payment_status]}</span>
            ),
          },
          {
            header: "",
            render: (inv) => (
              <div className="flex items-center gap-1">
                <button onClick={() => setViewing(inv)} className="rounded-card p-1.5 text-ink/40 hover:bg-paper hover:text-ink" aria-label="عرض التفاصيل">
                  <Eye size={16} strokeWidth={2} />
                </button>
                <button onClick={() => setReturning(inv)} className="rounded-card p-1.5 text-ink/40 hover:bg-paper hover:text-ink" aria-label="تسجيل مرتجع">
                  <Undo2 size={16} strokeWidth={2} />
                </button>
              </div>
            ),
          },
        ]}
      />

      {returning && (
        <ReturnFormModal
          open={!!returning}
          onClose={() => setReturning(null)}
          salesInvoiceId={returning.id}
          invoiceLabel={returning.invoice_number ?? returning.invoice_date}
        />
      )}

      <Modal open={!!viewing} onClose={() => setViewing(null)} title="تفاصيل الفاتورة">
        {viewing && (
          <div className="space-y-3">
            <div className="flex items-center justify-between text-xs text-charcoal/50">
              <span>{viewing.customers?.name ?? "—"}</span>
              <span dir="ltr">{viewing.invoice_date}</span>
            </div>
            <div className="divide-y divide-borderSoft rounded-xl border border-borderSoft">
              {viewing.sales_invoice_items.map((item, i) => (
                <div key={i} className="px-3 py-2.5 text-sm">
                  <div className="flex items-center justify-between">
                    <span className="text-charcoal">
                      {item.products?.name ?? "—"}
                      {item.is_bonus && <span className="mr-2 rounded bg-sageSoft/50 px-1.5 py-0.5 text-[0.65rem] text-sage">Bonus</span>}
                    </span>
                    <span className="text-charcoal/45" dir="ltr">
                      {item.quantity}{item.bonus_quantity > 0 ? ` + ${item.bonus_quantity} Bonus` : ""} × {money(item.unit_price)}
                    </span>
                    <span className="font-medium text-charcoal" dir="ltr">{money(item.net_total)}</span>
                  </div>
                  <div className="mt-1 text-[0.6875rem] text-charcoal/40" dir="ltr">
                    السعر الصافي للقطعة: {money(item.effective_unit_price)} ج.م
                  </div>
                  {canViewFinancial && (
                    <div className="mt-1 text-[0.6875rem] text-charcoal/40" dir="ltr">
                      تكلفة: {money(item.cost_total)} — ربح: {money(item.profit)}
                    </div>
                  )}
                </div>
              ))}
            </div>
            <div className="space-y-1.5 border-t border-borderSoft pt-3 text-sm">
              <div className="flex items-center justify-between text-charcoal/50">
                <span>إجمالي المبيعات</span>
                <span dir="ltr">{money(viewing.subtotal)} ج.م</span>
              </div>
              {([
                ["خصم الأصناف", viewing.line_discount_total],
                ["خصم على إجمالي الفاتورة", viewing.invoice_discount],
                ["خصم الشريحة", viewing.tier_discount],
                ["خصم الدفع الفوري", viewing.cash_discount],
              ] as [string, number][])
                .filter(([, v]) => v > 0)
                .map(([label, v]) => (
                  <div key={label} className="flex items-center justify-between text-charcoal/50">
                    <span>{label}</span>
                    <span dir="ltr">− {money(v)} ج.م</span>
                  </div>
                ))}
              {viewing.bonus_units > 0 && (
                <div className="flex items-center justify-between text-sage">
                  <span>Bonus (قطع مجانية)</span>
                  <span dir="ltr">{viewing.bonus_units}</span>
                </div>
              )}
              {viewing.payment_method && (
                <div className="flex items-center justify-between text-charcoal/50">
                  <span>طريقة الدفع</span>
                  <span>{viewing.payment_method}</span>
                </div>
              )}
              {viewing.tax_total > 0 && (
                <div className="flex items-center justify-between text-charcoal/50">
                  <span>الضريبة</span>
                  <span dir="ltr">+ {money(viewing.tax_total)} ج.م</span>
                </div>
              )}
              <div className="flex items-center justify-between font-semibold text-charcoal">
                <span>الإجمالي</span>
                <span dir="ltr">{money(viewing.total)} ج.م</span>
              </div>
              {canViewFinancial && (
                <>
                  <div className="flex items-center justify-between text-charcoal/50">
                    <span>التكلفة (COGS)</span>
                    <span dir="ltr">{money(viewing.cogs_total)} ج.م</span>
                  </div>
                  <div className="flex items-center justify-between font-semibold">
                    <span className="text-charcoal">الربح</span>
                    <span dir="ltr" className={viewing.profit_total >= 0 ? "text-sage" : "text-rose"}>
                      {money(viewing.profit_total)} ج.م
                      {viewing.subtotal - viewing.discount_total > 0 && (
                        <span className="mr-1 text-[0.6875rem] font-normal text-charcoal/40">
                          ({((viewing.profit_total / (viewing.subtotal - viewing.discount_total)) * 100).toFixed(1)}%)
                        </span>
                      )}
                    </span>
                  </div>
                </>
              )}
              {canViewFinancial && viewing.sales_representatives && (
                <div className="flex items-center justify-between text-charcoal/50">
                  <span>
                    عمولة {viewing.sales_representatives.name}
                    {viewing.commission_basis_snapshot && ` (${COMMISSION_BASIS_LABELS[viewing.commission_basis_snapshot] ?? viewing.commission_basis_snapshot})`}
                  </span>
                  <span dir="ltr">{money(viewing.commission_amount)} ج.م</span>
                </div>
              )}
            </div>
          </div>
        )}
      </Modal>
    </>
  );
}
