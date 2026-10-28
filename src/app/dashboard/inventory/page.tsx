import { Money } from "@/components/ui/money";
import { formatMoney } from "@/lib/money";
import { getSupabase, getMembership, NO_ORG_ID, hasPermission, hasAnyPermission } from "@/lib/org-context";
import { Pagination } from "@/components/ui/pagination";
import Link from "next/link";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { StatValue } from "@/components/ui/stat-value";
import { DataTable } from "@/components/ui/data-table";
import { StockAdjustmentForm } from "./stock-adjustment-form";
import { StockTransferForm } from "./stock-transfer-form";

const PAGE_SIZE = 50;

type StockRow = {
  id: string;
  quantity: number;
  product_id?: string;
  warehouse_id?: string;
  avg_cost: number;
  products: { name: string; unit: string } | null;
  warehouses: { name: string } | null;
};

function money(n: number) {
  return formatMoney(n);
}

export default async function InventoryPage(props: { searchParams: Promise<{ page?: string }> }) {
  const searchParams = await props.searchParams;
  const page = Math.max(1, Number(searchParams.page) || 1);
  const supabase = (await getSupabase());
  const membership = await getMembership();
  const orgId = membership?.organization_id ?? NO_ORG_ID;

  // One batch. The stock list is paginated (rows with a zero quantity are filtered in SQL, as the page used to do in
  // memory) and the total value comes from SQL (0059), so the page no longer downloads — and joins — every stock row.
  const [{ data, count }, canAdjust, { data: products }, { data: warehouses }, viewCost, totalValueRes, resvRes] = await Promise.all([
    supabase
      .from("inventory_stock")
      .select("id, quantity, product_id, warehouse_id, stock_costs(avg_cost), products(name, unit), warehouses(name)", { count: "exact" })
      .eq("organization_id", orgId)
      .neq("quantity", 0)
      .order("updated_at", { ascending: false })
      .order("id")
      .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1),
    hasPermission("inventory.adjust"),
    supabase.from("products").select("id, name").eq("organization_id", orgId).order("name"),
    supabase.from("warehouses").select("id, name").eq("organization_id", orgId).order("name"),
    // cost comes from the protected stock_costs table (0034); hidden for roles without cost access
    hasAnyPermission(["view_financial", "products.view_cost"]),
    membership ? supabase.rpc("inventory_value_total", { org_id: membership.organization_id }) : Promise.resolve({ data: 0 }),
    // reserved = sold but not yet dispatched; incoming = bought but not yet received (0044). Quantities only.
    membership ? supabase.rpc("inventory_reservations", { org_id: membership.organization_id }) : Promise.resolve({ data: [] }),
  ]);

  type RawRow = Omit<StockRow, "avg_cost"> & { stock_costs: { avg_cost: number } | { avg_cost: number }[] | null };
  const rows: StockRow[] = ((data as unknown as RawRow[]) ?? []).map((r) => {
    const c = Array.isArray(r.stock_costs) ? r.stock_costs[0] : r.stock_costs;
    return { id: r.id, quantity: r.quantity, product_id: (r as unknown as StockRow).product_id, warehouse_id: (r as unknown as StockRow).warehouse_id, products: r.products, warehouses: r.warehouses, avg_cost: Number(c?.avg_cost ?? 0) };
  });
  const totalValue = Number(totalValueRes.data ?? 0);

  // reserved = sold but not yet dispatched; incoming = bought but not yet received (0044). Quantities only.
  const resv = resvRes.data;
  const resvByKey = new Map<string, { reserved: number; incoming: number }>();
  for (const r of (resv as { product_id: string; warehouse_id: string; reserved: number; incoming: number }[] | null) ?? []) {
    resvByKey.set(`${r.product_id}:${r.warehouse_id}`, { reserved: Number(r.reserved), incoming: Number(r.incoming) });
  }

  return (
    <div>
      <PageHeader
        title="المخزون"
        action={
          <Link href="/dashboard/inventory/stocktake" className="rounded-xl border border-borderSoft bg-white px-4 py-2.5 text-sm font-medium text-charcoal hover:border-sage">
            جرد المخزن
          </Link>
        }
      />

      {canAdjust && <StockAdjustmentForm products={products ?? []} warehouses={warehouses ?? []} />}
      {canAdjust && (warehouses?.length ?? 0) > 1 && <StockTransferForm products={products ?? []} warehouses={warehouses ?? []} />}

      {viewCost && (
        <Card className="mb-6 p-4 sm:mb-7 sm:p-6">
          <div className="min-w-0">
            <p className="text-xs leading-6 text-charcoal/45">قيمة المخزون الحالية (بمتوسط التكلفة المرجح)</p>
            <StatValue className="mt-2" value={money(totalValue)} unit="ج.م" />
          </div>
        </Card>
      )}

      <DataTable<StockRow>
        rows={rows}
        getRowKey={(r) => r.id}
        emptyLabel="لا يوجد مخزون بعد — سيظهر هنا بعد أول فاتورة شراء"
        columns={[
          { header: "المنتج", render: (r) => r.products?.name ?? "—" },
          { header: "المخزن", render: (r) => r.warehouses?.name ?? "—" },
          { header: "الكمية بالمخزن", render: (r) => <span dir="ltr">{r.quantity} {r.products?.unit ?? ""}</span> },
          { header: "محجوزة لفواتير لم تُصرف", render: (r) => { const v = resvByKey.get(`${r.product_id}:${r.warehouse_id}`)?.reserved ?? 0; return <span dir="ltr" className={v > 0 ? "text-brass" : "text-charcoal/30"}>{v > 0 ? v : "—"}</span>; } },
          { header: "المتاحة للبيع", render: (r) => { const v = resvByKey.get(`${r.product_id}:${r.warehouse_id}`)?.reserved ?? 0; return <span dir="ltr">{r.quantity - v}</span>; } },
          { header: "في الطريق (لم تُستلم)", render: (r) => { const v = resvByKey.get(`${r.product_id}:${r.warehouse_id}`)?.incoming ?? 0; return <span dir="ltr" className={v > 0 ? "text-sage" : "text-charcoal/30"}>{v > 0 ? v : "—"}</span>; } },
          ...(viewCost
            ? [
                { header: "متوسط التكلفة", render: (r: StockRow) => <span dir="ltr"><Money value={r.avg_cost} /></span> },
                { header: "القيمة", render: (r: StockRow) => <span dir="ltr"><Money value={r.quantity * r.avg_cost} /></span> },
              ]
            : []),
        ]}
      />
      <Pagination page={page} pageSize={PAGE_SIZE} totalCount={count ?? 0} />
    </div>
  );
}
