import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { DataTable } from "@/components/ui/data-table";
import { PurchasesTabs } from "@/components/purchases/purchases-tabs";
import { NewReturnButton } from "./new-return-button";

function money(n: number) {
  return n.toLocaleString("ar-EG", { minimumFractionDigits: 2 });
}

type ReturnRow = {
  id: string;
  return_date: string;
  total: number;
  cash_refunded: number;
  notes: string | null;
  purchase_invoices: { invoice_number: string | null } | null;
  suppliers: { name: string } | null;
  purchase_return_items: { quantity: number; products: { name: string } | null }[];
};

export default async function PurchaseReturnsPage() {
  const supabase = createClient();

  const [{ data: returns }] = await Promise.all([
    supabase
      .from("purchase_returns")
      .select("id, return_date, total, cash_refunded, notes, purchase_invoices(invoice_number), suppliers(name), purchase_return_items(quantity, products(name))")
      .order("created_at", { ascending: false }),
  ]);

  const rows = (returns as unknown as ReturnRow[]) ?? [];

  return (
    <div>
      <PageHeader title="المشتريات" />
      <PurchasesTabs />

      <NewReturnButton />

      <DataTable<ReturnRow>
        rows={rows}
        getRowKey={(r) => r.id}
        emptyLabel="لا توجد مرتجعات بعد"
        columns={[
          { header: "التاريخ", render: (r) => <span dir="ltr">{r.return_date}</span> },
          { header: "الفاتورة", render: (r) => r.purchase_invoices?.invoice_number ?? "—" },
          { header: "المورد", render: (r) => r.suppliers?.name ?? "—" },
          {
            header: "الأصناف",
            render: (r) => (
              <span className="text-xs text-charcoal/60">{r.purchase_return_items.map((it) => `${it.products?.name ?? "—"} (${it.quantity})`).join("، ")}</span>
            ),
          },
          { header: "قيمة المرتجع", render: (r) => <span dir="ltr">{money(r.total)} ج.م</span> },
          { header: "استرجاع نقدي", render: (r) => (r.cash_refunded > 0 ? <span dir="ltr">{money(r.cash_refunded)} ج.م</span> : "—") },
        ]}
      />
    </div>
  );
}
