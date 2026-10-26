import { Money } from "@/components/ui/money";
import { getReportContext } from "@/lib/report-context";
import { isRestrictedRep } from "@/lib/org-context";
import { Card } from "@/components/ui/card";
import { DataTable } from "@/components/ui/data-table";
import { ExportButtons } from "@/components/ui/export-buttons";
import { SalesReportFilters } from "@/components/reports/sales-report-filters";
import { cartonsText, loadFilterOptions, loadSalesRows, money, parseFilters, qty, type SalesRow, type SalesSearchParams } from "@/lib/sales-report";
import { rangeText } from "@/lib/export/model";

export default async function SalesByChannelPage(props: { searchParams: Promise<SalesSearchParams> }) {
  const sp = await props.searchParams;
  const f = { ...parseFilters(sp), channel: null }; // the channel IS the grouping here
  const { supabase, orgId, canExport } = await getReportContext();
  if (!orgId) return null;

  const restricted = await isRestrictedRep();
  const [options, rows] = await Promise.all([loadFilterOptions(supabase, orgId), loadSalesRows(supabase, orgId, "channel", f)]);
  const totalRevenue = rows.reduce((a, r) => a + r.net_revenue, 0);
  const totalLoose = rows.reduce((a, r) => a + r.loose_units, 0);
  const share = (r: SalesRow) => (totalRevenue > 0 ? (r.net_revenue / totalRevenue) * 100 : 0);

  return (
    <div>
      <SalesReportFilters from={f.from} to={f.to} all={sp.all === "1" && !sp.from && !sp.to} warehouse={f.warehouse} rep={f.rep} channel={null} warehouses={options.warehouses} reps={options.reps} showRep={!restricted} showChannel={false} />

      <div className="mb-3 flex items-center justify-between">
        {canExport ? (
          <ExportButtons
            title="مبيعات حسب القناة"
            subtitle={rangeText(f.from, f.to)}
            kinds={["text", "int:sum", "int", "qty:sum", "qty:sum", "money:sum", "percent"]}
            filename={`مبيعات-القنوات-${f.from ?? "الكل"}-${f.to ?? "الآن"}`}
            headers={["القناة", "الفواتير", "العملاء", "الكراتين", "القطع", "صافي الإيراد", "النسبة من الإجمالي %"]}
            rows={rows.map((r) => [r.group_label, r.invoices, r.customers, r.cartons, r.net_qty, r.net_revenue, Number(share(r).toFixed(1))])}
          />
        ) : (
          <span />
        )}
      </div>

      <div className="mb-6 grid grid-cols-1 gap-3 sm:grid-cols-3">
        {rows.map((r) => (
          <Card key={r.group_id} className="p-4">
            <p className="text-[0.6875rem] text-charcoal/45">{r.group_label}</p>
            <p className="mt-1.5 text-xl font-semibold text-charcoal" dir="ltr"><Money value={r.net_revenue} /></p>
            <p className="mt-1 text-[0.6875rem] text-charcoal/40">{share(r).toLocaleString("ar-EG", { maximumFractionDigits: 1 })}٪ من الإجمالي</p>
          </Card>
        ))}
      </div>

      <DataTable<SalesRow>
        rows={rows}
        getRowKey={(r) => r.group_id}
        emptyLabel="لا توجد مبيعات"
        columns={[
          { header: "القناة", render: (r) => r.group_label },
          { header: "الفواتير", render: (r) => <span dir="ltr">{r.invoices}</span> },
          { header: "العملاء", render: (r) => <span dir="ltr">{r.customers}</span> },
          { header: "الكراتين", render: (r) => <span dir="ltr">{cartonsText(r.cartons)}</span> },
          { header: "القطع المباعة", render: (r) => <span dir="ltr">{qty(r.net_qty)}</span> },
          { header: "صافي الإيراد", render: (r) => <span dir="ltr" className="font-medium"><Money value={r.net_revenue} /></span> },
          { header: "النسبة", render: (r) => <span dir="ltr">{share(r).toLocaleString("ar-EG", { maximumFractionDigits: 1 })}٪</span> },
        ]}
      />
      <p className="mt-4 text-xs text-charcoal/40">
        قناة البيع تُحدَّد في فاتورة البيع (جملة / تجزئة / سوشيال ميديا)، وإن لم تُحدَّد فتُؤخذ من نوع تسعير العميل. الفواتير القديمة قبل إضافة القناة تُنسب حسب نوع العميل الحالي، ولا تظهر ضمن «سوشيال ميديا».
        الفترة بتاريخ الفاتورة والمرتجع يُخصم من فاتورته الأصلية.
        {totalLoose > 0 ? ` ${qty(totalLoose)} قطعة من أصناف بلا كرتونة محسوبة ضمن القطع فقط.` : ""}
      </p>
    </div>
  );
}
