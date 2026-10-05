import { getSupabase, getMembership, NO_ORG_ID } from "@/lib/org-context";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { DataTable } from "@/components/ui/data-table";
import { StockAdjustmentForm } from "./stock-adjustment-form";
import { StockTransferForm } from "./stock-transfer-form";

type StockRow = {
  id: string;
  quantity: number;
  avg_cost: number;
  products: { name: string; unit: string } | null;
  warehouses: { name: string } | null;
};

function money(n: number) {
  return n.toLocaleString("ar-EG", { minimumFractionDigits: 2 });
}

export default async function InventoryPage() {
  const supabase = getSupabase();
  const membership = await getMembership();
  const orgId = membership?.organization_id ?? NO_ORG_ID;

  const [{ data }, { data: canAdjust }, { data: products }, { data: warehouses }] = await Promise.all([
    supabase.from("inventory_stock").select("id, quantity, avg_cost, products(name, unit), warehouses(name)").eq("organization_id", orgId).order("updated_at", { ascending: false }),
    membership ? supabase.rpc("has_permission", { target_org: membership.organization_id, perm_key: "inventory.adjust" }) : Promise.resolve({ data: false }),
    supabase.from("products").select("id, name").eq("organization_id", orgId).order("name"),
    supabase.from("warehouses").select("id, name").eq("organization_id", orgId).order("name"),
  ]);

  const rows = (data as unknown as StockRow[]) ?? [];
  const totalValue = rows.reduce((sum, r) => sum + r.quantity * r.avg_cost, 0);

  return (
    <div>
      <PageHeader title="المخزون" />

      {canAdjust && <StockAdjustmentForm products={products ?? []} warehouses={warehouses ?? []} />}
      {canAdjust && (warehouses?.length ?? 0) > 1 && <StockTransferForm products={products ?? []} warehouses={warehouses ?? []} />}

      <Card className="mb-7 flex items-center justify-between p-5 sm:p-6">
        <div>
          <p className="text-xs text-charcoal/45">قيمة المخزون الحالية (بمتوسط التكلفة المرجح)</p>
          <p className="mt-2 text-3xl font-semibold tracking-tight text-charcoal" dir="ltr">{money(totalValue)} ج.م</p>
        </div>
      </Card>

      <DataTable<StockRow>
        rows={rows.filter((r) => r.quantity !== 0)}
        getRowKey={(r) => r.id}
        emptyLabel="لا يوجد مخزون بعد — سيظهر هنا بعد أول فاتورة شراء"
        columns={[
          { header: "المنتج", render: (r) => r.products?.name ?? "—" },
          { header: "المخزن", render: (r) => r.warehouses?.name ?? "—" },
          { header: "الكمية", render: (r) => <span dir="ltr">{r.quantity} {r.products?.unit ?? ""}</span> },
          { header: "متوسط التكلفة", render: (r) => <span dir="ltr">{money(r.avg_cost)} ج.م</span> },
          { header: "القيمة", render: (r) => <span dir="ltr">{money(r.quantity * r.avg_cost)} ج.م</span> },
        ]}
      />
    </div>
  );
}
