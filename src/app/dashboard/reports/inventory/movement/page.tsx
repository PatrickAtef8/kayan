import { getReportContext } from "@/lib/report-context";
import { Card } from "@/components/ui/card";
import { DataTable } from "@/components/ui/data-table";
import { ExportButtons } from "@/components/ui/export-buttons";
import { PeriodSelect } from "@/components/reports/period-select";
import { ParamSelect } from "@/components/reports/param-select";
import { resolvePeriod } from "@/lib/report-period";

type MovementRow = {
  product_id: string;
  product_name: string;
  sku: string | null;
  barcode: string | null;
  unit: string;
  units_per_carton: number | null;
  opening_qty: number;
  purchased_qty: number;
  sale_returned_qty: number;
  sold_qty: number;
  purchase_returned_qty: number;
  other_net_qty: number;
  closing_qty: number;
  net_sold_qty: number;
  sales_rank: number;
};

const num = (n: number) => Number(n).toLocaleString("ar-EG", { maximumFractionDigits: 3 });
const cartons = (qty: number, per: number | null) => (per && per > 0 ? (qty / per).toLocaleString("ar-EG", { maximumFractionDigits: 2 }) : "—");

export default async function ProductMovementPage(props: { searchParams: Promise<{ period?: string; m?: string; y?: string; warehouse?: string }> }) {
  const searchParams = await props.searchParams;
  const period = resolvePeriod(searchParams); // any month / year / all time
  const { from, to } = period;
  const warehouse = searchParams.warehouse || null;

  const { supabase, orgId, canExport } = await getReportContext();
  if (!orgId) return null;

  const [{ data }, { data: warehouses }] = await Promise.all([
    supabase.rpc("report_product_movement", { org_id: orgId, p_from: from, p_to: to, p_warehouse: warehouse }),
    supabase.from("warehouses").select("id, name").eq("organization_id", orgId).eq("is_active", true).order("name"),
  ]);
  const rows = (data as MovementRow[]) ?? [];

  // already sorted best → worst by the database
  const best = rows.filter((r) => r.net_sold_qty > 0).slice(0, 10);
  const worst = [...rows].reverse().slice(0, 10);

  return (
    <div>
      <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
        {canExport ? (
          <ExportButtons
            filename={`حركة-الأصناف-${from ?? "الكل"}`}
            headers={["المنتج", "الكود", "الباركود", "رصيد أول المدة", "مشتريات", "مرتجع مبيعات", "مبيعات", "مرتجع مشتريات", "تسويات وتحويلات", "المتبقي", "صافي المبيعات", "المبيعات بالكرتونة", "الترتيب"]}
            rows={rows.map((r) => [r.product_name, r.sku ?? "", r.barcode ?? "", r.opening_qty, r.purchased_qty, r.sale_returned_qty, r.sold_qty, r.purchase_returned_qty, r.other_net_qty, r.closing_qty, r.net_sold_qty, cartons(r.net_sold_qty, r.units_per_carton), r.sales_rank])}
          />
        ) : (
          <span />
        )}
        <div className="flex flex-wrap items-center gap-2">
          <ParamSelect
            param="warehouse"
            value={warehouse ?? ""}
            placeholder="كل المخازن"
            clearLabel="كل المخازن"
            options={(warehouses ?? []).map((w) => ({ value: w.id, label: w.name }))}
          />
          <PeriodSelect period={period} />
        </div>
      </div>

      <div className="mb-8 grid grid-cols-1 gap-4 lg:grid-cols-2">
        <RankCard title="الأكثر مبيعًا" rows={best} empty="لا توجد مبيعات في هذه الفترة" tone="text-sage" />
        <RankCard title="الأقل مبيعًا (شاملة الأصناف الراكدة)" rows={worst} empty="لا توجد أصناف" tone="text-charcoal/60" />
      </div>

      <div className="mb-4 text-xs font-medium text-charcoal/40">حركة كل الأصناف خلال الفترة (مرتبة من الأكثر للأقل مبيعًا)</div>
      <DataTable<MovementRow>
        rows={rows}
        getRowKey={(r) => r.product_id}
        emptyLabel="لا توجد أصناف بعد"
        columns={[
          { header: "#", render: (r) => <span dir="ltr">{r.sales_rank}</span> },
          { header: "المنتج", render: (r) => r.product_name },
          { header: "الباركود", render: (r) => <span dir="ltr">{r.barcode ?? "—"}</span> },
          { header: "رصيد أول المدة", render: (r) => <span dir="ltr">{num(r.opening_qty)}</span> },
          { header: "مشتريات", render: (r) => <span dir="ltr">{num(r.purchased_qty)}</span> },
          { header: "مبيعات", render: (r) => <span dir="ltr">{num(r.sold_qty)}</span> },
          { header: "مرتجع مبيعات", render: (r) => <span dir="ltr">{num(r.sale_returned_qty)}</span> },
          { header: "صافي المبيعات", render: (r) => <span dir="ltr" className="font-medium">{num(r.net_sold_qty)} {r.unit}</span> },
          { header: "بالكرتونة", render: (r) => <span dir="ltr">{cartons(r.net_sold_qty, r.units_per_carton)}</span> },
          { header: "المتبقي", render: (r) => <span dir="ltr" className={r.closing_qty <= 0 ? "text-rose" : ""}>{num(r.closing_qty)} {r.unit}</span> },
        ]}
      />
      <p className="mt-4 text-xs text-charcoal/40">
        المبيعات تشمل وحدات البونص لأنها خرجت من المخزن. صافي المبيعات = المبيعات − المرتجع الصالح للبيع. المرتجع التالف لا يعود للمخزن فلا يُخصم هنا.
        المتبقي = رصيد المخزن في نهاية الفترة.
      </p>
    </div>
  );
}

function RankCard({ title, rows, empty, tone }: { title: string; rows: MovementRow[]; empty: string; tone: string }) {
  return (
    <Card className="p-5">
      <p className="mb-3 text-xs font-medium text-charcoal/45">{title}</p>
      {rows.length === 0 ? (
        <p className="py-4 text-sm text-charcoal/40">{empty}</p>
      ) : (
        <ol className="space-y-2">
          {rows.map((r) => (
            <li key={r.product_id} className="flex items-center justify-between gap-3 text-sm">
              <span className="truncate text-charcoal">{r.product_name}</span>
              <span dir="ltr" className={`shrink-0 font-medium ${tone}`}>
                {num(r.net_sold_qty)} {r.unit}
              </span>
            </li>
          ))}
        </ol>
      )}
    </Card>
  );
}
