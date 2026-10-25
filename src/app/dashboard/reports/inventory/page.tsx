import { Money } from "@/components/ui/money";
import { formatMoney } from "@/lib/money";
import { getReportContext } from "@/lib/report-context";
import { Card } from "@/components/ui/card";
import { DataTable } from "@/components/ui/data-table";
import { ExportButtons } from "@/components/ui/export-buttons";

function money(n: number | null) {
  if (n === null || n === undefined) return "—";
  return formatMoney(n);
}

type StockRow = {
  product_id: string;
  product_name: string;
  sku: string | null;
  unit: string;
  warehouse_id: string;
  warehouse_name: string;
  quantity: number;
  avg_cost: number | null;
  stock_value: number | null;
};

type MovementRow = {
  id: string;
  moved_at: string;
  product_name: string;
  warehouse_name: string;
  movement_type: string;
  quantity_delta: number;
  unit_cost: number | null;
  reference_type: string | null;
  note: string | null;
};

const MOVEMENT_LABEL: Record<string, string> = {
  purchase: "شراء",
  purchase_return: "مرتجع شراء",
  sale: "بيع",
  sale_return: "مرتجع بيع",
  adjustment: "تسوية",
  transfer_out: "نقل صادر",
  transfer_in: "نقل وارد",
};

export default async function InventoryReportPage() {
  const { supabase, orgId, canViewFinancial, canExport } = await getReportContext();
  if (!orgId) return null;

  const [{ data: stock }, { data: movements }] = await Promise.all([
    supabase.rpc("report_inventory_stock", { org_id: orgId }),
    supabase.rpc("report_stock_movements", { org_id: orgId, p_limit: 50, p_offset: 0 }),
  ]);

  const stockRows = (stock as StockRow[]) ?? [];
  const movementRows = (movements as MovementRow[]) ?? [];
  const totalValue = stockRows.reduce((sum, r) => sum + (r.stock_value ?? 0), 0);

  return (
    <div>
      {canViewFinancial && (
        <Card className="mb-7 flex items-center justify-between p-5 sm:p-6">
          <div>
            <p className="text-xs text-charcoal/45">قيمة المخزون الحالية (بمتوسط التكلفة المرجح)</p>
            <p className="mt-2 text-3xl font-semibold tracking-tight text-charcoal" dir="ltr">
              <Money value={totalValue} />
            </p>
          </div>
        </Card>
      )}

      <div className="mb-4 flex items-center justify-between">
        <span className="text-xs font-medium text-charcoal/40">أرصدة المخزون حسب المخزن</span>
        {canExport && (
          <ExportButtons
            filename="أرصدة-المخزون"
            headers={["المنتج", "المخزن", "الكمية", ...(canViewFinancial ? ["متوسط التكلفة", "القيمة"] : [])]}
            rows={stockRows.map((r) => [r.product_name, r.warehouse_name, r.quantity, ...(canViewFinancial ? [r.avg_cost ?? "", r.stock_value ?? ""] : [])])}
          />
        )}
      </div>
      <DataTable<StockRow>
        rows={stockRows}
        getRowKey={(r) => `${r.product_id}-${r.warehouse_id}`}
        emptyLabel="لا يوجد مخزون بعد"
        columns={[
          { header: "المنتج", render: (r) => r.product_name },
          { header: "المخزن", render: (r) => r.warehouse_name },
          { header: "الكمية", render: (r) => <span dir="ltr">{r.quantity} {r.unit}</span> },
          ...(canViewFinancial
            ? [
                { header: "متوسط التكلفة", render: (r: StockRow) => <span dir="ltr"><Money value={r.avg_cost} /></span> },
                { header: "القيمة", render: (r: StockRow) => <span dir="ltr"><Money value={r.stock_value} /></span> },
              ]
            : []),
        ]}
      />

      <div className="mb-4 mt-9 text-xs font-medium text-charcoal/40">آخر حركات المخزون</div>
      <DataTable<MovementRow>
        rows={movementRows}
        getRowKey={(r) => r.id}
        emptyLabel="لا توجد حركات بعد"
        columns={[
          { header: "التاريخ", render: (r) => <span dir="ltr">{new Date(r.moved_at).toLocaleString("ar-EG")}</span> },
          { header: "المنتج", render: (r) => r.product_name },
          { header: "المخزن", render: (r) => r.warehouse_name },
          { header: "النوع", render: (r) => MOVEMENT_LABEL[r.movement_type] ?? r.movement_type },
          {
            header: "الكمية",
            render: (r) => (
              <span dir="ltr" className={r.quantity_delta >= 0 ? "text-sage" : "text-rose"}>
                {r.quantity_delta > 0 ? "+" : ""}
                {r.quantity_delta}
              </span>
            ),
          },
          ...(canViewFinancial ? [{ header: "تكلفة الوحدة", render: (r: MovementRow) => <Money value={r.unit_cost} suffix="" /> }] : []),
          { header: "ملاحظة", render: (r) => r.note ?? "—" },
        ]}
      />
    </div>
  );
}
