"use client";

import { Money } from "@/components/ui/money";
import { formatMoney } from "@/lib/money";
import { useState } from "react";
import { Eye, HandCoins } from "lucide-react";
import { FulfilmentBadge } from "@/components/ui/fulfilment-badge";
import { DataTable } from "@/components/ui/data-table";
import { Modal } from "@/components/ui/modal";
import { PaymentModal } from "./payment-modal";
import { InvoiceExportButtons } from "@/components/ui/invoice-export-buttons";
import { purchaseInvoiceDoc } from "@/lib/export/invoice-model";
import type { PurchaseInvoiceRow } from "./page";

const STATUS_LABEL: Record<PurchaseInvoiceRow["payment_status"], string> = {
  paid: "مدفوعة",
  partial: "مدفوعة جزئيًا",
  unpaid: "غير مدفوعة",
};
const STATUS_CLASS: Record<PurchaseInvoiceRow["payment_status"], string> = {
  paid: "bg-sageSoft text-sage",
  partial: "bg-amber-100 text-amber-700",
  unpaid: "bg-rose/10 text-rose",
};

function money(n: number) {
  return formatMoney(n);
}

export function PurchasesTable({ invoices, canPay, showPayments }: { invoices: PurchaseInvoiceRow[]; canPay: boolean; showPayments: boolean }) {
  // keep ids, not row copies: after a payment the page data refreshes and the open details follow it
  const [viewingId, setViewingId] = useState<string | null>(null);
  const [payingId, setPayingId] = useState<string | null>(null);
  const viewing = invoices.find((inv) => inv.id === viewingId) ?? null;
  const paying = invoices.find((inv) => inv.id === payingId) ?? null;

  return (
    <>
      <DataTable<PurchaseInvoiceRow>
        rows={invoices}
        getRowKey={(inv) => inv.id}
        emptyLabel="لا توجد فواتير شراء بعد — أضف أول فاتورة أعلاه"
        columns={[
          { header: "التاريخ", render: (inv) => <span dir="ltr">{inv.invoice_date}</span> },
          { header: "رقم الفاتورة", render: (inv) => <span dir="ltr">{inv.invoice_number ?? "—"}</span> },
          { header: "المورد", render: (inv) => inv.suppliers?.name ?? "—" },
          { header: "المخزن", render: (inv) => inv.warehouses?.name ?? "—" },
          { header: "الإجمالي", render: (inv) => <span dir="ltr"><Money value={inv.total} /></span> },
          { header: "المدفوع", render: (inv) => <span dir="ltr"><Money value={inv.amount_paid} /></span> },
          ...(showPayments
            ? [
                {
                  header: "المتبقي",
                  render: (inv: PurchaseInvoiceRow) => (
                    <span dir="ltr" className={inv.remaining > 0 ? "text-rose" : "text-charcoal/40"}><Money value={inv.remaining} /></span>
                  ),
                },
              ]
            : []),
          { header: "الاستلام", render: (inv) => <FulfilmentBadge kind="purchase" status={inv.receipt_status} at={inv.received_at} /> },
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
                {canPay && inv.remaining > 0 && (
                  <button onClick={() => setPayingId(inv.id)} className="flex items-center gap-1 whitespace-nowrap rounded-card px-2 py-1.5 text-xs text-sage hover:bg-sageSoft/30">
                    <HandCoins size={15} strokeWidth={2} />
                    تسجيل دفعة
                  </button>
                )}
                <button onClick={() => setViewingId(inv.id)} className="flex items-center gap-1 whitespace-nowrap rounded-card px-2 py-1.5 text-xs text-ink/55 hover:bg-paper hover:text-ink">
                  <Eye size={15} strokeWidth={2} />
                  عرض التفاصيل
                </button>
                <InvoiceExportButtons build={(org) => purchaseInvoiceDoc(inv, org)} />
              </div>
            ),
          },
        ]}
      />

      {paying && (
        <PaymentModal
          onClose={() => setPayingId(null)}
          purchaseInvoiceId={paying.id}
          invoiceLabel={paying.invoice_number ?? paying.invoice_date}
          supplierName={paying.suppliers?.name ?? "—"}
          total={paying.total}
          paid={paying.amount_paid}
          remaining={paying.remaining}
        />
      )}

      <Modal open={!!viewing} onClose={() => setViewingId(null)} title="تفاصيل الفاتورة">
        {viewing && (
          <div className="max-h-[75vh] space-y-3 overflow-y-auto">
            <div className="flex items-center justify-between text-xs text-charcoal/50">
              <span>{viewing.suppliers?.name ?? "—"}</span>
              <span dir="ltr">{viewing.invoice_date}</span>
            </div>
            <InvoiceExportButtons variant="full" build={(org) => purchaseInvoiceDoc(viewing, org)} />
            <div className="divide-y divide-borderSoft rounded-xl border border-borderSoft">
              {viewing.purchase_invoice_items.map((item, i) => (
                <div key={i} className="px-3 py-2.5 text-sm">
                  <div className="flex items-center justify-between">
                    <span className="text-charcoal">
                      {item.products?.name ?? "—"}
                      {item.is_bonus && <span className="mr-2 rounded bg-sageSoft/50 px-1.5 py-0.5 text-[0.65rem] text-sage">Bonus</span>}
                    </span>
                    <span className="text-charcoal/45" dir="ltr">
                      {item.quantity}{item.bonus_quantity > 0 ? ` + ${item.bonus_quantity} Bonus` : ""} × {money(item.unit_cost)}
                    </span>
                    <span className="font-medium text-charcoal"><Money value={item.net_total} suffix="" /></span>
                  </div>
                  <div className="mt-1 text-[0.6875rem] text-charcoal/40" dir="ltr">التكلفة الصافية للقطعة: <Money value={item.effective_unit_cost} /></div>
                </div>
              ))}
            </div>
            <div className="space-y-1.5 text-sm text-charcoal/50">
              <div className="flex items-center justify-between"><span>إجمالي قبل الخصم</span><span dir="ltr"><Money value={viewing.subtotal} /></span></div>
              {([
                ["خصم الأصناف", viewing.line_discount_total],
                ["خصم على إجمالي الفاتورة", viewing.invoice_discount],
                ["خصم الشريحة", viewing.tier_discount],
                ["خصم الدفع الفوري", viewing.cash_discount],
              ] as [string, number][])
                .filter(([, v]) => v > 0)
                .map(([label, v]) => (
                  <div key={label} className="flex items-center justify-between"><span>{label}</span><span dir="ltr">− <Money value={v} /></span></div>
                ))}
              {viewing.bonus_units > 0 && <div className="flex items-center justify-between text-sage"><span>Bonus (قطع مجانية)</span><span dir="ltr">{viewing.bonus_units}</span></div>}
              {viewing.payment_method && <div className="flex items-center justify-between"><span>طريقة الدفع</span><span>{viewing.payment_method}</span></div>}
            </div>
            <div className="flex items-center justify-between border-t border-borderSoft pt-3 text-sm">
              <span className="text-charcoal/50">الإجمالي</span>
              <span className="font-semibold text-charcoal" dir="ltr"><Money value={viewing.total} /></span>
            </div>

            {showPayments && (
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
                          <span className="text-charcoal/60" dir="ltr">{p.payment_date}</span>
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
                      <span>مرتجعات للمورد</span>
                      <span dir="ltr">− <Money value={viewing.returns_total} /></span>
                    </div>
                  )}
                  {viewing.cash_refunded > 0 && (
                    <div className="flex items-center justify-between text-charcoal/50">
                      <span>مبالغ استردها المورد نقدًا</span>
                      <span dir="ltr">+ <Money value={viewing.cash_refunded} /></span>
                    </div>
                  )}
                  <div className="flex items-center justify-between text-charcoal/50">
                    <span>إجمالي المدفوع</span>
                    <span dir="ltr" className="text-sage"><Money value={viewing.amount_paid} /></span>
                  </div>
                  <div className="flex items-center justify-between font-semibold">
                    <span className="text-charcoal">المتبقي</span>
                    <span dir="ltr" className={viewing.remaining > 0 ? "text-rose" : "text-sage"}>
                      {viewing.remaining > 0 ? `${money(viewing.remaining)} ج.م` : "لا يوجد مبلغ متبقي"}
                    </span>
                  </div>
                </div>
                {canPay && viewing.remaining > 0 && (
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
            )}
          </div>
        )}
      </Modal>
    </>
  );
}
