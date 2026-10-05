import { getSupabase, getMembership, NO_ORG_ID } from "@/lib/org-context";
import { PageHeader } from "@/components/ui/page-header";
import { DataTable } from "@/components/ui/data-table";
import { SalesTabs } from "@/components/sales/sales-tabs";
import { NewReturnButton } from "./new-return-button";

function money(n: number) {
  return n.toLocaleString("ar-EG", { minimumFractionDigits: 2 });
}

type ReturnRow = {
  id: string;
  return_date: string;
  total: number;
  cost_reversed: number; // filled in only for members with view_financial
  profit_reversed: number;
  cash_refunded: number;
  notes: string | null;
  sales_invoices: { invoice_number: string | null } | null;
  customers: { name: string } | null;
  sales_return_items: { quantity: number; condition: "resalable" | "damaged"; products: { name: string } | null }[];
};

export default async function SalesReturnsPage() {
  const supabase = getSupabase();
  const membership = await getMembership();
  const orgId = membership?.organization_id ?? NO_ORG_ID;

  const [{ data: returns }, { data: canViewFinancial }] = await Promise.all([
    supabase
      .from("sales_returns")
      .select("id, return_date, total, cash_refunded, notes, sales_invoices(invoice_number), customers(name), sales_return_items(quantity, condition, products(name))")
      .eq("organization_id", orgId)
      .order("created_at", { ascending: false }),
    membership ? supabase.rpc("has_permission", { target_org: membership.organization_id, perm_key: "view_financial" }) : Promise.resolve({ data: false }),
  ]);

  const rows = (returns as unknown as ReturnRow[]) ?? [];
  if (canViewFinancial && rows.length > 0) {
    const { data: fin } = await supabase.from("sales_return_financials").select("sales_return_id, cost_reversed, profit_reversed").in("sales_return_id", rows.map((r) => r.id));
    const byId = new Map((fin ?? []).map((f) => [f.sales_return_id, f]));
    for (const r of rows) {
      r.cost_reversed = Number(byId.get(r.id)?.cost_reversed ?? 0);
      r.profit_reversed = Number(byId.get(r.id)?.profit_reversed ?? 0);
    }
  }

  return (
    <div>
      <PageHeader title="المبيعات" />
      <SalesTabs />

      <NewReturnButton />

      <DataTable<ReturnRow>
        rows={rows}
        getRowKey={(r) => r.id}
        emptyLabel="لا توجد مرتجعات بعد"
        columns={[
          { header: "التاريخ", render: (r) => <span dir="ltr">{r.return_date}</span> },
          { header: "الفاتورة", render: (r) => r.sales_invoices?.invoice_number ?? "—" },
          { header: "العميل", render: (r) => r.customers?.name ?? "—" },
          {
            header: "الأصناف",
            render: (r) => (
              <span className="text-xs text-charcoal/60">
                {r.sales_return_items.map((it, i) => `${it.products?.name ?? "—"} (${it.quantity}${it.condition === "damaged" ? "، تالف" : ""})`).join("، ")}
              </span>
            ),
          },
          { header: "قيمة المرتجع", render: (r) => <span dir="ltr">{money(r.total)} ج.م</span> },
          ...(canViewFinancial
            ? [
                {
                  header: "أثر الربح",
                  render: (r: ReturnRow) => (
                    <span dir="ltr" className="text-rose">
                      − {money(r.profit_reversed)} ج.م
                    </span>
                  ),
                },
              ]
            : []),
          { header: "استرجاع نقدي", render: (r) => (r.cash_refunded > 0 ? <span dir="ltr">{money(r.cash_refunded)} ج.م</span> : "—") },
        ]}
      />
    </div>
  );
}
