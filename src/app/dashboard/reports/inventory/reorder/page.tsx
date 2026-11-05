import { getReportContext } from "@/lib/report-context";
import { Card } from "@/components/ui/card";
import { DataTable } from "@/components/ui/data-table";
import { ExportButtons } from "@/components/ui/export-buttons";
import { ParamSelect } from "@/components/reports/param-select";
import { cairoDate } from "@/lib/report-period";

type ReorderRow = {
  product_id: string;
  product_name: string;
  sku: string | null;
  barcode: string | null;
  unit: string;
  category_name: string | null;
  current_qty: number;
  reorder_level: number;
  shortage: number;
  status: "out" | "low";
};

const num = (n: number) => Number(n).toLocaleString("ar-EG", { maximumFractionDigits: 3 });

export default async function ReorderReportPage(props: { searchParams: Promise<{ warehouse?: string }> }) {
  const searchParams = await props.searchParams;
  const { supabase, orgId, canExport } = await getReportContext();
  if (!orgId) return null;

  const warehouse = searchParams.warehouse || null;

  const [{ data }, { data: warehouses }, { count: noLevelCount }] = await Promise.all([
    supabase.rpc("report_reorder", { org_id: orgId, p_warehouse: warehouse }),
    supabase.from("warehouses").select("id, name").eq("organization_id", orgId).eq("is_active", true).order("name"),
    supabase
      .from("products")
      .select("id", { count: "exact", head: true })
      .eq("organization_id", orgId)
      .eq("is_active", true)
      .eq("track_inventory", true)
      .eq("reorder_level", 0),
  ]);

  const rows = (data as ReorderRow[]) ?? [];
  const outCount = rows.filter((r) => r.status === "out").length;
  const lowCount = rows.length - outCount;
  // the report is a "today" report — stamp it with the business's local day
  const today = new Date().toLocaleDateString("ar-EG", { timeZone: "Africa/Cairo", weekday: "long", year: "numeric", month: "long", day: "numeric" });
  const warehouseName = (warehouses ?? []).find((w) => w.id === warehouse)?.name;

  return (
    <div>
      <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
        {canExport ? (
          <ExportButtons
            title="نواقص المخزون"
            subtitle={`بتاريخ ${cairoDate()}`}
            kinds={["text", "code", "code", "text", "qty", "qty", "qty", "text"]}
            filename={`نواقص-المخزون-${cairoDate()}`}
            headers={["المنتج", "الكود", "الباركود", "التصنيف", "الرصيد", "حد الطلب", "العجز عن الحد", "الحالة"]}
            rows={rows.map((r) => [r.product_name, r.sku ?? "", r.barcode ?? "", r.category_name ?? "", r.current_qty, r.reorder_level, r.shortage, r.status === "out" ? "نفد" : "أقل من الحد"])}
          />
        ) : (
          <span />
        )}
        <ParamSelect
          param="warehouse"
          value={warehouse ?? ""}
          placeholder="كل المخازن"
          clearLabel="كل المخازن"
          options={(warehouses ?? []).map((w) => ({ value: w.id, label: w.name }))}
        />
      </div>

      <div className="mb-2 text-xs text-charcoal/45">
        تقرير النواقص اليومي — {today}
        {warehouseName ? ` — مخزن: ${warehouseName}` : ""}
      </div>

      <div className="mb-7 grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Card className="p-4">
          <p className="text-[0.6875rem] text-charcoal/45">أصناف تحت الحد</p>
          <p className="mt-1.5 text-xl font-semibold text-charcoal" dir="ltr">{rows.length}</p>
        </Card>
        <Card className="p-4">
          <p className="text-[0.6875rem] text-charcoal/45">نفدت تمامًا</p>
          <p className="mt-1.5 text-xl font-semibold text-rose" dir="ltr">{outCount}</p>
        </Card>
        <Card className="p-4">
          <p className="text-[0.6875rem] text-charcoal/45">أقل من الحد</p>
          <p className="mt-1.5 text-xl font-semibold text-charcoal" dir="ltr">{lowCount}</p>
        </Card>
      </div>

      <DataTable<ReorderRow>
        rows={rows}
        getRowKey={(r) => r.product_id}
        emptyLabel="لا توجد نواقص — كل الأصناف التي لها حد طلب فوق حدها 🎉"
        columns={[
          { header: "المنتج", render: (r) => r.product_name },
          { header: "الكود", render: (r) => <span dir="ltr">{r.sku ?? "—"}</span> },
          { header: "الباركود", render: (r) => <span dir="ltr">{r.barcode ?? "—"}</span> },
          { header: "الرصيد", render: (r) => <span dir="ltr">{num(r.current_qty)} {r.unit}</span> },
          { header: "حد الطلب", render: (r) => <span dir="ltr">{num(r.reorder_level)}</span> },
          { header: "العجز عن الحد", render: (r) => <span dir="ltr" className="text-rose">{num(r.shortage)}</span> },
          {
            header: "الحالة",
            render: (r) =>
              r.status === "out" ? (
                <span className="rounded-md bg-rose/10 px-2 py-0.5 text-xs font-medium text-rose">نفد</span>
              ) : (
                <span className="rounded-md bg-paper px-2 py-0.5 text-xs font-medium text-charcoal/60">أقل من الحد</span>
              ),
          },
        ]}
      />

      {(noLevelCount ?? 0) > 0 && (
        <p className="mt-4 text-xs text-charcoal/40">
          {noLevelCount} صنف نشط ليس له حد طلب، فلن يظهر هنا أبدًا. حدّد الحد من صفحة المنتجات (تعديل المنتج ← حد الطلب).
        </p>
      )}
    </div>
  );
}
