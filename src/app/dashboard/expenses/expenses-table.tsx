"use client";

import { Money } from "@/components/ui/money";
import { formatMoney } from "@/lib/money";
import { useState } from "react";
import { Paperclip } from "lucide-react";
import { DataTable } from "@/components/ui/data-table";
import { Modal } from "@/components/ui/modal";
import dynamic from "next/dynamic";
import type { ExpenseRow } from "./page";
import { EXPENSE_TYPE_LABELS } from "./expense-types";

// Only needed once a row's attachments modal is opened; keeps the Supabase
// browser client out of the expenses page's initial bundle.
const AttachmentsPanel = dynamic(() => import("@/components/attachments/attachments-panel").then((m) => m.AttachmentsPanel), {
  ssr: false,
  loading: () => <div className="py-6 text-center text-xs text-charcoal/40">جارٍ التحميل...</div>,
});

function money(n: number) {
  return formatMoney(n);
}

export function ExpensesTable({ expenses, organizationId }: { expenses: ExpenseRow[]; organizationId: string }) {
  const [openId, setOpenId] = useState<string | null>(null);
  const openExpense = expenses.find((e) => e.id === openId);

  return (
    <>
      <DataTable<ExpenseRow>
        rows={expenses}
        getRowKey={(e) => e.id}
        emptyLabel="لا توجد مصروفات مسجلة بعد"
        columns={[
          { header: "التاريخ", render: (e) => <span dir="ltr">{e.expense_date}</span> },
          {
            header: "نوع المصروف",
            render: (e) => (
              <div>
                <span className="rounded-full bg-paper px-2.5 py-1 text-[0.6875rem] font-medium text-charcoal/70">{EXPENSE_TYPE_LABELS[e.expense_type] ?? e.expense_type}</span>
                {e.sales_representatives && <div className="mt-1 text-[0.6875rem] text-charcoal/45">{e.sales_representatives.name}</div>}
              </div>
            ),
          },
          { header: "التصنيف (للتقارير)", render: (e) => e.expense_categories?.name ?? <span className="text-charcoal/30">بدون تصنيف</span> },
          { header: "ملاحظة", render: (e) => e.description ?? "—" },
          { header: "طريقة الدفع", render: (e) => e.payment_method ?? "—" },
          { header: "المبلغ", render: (e) => <span dir="ltr" className="font-medium text-rose">− <Money value={e.amount} /></span> },
          {
            header: "المرفقات",
            render: (e) => (
              <button type="button" onClick={() => setOpenId(e.id)} className="flex items-center gap-1 text-xs font-medium text-charcoal/50 hover:text-sage">
                <Paperclip size={12} strokeWidth={1.8} />
                عرض
              </button>
            ),
          },
        ]}
      />

      {openExpense && organizationId && (
        <Modal open={!!openExpense} onClose={() => setOpenId(null)} title={`مرفقات — ${openExpense.description ?? openExpense.expense_date}`}>
          <AttachmentsPanel organizationId={organizationId} entityType="expense" entityId={openExpense.id} />
        </Modal>
      )}
    </>
  );
}
