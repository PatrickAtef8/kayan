import type { Period } from "./page";

export type BreakdownRow = {
  group_key: string;
  group_label: string;
  ref_date: string | null;
  invoices: number;
  net_sales: number;
  gross_profit: number | null;
};

export type DashboardAnalyticsData = {
  trend: BreakdownRow[];
  products: BreakdownRow[];
  customers: BreakdownRow[];
  representatives: BreakdownRow[];
};

function money(n: number) {
  return n.toLocaleString("ar-EG", { maximumFractionDigits: 0 });
}

// §42: sales/profit chart, top products, top customers, rep performance.
// Plain CSS/SVG-free bars on purpose — no charting dependency for what is
// four small read-only visuals.
export function DashboardAnalytics({ data, period, canViewFinancial }: { data: DashboardAnalyticsData; period: Period; canViewFinancial: boolean }) {
  // Daily points for "this month", monthly points for year / all time —
  // a year of daily bars is unreadable.
  const buckets = new Map<string, { sales: number; profit: number }>();
  for (const row of data.trend) {
    if (!row.ref_date) continue;
    const key = period === "month" ? row.ref_date : row.ref_date.slice(0, 7);
    const b = buckets.get(key) ?? { sales: 0, profit: 0 };
    b.sales += Number(row.net_sales);
    b.profit += Number(row.gross_profit ?? 0);
    buckets.set(key, b);
  }
  const points = Array.from(buckets.entries()).sort(([a], [b]) => a.localeCompare(b));
  const max = Math.max(1, ...points.map(([, v]) => Math.max(v.sales, canViewFinancial ? v.profit : 0)));

  if (points.length === 0 && data.products.length === 0) return null;

  return (
    <div className="mt-10 space-y-6 border-t border-borderSoft pt-8">
      <div>
        <p className="text-xs font-medium text-charcoal/40">أداء المبيعات</p>
        <h2 className="mt-1 text-xl font-semibold text-charcoal">{period === "month" ? "المبيعات اليومية" : "المبيعات الشهرية"}</h2>
      </div>

      <div className="rounded-2xl border border-borderSoft bg-white p-5">
        {points.length === 0 ? (
          <p className="py-10 text-center text-sm text-charcoal/40">لا توجد مبيعات في هذه الفترة</p>
        ) : (
          <>
            <div className="flex h-44 items-end gap-1 overflow-x-auto" dir="ltr">
              {points.map(([key, v]) => (
                <div key={key} className="flex min-w-[1.25rem] flex-1 flex-col items-center gap-1" title={`${key} — مبيعات: ${money(v.sales)}${canViewFinancial ? ` — ربح: ${money(v.profit)}` : ""}`}>
                  <div className="flex h-36 w-full items-end justify-center gap-0.5">
                    <div className="w-full max-w-[0.9rem] rounded-t bg-sage" style={{ height: `${Math.max(2, (v.sales / max) * 100)}%` }} />
                    {canViewFinancial && <div className="w-full max-w-[0.9rem] rounded-t bg-brass/70" style={{ height: `${Math.max(2, (Math.max(v.profit, 0) / max) * 100)}%` }} />}
                  </div>
                  <span className="text-[0.625rem] text-charcoal/40">{period === "month" ? key.slice(8) : key.slice(2)}</span>
                </div>
              ))}
            </div>
            <div className="mt-3 flex items-center gap-4 text-[0.6875rem] text-charcoal/50">
              <span className="flex items-center gap-1.5">
                <span className="h-2 w-2 rounded-sm bg-sage" /> صافي المبيعات
              </span>
              {canViewFinancial && (
                <span className="flex items-center gap-1.5">
                  <span className="h-2 w-2 rounded-sm bg-brass/70" /> إجمالي الربح
                </span>
              )}
            </div>
          </>
        )}
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
