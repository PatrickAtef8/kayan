import { Money } from "@/components/ui/money";
import { getReportContext } from "@/lib/report-context";
import { isRestrictedRep } from "@/lib/org-context";
import { Card } from "@/components/ui/card";
import { DataTable } from "@/components/ui/data-table";
import { ExportButtons } from "@/components/ui/export-buttons";
import { SalesReportFilters } from "@/components/reports/sales-report-filters";
import { cartonsText, loadFilterOptions, loadSalesRows, money, parseFilters, productCartons, qty, type SalesRow, type SalesSearchParams } from "@/lib/sales-report";
import { rangeText } from "@/lib/export/model";

export default async function SalesByProductPage(props: { searchParams: Promise<SalesSearchParams> }) {
  const sp = await props.searchParams;
  const f = parseFilters(sp);
  const { supabase, orgId, canExport } = await getReportContext();
  if (!orgId) return null;

  const restricted = await isRestrictedRep();
  const [options, rows] = await Promise.all([loadFilterOptions(supabase, orgId), loadSalesRows(supabase, orgId, "product", f)]);
  const total = rows.reduce(
    (a, r) => ({ revenue: a.revenue + r.net_revenue, units: a.units + r.net_qty, cartons: a.cartons + r.cartons }),
    { revenue: 0, units: 0, cartons: 0 },
  );
  const truncated = (rows[0]?.total_count ?? 0) > rows.length;

  return (
    <div>
      <SalesReportFilters from={f.from} to={f.to} all={sp.all === "1" && !sp.from && !sp.to} warehouse={f.warehouse} rep={f.rep} channel={f.channel} warehouses={options.warehouses} reps={options.reps} showRep={!restricted} />

      <div className="mb-3 flex items-center justify-between">
        {canExport ? (
          <ExportButtons
            title="مبيعات حسب الصنف"
            subtitle={rangeText(f.from, f.to)}
            kinds={["text", "qty", "qty", "qty", "qty", "int", "int", "int", "money:sum"]}
            filename={`مبيعات-الأصناف-${f.from ?? "الكل"}-${f.to ?? "الآن"}`}
            headers={["الصنف", "المفوتر", "بونص", "مرتجع", "الصافي (قطع)", "عدد الوحدات بالكرتونة", "كراتين كاملة", "قطع زائدة", "صافي الإيراد"]}
            rows={rows.map((r) => [r.group_label, r.billed_qty, r.bonus_qty, r.returned_qty, r.net_qty, r.units_per_carton ?? "", r.whole_cartons ?? "", r.remainder_units ?? "", r.net_revenue])}
          />
        ) : (
          <span />
        )}
      </div>

      <div className="mb-6 grid grid-cols-2 gap-3 lg:grid-cols-3">
        <Card className="p-4"><p className="text-[0.6875rem] text-charcoal/45">صافي الإيراد</p><p className="mt-1.5 text-xl font-semibold text-charcoal" dir="ltr"><Money value={total.revenue} /></p></Card>
        <Card className="p-4"><p className="text-[0.6875rem] text-charcoal/45">القطع المباعة (صافي)</p><p className="mt-1.5 text-xl font-semibold text-charcoal" dir="ltr">{qty(total.units)}</p></Card>
        <Card className="p-4"><p className="text-[0.6875rem] text-charcoal/45">الكراتين</p><p className="mt-1.5 text-xl font-semibold text-charcoal" dir="ltr">{cartonsText(total.cartons)}</p></Card>
      </div>

      <DataTable<SalesRow>
        rows={rows}
        getRowKey={(r) => r.group_id}
        emptyLabel="لا توجد مبيعات في هذه الفترة"
        columns={[
          { header: "الصنف", render: (r) => r.group_label },
          { header: "المفوتر", render: (r) => <span dir="ltr">{qty(r.billed_qty)}</span> },
          { header: "بونص", render: (r) => <span dir="ltr">{r.bonus_qty > 0 ? qty(r.bonus_qty) : "—"}</span> },
          { header: "مرتجع", render: (r) => <span dir="ltr" className={r.returned_qty > 0 ? "text-rose" : ""}>{r.returned_qty > 0 ? qty(r.returned_qty) : "—"}</span> },
          { header: "الصافي (قطع)", render: (r) => <span dir="ltr" className="font-medium">{qty(r.net_qty)}</span> },
          { header: "بالكرتونة", render: (r) => <span dir="ltr">{productCartons(r)}</span> },
          { header: "صافي الإيراد", render: (r) => <span dir="ltr" className="font-medium"><Money value={r.net_revenue} /></span> },
        ]}
      />
      {truncated && <p className="mt-3 text-xs text-amber-700">يعرض أعلى {rows.length} صنفًا من {rows[0]?.total_count} — ضيّق الفترة أو أضف فلترًا.</p>}
      <p className="mt-4 text-xs text-charcoal/40">
        الصافي = المفوتر + البونص − المرتجع (بما فيه التالف). الكراتين من عدد الوحدات/كرتونة المسجل لكل صنف على حدة؛ «—» تعني أن الصنف بلا كرتونة محددة. الإيراد بعد خصم البنود والفاتورة والمرتجع، قبل الضريبة. الفترة بتاريخ الفاتورة والمرتجع يُخصم من فاتورته الأصلية.
      </p>
    </div>
  );
}
