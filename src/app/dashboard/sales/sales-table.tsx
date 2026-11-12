"use client";

import { Money } from "@/components/ui/money";
import { formatQty, formatDateDigits, formatPercent } from "@/lib/money";
import { Num } from "@/components/ui/num";
import { useState } from "react";
import { Eye, HandCoins, Undo2 } from "lucide-react";
import { FulfilmentBadge } from "@/components/ui/fulfilment-badge";
import { DataTable } from "@/components/ui/data-table";
import { Modal } from "@/components/ui/modal";
import { COMMISSION_BASIS_LABELS } from "../representatives/commission-basis";
import { ReturnFormModal } from "./returns/return-form-modal";
import { PaymentModal } from "./payment-modal";
import { InvoiceExportButtons } from "@/components/ui/invoice-export-buttons";
import { salesInvoiceDoc } from "@/lib/export/invoice-model";
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

export function SalesTable({ invoices, canViewFinancial, canCollect }: { invoices: SalesInvoiceRow[]; canViewFinancial: boolean; canCollect: boolean }) {
  // keep ids, not row copies: after a payment the page data refreshes and the open details follow it
  const [viewingId, setViewingId] = useState<string | null>(null);
  const [returning, setReturning] = useState<SalesInvoiceRow | null>(null);
  const [payingId, setPayingId] = useState<string | null>(null);
  const viewing = invoices.find((inv) => inv.id === viewingId) ?? null;
  const paying = invoices.find((inv) => inv.id === payingId) ?? null;

  return (
    <>
      <DataTable<SalesInvoiceRow>
        rows={invoices}
        getRowKey={(inv) => inv.id}
        emptyLabel="لا توجد فواتير بيع بعد — أضف أول فاتورة أعلاه"
        columns={[
          { header: "التاريخ", render: (inv) => <span dir="ltr">{formatDateDigits(inv.invoice_date)}</span> },
          { header: "رقم الفاتورة", render: (inv) => <span dir="ltr">{inv.invoice_number ?? "—"}</span> },
          { header: "العميل", render: (inv) => inv.customers?.name ?? "—" },
          { header: "المندوب", render: (inv) => inv.sales_representatives?.name ?? "—" },
          { header: "المخزن", render: (inv) => inv.warehouses?.name ?? "—" },
          { header: "الإجمالي", render: (inv) => <span dir="ltr"><Money value={inv.total} /></span> },
          ...(canViewFinancial
            ? [
                {
                  header: "الربح",
                  render: (inv: SalesInvoiceRow) => (
                    <span dir="ltr" className={inv.profit_total >= 0 ? "text-sage" : "text-rose"}>
                      <Money value={inv.profit_total} />
                    </span>
                  ),
                },
              ]
            : []),
          { header: "المدفوع", render: (inv) => <span dir="ltr"><Money value={inv.amount_paid} /></span> },
          {
            header: "المتبقي",
            render: (inv) => (
              <span dir="ltr" className={inv.remaining > 0 ? "text-rose" : "text-charcoal/40"}><Money value={inv.remaining} /></span>
            ),
          },
          { header: "الصرف", render: (inv) => <FulfilmentBadge kind="sales" status={inv.dispatch_status} at={inv.dispatched_at} /> },
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
                {canCollect && inv.remaining > 0 && (
                  <button onClick={() => setPayingId(inv.id)} className="flex items-center gap-1 whitespace-nowrap rounded-card px-2 py-1.5 text-xs text-sage hover:bg-sageSoft/30">
                    <HandCoins size={15} strokeWidth={2} />
                    تسجيل دفعة
                  </button>
                )}
                <button onClick={() => setViewingId(inv.id)} className="flex items-center gap-1 whitespace-nowrap rounded-card px-2 py-1.5 text-xs text-ink/55 hover:bg-paper hover:text-ink">
                  <Eye size={15} strokeWidth={2} />
                  عرض التفاصيل
                </button>
                <InvoiceExportButtons build={(org) => salesInvoiceDoc(inv, org)} />
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

      {paying && (
        <PaymentModal
          onClose={() => setPayingId(null)}
          salesInvoiceId={paying.id}
          invoiceLabel={paying.invoice_number ?? paying.invoice_date}
          customerName={paying.customers?.name ?? "—"}
          total={paying.total}
          paid={paying.amount_paid}
          remaining={paying.remaining}
        />
      )}

      <Modal open={!!viewing} onClose={() => setViewingId(null)} title="تفاصيل الفاتورة">
        {viewing && (
          <div className="max-h-[75vh] space-y-3 overflow-y-auto">
            <div className="flex items-center justify-between text-xs text-charcoal/50">
              <span>{viewing.customers?.name ?? "—"}</span>
              <Num>{formatDateDigits(viewing.invoice_date)}</Num>
            </div>
            <InvoiceExportButtons variant="full" build={(org) => salesInvoiceDoc(viewing, org)} />
            <div className="divide-y divide-borderSoft rounded-xl border border-borderSoft">
              {viewing.sales_invoice_items.map((item, i) => (
                <div key={i} className="px-3 py-2.5 text-sm">
                  <div className="flex items-center justify-between">
                    <span className="text-charcoal">
                      {item.products?.name ?? "—"}
                      {item.is_bonus && <span className="mr-2 rounded bg-sageSoft/50 px-1.5 py-0.5 text-[0.65rem] text-sage">بونص</span>}
                    </span>
                    <span className="text-charcoal/45" dir="rtl">
                      <Num>{formatQty(item.quantity)}</Num>{item.bonus_quantity > 0 && <> + <Num>{formatQty(item.bonus_quantity)}</Num> بونص</>} × <Money value={item.unit_price} suffix="" />
                    </span>
                    <span className="font-medium text-charcoal"><Money value={item.net_total} suffix="ج.م" /></span>
                  </div>
                  <div className="mt-1 text-[0.6875rem] text-charcoal/40">
                    السعر الصافي للقطعة: <Money value={item.effective_unit_price} />
                  </div>
                  {canViewFinancial && (
                    <div className="mt-1 text-[0.6875rem] text-charcoal/40">
                      التكلفة: <Money value={item.cost_total} /> · الربح: <Money value={item.profit} />
                    </div>
                  )}
                </div>
              ))}
            </div>
            <div className="space-y-1.5 border-t border-borderSoft pt-3 text-sm">
              <div className="flex items-center justify-between text-charcoal/50">
                <span>إجمالي المبيعات</span>
                <span dir="ltr"><Money value={viewing.subtotal} /></span>
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
                    <Money value={v} sign="−" />
                  </div>
                ))}
              {viewing.bonus_units > 0 && (
                <div className="flex items-center justify-between text-sage">
                  <span>بونص (قطع مجانية)</span>
                  <Num>{formatQty(viewing.bonus_units)}</Num>
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
                  <Money value={viewing.tax_total} sign="+" />
                </div>
              )}
              <div className="flex items-center justify-between font-semibold text-charcoal">
                <span>الإجمالي</span>
                <span dir="ltr"><Money value={viewing.total} /></span>
              </div>
              {canViewFinancial && (
                <>
                  <div className="flex items-center justify-between text-charcoal/50">
                    <span>التكلفة (COGS)</span>
                    <span dir="ltr"><Money value={viewing.cogs_total} /></span>
                  </div>
                  <div className="flex items-center justify-between font-semibold">
                    <span className="text-charcoal">الربح</span>
                    <span className={`inline-flex items-center gap-1.5 ${viewing.profit_total >= 0 ? "text-sage" : "text-rose"}`}>
                      <Money value={viewing.profit_total} />
                      {viewing.subtotal - viewing.discount_total > 0 && (
                        <span className="text-[0.6875rem] font-normal text-charcoal/40">
                          (<Num>{formatPercent((viewing.profit_total / (viewing.subtotal - viewing.discount_total)) * 100)}</Num>)
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
                  <span dir="ltr"><Money value={viewing.commission_amount} /></span>
                </div>
              )}
            </div>

            <div className="space-y-2 border-t border-borderSoft pt-3">
              <div className="flex items-center justify-between text-sm font-medium text-charcoal">
                <span>سجل الدفعات</span>
                <span className={`rounded-full px-2.5 py-1 text-[0.6875rem] font-medium ${STATUS_CLASS[viewing.payment_status]}`}>{STATUS_LABEL[viewing.payment_status]}</span>
              </div>
              {viewing.payments.length === 0 ? (
                <p className="text-xs text-charcoal/45">لا توجد دفعات مسجلة على هذه الفاتورة.</p>
              ) : (
                <div className="divide-y divide-borderSoft rounded-xl border border-borderSoft">
                  {viewing.payments.map((p) => (
                    <div key={p.id} className="px-3 py-2 text-sm">
                      <div className="flex items-center justify-between">
                        <Num className="text-charcoal/60">{formatDateDigits(p.collection_date)}</Num>
                        <span className="font-medium text-charcoal" dir="ltr"><Money value={p.amount} /></span>
                      </div>
                      {(p.payment_method || p.notes) && (
                        <div className="mt-0.5 text-[0.6875rem] text-charcoal/40">{[p.payment_method, p.notes].filter(Boolean).join(" — ")}</div>
                      )}
                    </div>
                  ))}
                </div>
              )}
              <div className="space-y-1.5 pt-1 text-sm">
                <div className="flex items-center justify-between text-charcoal/50">
                  <span>إجمالي الفاتورة</span>
                  <span dir="ltr"><Money value={viewing.total} /></span>
                </div>
                {viewing.returns_total > 0 && (
                  <div className="flex items-center justify-between text-charcoal/50">
                    <span>مرتجعات</span>
                    <Money value={viewing.returns_total} sign="−" />
                  </div>
                )}
                {viewing.cash_refunded > 0 && (
                  <div className="flex items-center justify-between text-charcoal/50">
                    <span>مبالغ استُرجعت نقدًا للعميل</span>
                    <Money value={viewing.cash_refunded} sign="+" />
                  </div>
                )}
                <div className="flex items-center justify-between text-charcoal/50">
                  <span>إجمالي المدفوع</span>
                  <span dir="ltr" className="text-sage"><Money value={viewing.amount_paid} /></span>
                </div>
                <div className="flex items-center justify-between font-semibold">
                  <span className="text-charcoal">المتبقي</span>
                  <span className={viewing.remaining > 0 ? "text-rose" : "text-sage"}>
                    {viewing.remaining > 0 ? <Money value={viewing.remaining} /> : "لا يوجد مبلغ متبقي"}
                  </span>
                </div>
              </div>
              {canCollect && viewing.remaining > 0 && (
                <button
                  onClick={() => {
                    setViewingId(null);
                    setPayingId(viewing.id);
                  }}
                  className="mt-1 w-full rounded-xl border border-borderSoft py-2 text-sm text-sage hover:border-sage hover:bg-sageSoft/30"
                >
                  تسجيل دفعة جديدة
                </button>
              )}
            </div>
          </div>
        )}
      </Modal>
    </>
  );
}
