"use client";

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
  return n.toLocaleString("ar-EG", { minimumFractionDigits: 2 });
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
          { header: "التصنيف", render: (e) => e.expense_categories?.name ?? "—" },
          { header: "النوع", render: (e) => `${EXPENSE_TYPE_LABELS[e.expense_type] ?? e.expense_type}${e.sales_representatives ? ` — ${e.sales_representatives.name}` : ""}` },
          { header: "الوصف", render: (e) => e.description ?? "—" },
          { header: "طريقة الدفع", render: (e) => e.payment_method ?? "—" },
          { header: "المبلغ", render: (e) => <span dir="ltr" className="font-medium text-rose">− {money(e.amount)} ج.م</span> },
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
