"use client";

import { Money } from "@/components/ui/money";
import { formatMoney } from "@/lib/money";
import { DataTable } from "@/components/ui/data-table";
import type { MovementRow } from "./page";

const CATEGORY_LABEL: Record<string, string> = {
  customer_collection: "تحصيل من عميل",
  sales_cash: "بيع نقدي",
  supplier_payment: "دفعة لمورد",
  expense: "مصروف",
  partner_withdrawal: "سحب شريك",
  other_income: "دخل آخر",
  other_payment: "مصروف آخر",
};

function money(n: number) {
  return formatMoney(n);
}

export function TreasuryTable({ movements }: { movements: MovementRow[] }) {
  return (
    <DataTable<MovementRow>
      rows={movements}
      getRowKey={(m) => m.id}
      emptyLabel="لا توجد حركات خزنة بعد"
      columns={[
        { header: "التاريخ", render: (m) => <span dir="ltr">{m.movement_date}</span> },
        { header: "النوع", render: (m) => CATEGORY_LABEL[m.category] ?? m.category },
        { header: "الوصف", render: (m) => m.description ?? "—" },
        {
          header: "المبلغ",
          render: (m) => (
            <span dir="ltr" className={`font-medium ${m.direction === "in" ? "text-sage" : "text-rose"}`}>
              {m.direction === "in" ? "+" : "−"} <Money value={m.amount} />
            </span>
          ),
        },
      ]}
    />
  );
}
