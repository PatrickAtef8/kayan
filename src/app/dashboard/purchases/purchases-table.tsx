"use client";

import { useState } from "react";
import { Eye } from "lucide-react";
import { DataTable } from "@/components/ui/data-table";
import { Modal } from "@/components/ui/modal";
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
  return n.toLocaleString("ar-EG", { minimumFractionDigits: 2 });
}

export function PurchasesTable({ invoices }: { invoices: PurchaseInvoiceRow[] }) {
  const [viewing, setViewing] = useState<PurchaseInvoiceRow | null>(null);

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
          { header: "الإجمالي", render: (inv) => <span dir="ltr">{money(inv.total)} ج.م</span> },
          { header: "المدفوع", render: (inv) => <span dir="ltr">{money(inv.amount_paid)} ج.م</span> },
          {
            header: "الحالة",
            render: (inv) => (
              <span className={`rounded-full px-2.5 py-1 text-[0.6875rem] font-medium ${STATUS_CLASS[inv.payment_status]}`}>{STATUS_LABEL[inv.payment_status]}</span>
            ),
          },
          {
            header: "",
            render: (inv) => (
              <button onClick={() => setViewing(inv)} className="rounded-card p-1.5 text-ink/40 hover:bg-paper hover:text-ink" aria-label="عرض التفاصيل">
                <Eye size={16} strokeWidth={2} />
              </button>
            ),
          },
        ]}
      />

      <Modal open={!!viewing} onClose={() => setViewing(null)} title="تفاصيل الفاتورة">
        {viewing && (
          <div className="space-y-3">
            <div className="flex items-center justify-between text-xs text-charcoal/50">
              <span>{viewing.suppliers?.name ?? "—"}</span>
              <span dir="ltr">{viewing.invoice_date}</span>
            </div>
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
                    <span className="font-medium text-charcoal" dir="ltr">{money(item.net_total)}</span>
                  </div>
                  <div className="mt-1 text-[0.6875rem] text-charcoal/40" dir="ltr">التكلفة الصافية للقطعة: {money(item.effective_unit_cost)} ج.م</div>
                </div>
              ))}
            </div>
            <div className="space-y-1.5 text-sm text-charcoal/50">
              <div className="flex items-center justify-between"><span>إجمالي قبل الخصم</span><span dir="ltr">{money(viewing.subtotal)} ج.م</span></div>
              {([
                ["خصم الأصناف", viewing.line_discount_total],
                ["خصم على إجمالي الفاتورة", viewing.invoice_discount],
                ["خصم الشريحة", viewing.tier_discount],
                ["خصم الدفع الفوري", viewing.cash_discount],
              ] as [string, number][])
                .filter(([, v]) => v > 0)
                .map(([label, v]) => (
                  <div key={label} className="flex items-center justify-between"><span>{label}</span><span dir="ltr">− {money(v)} ج.م</span></div>
                ))}
              {viewing.bonus_units > 0 && <div className="flex items-center justify-between text-sage"><span>Bonus (قطع مجانية)</span><span dir="ltr">{viewing.bonus_units}</span></div>}
              {viewing.payment_method && <div className="flex items-center justify-between"><span>طريقة الدفع</span><span>{viewing.payment_method}</span></div>}
            </div>
            <div className="flex items-center justify-between border-t border-borderSoft pt-3 text-sm">
              <span className="text-charcoal/50">الإجمالي</span>
              <span className="font-semibold text-charcoal" dir="ltr">{money(viewing.total)} ج.م</span>
            </div>
          </div>
        )}
      </Modal>
    </>
  );
}
