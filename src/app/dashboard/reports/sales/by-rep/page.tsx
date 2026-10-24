import Link from "next/link";
import { getReportContext } from "@/lib/report-context";
import { isRestrictedRep } from "@/lib/org-context";
import { Card } from "@/components/ui/card";
import { DataTable } from "@/components/ui/data-table";
import { ExportButtons } from "@/components/ui/export-buttons";
import { SalesReportFilters } from "@/components/reports/sales-report-filters";
import { cartonsText, loadFilterOptions, loadSalesRows, money, parseFilters, productCartons, qty, withParams, type SalesRow, type SalesSearchParams } from "@/lib/sales-report";

export default async function SalesByRepPage(props: { searchParams: Promise<SalesSearchParams> }) {
  const sp = await props.searchParams;
  const f = parseFilters(sp);
  const { supabase, orgId, canExport } = await getReportContext();
  if (!orgId) return null;

  const restricted = await isRestrictedRep();
  const [options, rows] = await Promise.all([loadFilterOptions(supabase, orgId), loadSalesRows(supabase, orgId, "rep", f)]);
  // one rep selected → also show what that rep sold, by product and by customer
  const [byProduct, byCustomer] = f.rep
    ? await Promise.all([loadSalesRows(supabase, orgId, "product", f), loadSalesRows(supabase, orgId, "customer", f)])
    : [[], []];

  const total = rows.reduce(
    (a, r) => ({ revenue: a.revenue + r.net_revenue, units: a.units + r.net_qty, cartons: a.cartons + r.cartons, loose: a.loose + r.loose_units, invoices: a.invoices + r.invoices }),
    { revenue: 0, units: 0, cartons: 0, loose: 0, invoices: 0 },
  );
  const repName = options.reps.find((r) => r.id === f.rep)?.name;

  return (
    <div>
      <SalesReportFilters from={f.from} to={f.to} all={sp.all === "1" && !sp.from && !sp.to} warehouse={f.warehouse} rep={f.rep} channel={f.channel} warehouses={options.warehouses} reps={options.reps} showRep={!restricted} />

      <div className="mb-3 flex items-center justify-between">
        {canExport ? (
          <ExportButtons
            filename={`مبيعات-المناديب-${f.from ?? "الكل"}-${f.to ?? "الآن"}`}
            headers={["المندوب", "الفواتير", "العملاء", "عدد الأصناف", "الكراتين", "القطع", "قطع بدون كرتونة", "صافي الإيراد"]}
            rows={rows.map((r) => [r.group_label, r.invoices, r.customers, r.products, r.cartons, r.net_qty, r.loose_units, r.net_revenue])}
          />
        ) : (
          <span />
        )}
        {f.rep && <Link href={withParams(sp, { rep: "" })} scroll={false} className="text-xs text-sage hover:underline">عرض كل المناديب</Link>}
      </div>

      <div className="mb-6 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="صافي الإيراد" value={`${money(total.revenue)} ج.م`} />
        <Stat label="الكراتين" value={cartonsText(total.cartons)} />
        <Stat label="القطع المباعة" value={qty(total.units)} />
        <Stat label="الفواتير" value={String(total.invoices)} />
      </div>

      <DataTable<SalesRow>
        rows={rows}
        getRowKey={(r) => r.group_id}
        emptyLabel="لا توجد مبيعات في هذه الفترة"
        columns={[
          { header: "المندوب", render: (r) => r.group_label },
          { header: "الفواتير", render: (r) => <span dir="ltr">{r.invoices}</span> },
          { header: "العملاء", render: (r) => <span dir="ltr">{r.customers}</span> },
          { header: "عدد الأصناف", render: (r) => <span dir="ltr">{r.products}</span> },
          { header: "الكراتين", render: (r) => <span dir="ltr">{cartonsText(r.cartons)}</span> },
          { header: "القطع المباعة", render: (r) => <span dir="ltr">{qty(r.net_qty)}</span> },
          { header: "صافي الإيراد", render: (r) => <span dir="ltr" className="font-medium">{money(r.net_revenue)} ج.م</span> },
          { header: "", render: (r) => (r.group_id !== "none" ? <Link href={withParams(sp, { rep: r.group_id })} scroll={false} className="text-xs text-sage hover:underline">تفصيل</Link> : null) },
        ]}
      />
      <Notes loose={total.loose} />

      {f.rep && (
        <div className="mt-10 space-y-8">
          <div>
            <p className="mb-3 text-sm font-medium text-charcoal">مبيعات {repName ?? "المندوب"} بالأصناف</p>
            <DataTable<SalesRow>
              rows={byProduct}
              getRowKey={(r) => r.group_id}
              emptyLabel="لا توجد مبيعات"
              columns={[
                { header: "الصنف", render: (r) => r.group_label },
                { header: "القطع", render: (r) => <span dir="ltr">{qty(r.net_qty)}</span> },
                { header: "الكراتين", render: (r) => <span dir="ltr">{productCartons(r)}</span> },
                { header: "صافي الإيراد", render: (r) => <span dir="ltr">{money(r.net_revenue)} ج.م</span> },
              ]}
            />
          </div>
          <div>
            <p className="mb-3 text-sm font-medium text-charcoal">مبيعات {repName ?? "المندوب"} بالعملاء</p>
            <DataTable<SalesRow>
              rows={byCustomer}
              getRowKey={(r) => r.group_id}
              emptyLabel="لا توجد مبيعات"
              columns={[
                { header: "العميل", render: (r) => r.group_label },
                { header: "الفواتير", render: (r) => <span dir="ltr">{r.invoices}</span> },
                { header: "القطع", render: (r) => <span dir="ltr">{qty(r.net_qty)}</span> },
                { header: "صافي الإيراد", render: (r) => <span dir="ltr">{money(r.net_revenue)} ج.م</span> },
              ]}
            />
          </div>
        </div>
      )}
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <Card className="p-4">
      <p className="text-[0.6875rem] text-charcoal/45">{label}</p>
      <p className="mt-1.5 text-xl font-semibold text-charcoal" dir="ltr">{value}</p>
    </Card>
  );
}

function Notes({ loose }: { loose: number }) {
  return (
    <p className="mt-4 text-xs text-charcoal/40">
      الفترة بتاريخ الفاتورة، والمرتجع يُخصم من فاتورته الأصلية. الكراتين تُحسب فقط للأصناف التي لها عدد وحدات/كرتونة محدد في بياناتها
      {loose > 0 ? ` — ${qty(loose)} قطعة من أصناف بلا كرتونة محسوبة ضمن «القطع المباعة» فقط` : ""}. القطع = المفوتر + البونص − المرتجع.
    </p>
  );
}
