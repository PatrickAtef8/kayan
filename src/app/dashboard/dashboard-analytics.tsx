import type { PeriodSel } from "@/lib/report-period";
import { SalesTrendChart, type TrendPoint } from "./sales-trend-chart";

export type { TrendPoint };

export type BreakdownRow = {
  group_key: string;
  group_label: string;
  ref_date: string | null;
  invoices: number;
  net_sales: number;
  gross_profit: number | null;
};

export type DashboardAnalyticsData = {
  trend: TrendPoint[];
  products: BreakdownRow[];
  customers: BreakdownRow[];
  representatives: BreakdownRow[];
};

function money(n: number) {
  return n.toLocaleString("ar-EG", { maximumFractionDigits: 0 });
}

// §42: sales/profit chart, top products, top customers, rep performance.
// No charting dependency on purpose: the trend is a small HTML/SVG chart (sales-trend-chart.tsx) fed by
// dashboard_sales_trend (0055), and the three ranking cards are plain CSS bars.
export function DashboardAnalytics({ data, period, canViewFinancial }: { data: DashboardAnalyticsData; period: PeriodSel; canViewFinancial: boolean }) {
  if (data.trend.length === 0 && data.products.length === 0) return null;

  return (
    <div className="mt-10 space-y-6 border-t border-borderSoft pt-8">
      <div>
        <p className="text-xs font-medium text-charcoal/40">أداء المبيعات · {period.title}</p>
        <h2 className="mt-1 text-xl font-semibold text-charcoal">{period.kind === "month" ? "المبيعات والأرباح اليومية" : "المبيعات والأرباح الشهرية"}</h2>
      </div>

      <div className="rounded-2xl border border-borderSoft bg-white p-5">
        <SalesTrendChart points={data.trend} bucket={period.kind === "month" ? "day" : "month"} canViewFinancial={canViewFinancial} />
      </div>

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <RankCard title="أعلى المنتجات مبيعًا" rows={data.products} canViewFinancial={canViewFinancial} />
        <RankCard title="أعلى العملاء شراءً" rows={data.customers} canViewFinancial={canViewFinancial} />
        <RankCard title="أداء المندوبين" rows={data.representatives} canViewFinancial={canViewFinancial} />
      </div>
    </div>
  );
}

function RankCard({ title, rows, canViewFinancial }: { title: string; rows: BreakdownRow[]; canViewFinancial: boolean }) {
  const max = Math.max(1, ...rows.map((r) => Number(r.net_sales)));
  return (
    <div className="rounded-2xl border border-borderSoft bg-white p-5">
      <p className="mb-4 text-sm font-medium text-charcoal">{title}</p>
      {rows.length === 0 ? (
        <p className="py-6 text-center text-xs text-charcoal/35">لا توجد بيانات</p>
      ) : (
        <div className="space-y-3">
          {rows.map((r) => (
            <div key={r.group_key + r.group_label}>
              <div className="mb-1 flex items-center justify-between gap-2 text-xs">
                <span className="truncate text-charcoal">{r.group_label}</span>
                <span className="shrink-0 text-charcoal/55" dir="ltr">
                  {money(Number(r.net_sales))} ج.م
                </span>
              </div>
              <div className="h-1.5 overflow-hidden rounded-full bg-paper">
                <div className="h-full rounded-full bg-sage" style={{ width: `${Math.max(3, (Number(r.net_sales) / max) * 100)}%` }} />
              </div>
              {canViewFinancial && r.gross_profit != null && (
                <p className="mt-1 text-[0.6875rem] text-charcoal/40" dir="ltr">
                  ربح {money(Number(r.gross_profit))} ج.م · {r.invoices} فاتورة
                </p>
              )}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
