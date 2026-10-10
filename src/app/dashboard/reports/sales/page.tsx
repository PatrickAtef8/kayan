import { getReportContext } from "@/lib/report-context";
import { Card } from "@/components/ui/card";
import { DataTable } from "@/components/ui/data-table";
import { PeriodSelect } from "@/components/reports/period-select";
import { ExportButtons } from "@/components/ui/export-buttons";
import { periodRange, type ReportPeriod } from "@/lib/report-period";

function money(n: number | null) {
  if (n === null || n === undefined) return "—";
  return n.toLocaleString("ar-EG", { minimumFractionDigits: 2 });
}

type BreakdownRow = {
  group_key: string;
  group_label: string;
  ref_date: string | null;
  party: string | null;
  invoices: number;
  quantity: number;
  gross_sales: number;
  discounts: number;
  net_sales: number;
  cogs: number | null;
  gross_profit: number | null;
  commission: number | null;
  total_count: number;
};

const GROUP_OPTIONS = [
  { value: "date", label: "حسب التاريخ" },
  { value: "invoice", label: "حسب الفاتورة" },
  { value: "customer", label: "حسب العميل" },
  { value: "product", label: "حسب المنتج" },
  { value: "representative", label: "حسب المندوب" },
];

export default async function SalesReportPage(props: { searchParams: Promise<{ period?: string; group?: string }> }) {
  const searchParams = await props.searchParams;
  const period = (searchParams.period === "year" || searchParams.period === "all" ? searchParams.period : "month") as ReportPeriod;
  const group = ["date", "invoice", "customer", "product", "representative"].includes(searchParams.group ?? "") ? (searchParams.group as string) : "date";
  const { from, to } = periodRange(period);

  const { supabase, orgId, canViewFinancial, canExport } = await getReportContext();
  if (!orgId) return null;

  const [{ data: summary }, { data: rows }] = await Promise.all([
    supabase.rpc("report_summary", { org_id: orgId, p_from: from, p_to: to }),
    supabase.rpc("report_sales_breakdown", { org_id: orgId, p_from: from, p_to: to, p_group: group, p_limit: 100, p_offset: 0 }),
  ]);

  const s = summary as { sales: Record<string, number>; financial: Record<string, unknown> | null } | null;
  const breakdown = (rows as BreakdownRow[]) ?? [];

  const groupHeader = { date: "التاريخ", invoice: "الفاتورة", customer: "العميل", product: "المنتج", representative: "المندوب" }[group as string] ?? "البند";

  return (
    <div>
      <div className="mb-6 flex items-center justify-between">
        {canExport ? (
          <ExportButtons
            filename={`مبيعات-${group}-${from ?? "الكل"}-${to ?? "الآن"}`}
            headers={[groupHeader, "عدد الفواتير", "الكمية", "صافي المبيعات", ...(canViewFinancial ? ["الربح"] : [])]}
            rows={breakdown.map((r) => [r.group_label, r.invoices, r.quantity, r.net_sales, ...(canViewFinancial ? [r.gross_profit ?? ""] : [])])}
          />
        ) : (
          <span />
        )}
        <PeriodSelect period={period} />
      </div>

      <div className="mb-7 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4">
        <SummaryCard label="إجمالي المبيعات" value={money(s?.sales?.gross_sales ?? null)} />
        <SummaryCard label="الخصومات" value={money(s?.sales?.discounts ?? null)} />
        <SummaryCard label="صافي المبيعات" value={money(s?.sales?.net_sales ?? null)} />
        {canViewFinancial && (
          <>
            <SummaryCard label="تكلفة البضاعة المباعة" value={money((s?.financial?.cogs as number) ?? null)} />
            <SummaryCard label="إجمالي الربح" value={money((s?.financial?.gross_profit as number) ?? null)} highlight />
            <SummaryCard label="المصروفات التشغيلية" value={money((s?.financial?.operating_expenses as number) ?? null)} />
            <SummaryCard label="العمولات" value={money((s?.financial?.commissions as number) ?? null)} />
            <SummaryCard label="صافي الربح" value={money((s?.financial?.net_profit as number) ?? null)} highlight />
          </>
        )}
      </div>

      <GroupSwitcher group={group} period={period} />

      <DataTable<BreakdownRow>
        rows={breakdown}
        getRowKey={(r) => r.group_key}
        emptyLabel="لا توجد بيانات لهذه الفترة"
        columns={[
          { header: groupHeader, render: (r) => r.group_label },
          ...(group === "invoice" ? [{ header: "العميل", render: (r: BreakdownRow) => r.party ?? "—" }] : []),
          { header: "عدد الفواتير", render: (r) => <span dir="ltr">{r.invoices}</span> },
          { header: "الكمية", render: (r) => <span dir="ltr">{r.quantity}</span> },
          { header: "صافي المبيعات", render: (r) => <span dir="ltr">{money(r.net_sales)} ج.م</span> },
          ...(canViewFinancial
            ? [
                {
                  header: "الربح",
                  render: (r: BreakdownRow) => (
                    <span dir="ltr" className={(r.gross_profit ?? 0) >= 0 ? "text-sage" : "text-rose"}>
                      {money(r.gross_profit)} ج.م
                    </span>
                  ),
                },
                {
                  header: "الهامش",
                  render: (r: BreakdownRow) => (r.net_sales > 0 && r.gross_profit !== null ? <span dir="ltr">{((r.gross_profit / r.net_sales) * 100).toFixed(1)}%</span> : "—"),
                },
              ]
            : []),
        ]}
      />
    </div>
  );
}

function SummaryCard({ label, value, highlight }: { label: string; value: string; highlight?: boolean }) {
  return (
    <Card className="p-4">
      <p className="text-[0.6875rem] text-charcoal/45">{label}</p>
      <p className={`mt-1.5 text-xl font-semibold tracking-tight ${highlight ? "text-sage" : "text-charcoal"}`} dir="ltr">
        {value} ج.م
      </p>
    </Card>
  );
}

function GroupSwitcher({ group, period }: { group: string; period: string }) {
  return (
    <div className="mb-3 flex flex-wrap gap-1.5">
      {GROUP_OPTIONS.map((g) => (
        <a
          key={g.value}
          href={`?group=${g.value}&period=${period}`}
          className={`rounded-lg px-2.5 py-1.5 text-xs font-medium transition-colors ${g.value === group ? "bg-charcoal text-ivory" : "bg-paper text-charcoal/50 hover:text-charcoal"}`}
        >
          {g.label}
        </a>
      ))}
    </div>
  );
}
