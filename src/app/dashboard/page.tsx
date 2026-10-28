import Link from "next/link";
import { getSupabase, getMembership, getRoleKey } from "@/lib/org-context";
import { PageHeader } from "@/components/ui/page-header";
import { DashboardHome } from "./dashboard-home";
import { RepHome } from "./rep-home";
import type { BreakdownRow, DashboardAnalyticsData } from "./dashboard-analytics";
import { resolvePeriod, type PeriodSel } from "@/lib/report-period";

export default async function DashboardPage(props: { searchParams: Promise<{ period?: string; m?: string; y?: string }> }) {
  const searchParams = await props.searchParams;
  // Any month, any year, or all time (?period=month&m=2025-03 · ?period=year&y=2025 · ?period=all) — Cairo calendar.
  const period: PeriodSel = resolvePeriod(searchParams);
  const start = period.from;
  const end = period.to;

  const supabase = (await getSupabase());
  const membership = await getMembership();

  if (!membership) {
    return (
      <DashboardHome period={period} hasProducts={false} canViewFinancial={false} totalSales={0} netProfit={0} treasuryBalance={0} customerReceivable={0} supplierPayable={0} inventoryValue={0} recentActivity={[]} analytics={{ trend: [], products: [], customers: [], representatives: [] }} />
    );
  }

  const orgId = membership.organization_id;

  // The storekeeper's home: work to do and stock alerts — quantities only, never a figure of money.
  if ((await getRoleKey()) === "warehouse") {
    const [counts, stock, expiry] = await Promise.all([
      supabase.rpc("warehouse_pending_counts", { org_id: orgId }),
      supabase.from("inventory_stock").select("product_id, quantity").eq("organization_id", orgId).lte("quantity", 0),
      supabase.rpc("report_expiry_summary", { org_id: orgId, p_days: 30 }),
    ]);
    const c = (counts.data as { sales: number; purchases: number } | null) ?? { sales: 0, purchases: 0 };
    const e = expiry.data as { expired?: { batches: number }; expiring?: { batches: number } } | null;
    const tiles = [
      { label: "أوامر صرف في الانتظار", value: Number(c.sales), href: "/dashboard/warehouse-orders?tab=sales" },
      { label: "أوامر استلام في الانتظار", value: Number(c.purchases), href: "/dashboard/warehouse-orders?tab=purchase" },
      { label: "أصناف نفدت كميتها", value: new Set((stock.data ?? []).map((r) => r.product_id)).size, href: "/dashboard/inventory" },
      { label: "دفعات منتهية أو قاربت على الانتهاء", value: Number(e?.expired?.batches ?? 0) + Number(e?.expiring?.batches ?? 0), href: "/dashboard/reports/inventory/expiry" },
    ];
    return (
      <div>
        <PageHeader title="الرئيسية" />
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 sm:gap-4 xl:grid-cols-4">
          {tiles.map((t) => (
            <Link key={t.label} href={t.href} className="min-w-0 rounded-xl border border-borderSoft bg-white p-4 transition-colors hover:border-sage sm:p-5">
              <p className="text-xs text-charcoal/45">{t.label}</p>
              <p className="mt-2 text-3xl font-semibold tracking-tight text-charcoal"><span dir="ltr" className="num">{t.value.toLocaleString("ar-EG")}</span></p>
            </Link>
          ))}
        </div>
      </div>
    );
  }

  // The sales rep's home: only his own customers and invoices, never a company-wide figure.
  if ((await getRoleKey()) === "sales") {
    return <RepHome supabase={supabase} orgId={orgId} period={period} />;
  }

  const [{ count: productCount }, { data: canViewFinancial }, { data: salesTotals }, { data: balanceTotals }, { data: recentActivity }, { data: rollups }, { data: topProducts }, { data: trendRows }] =
    await Promise.all([
      supabase.from("products").select("id", { count: "exact", head: true }).eq("organization_id", orgId),
      supabase.rpc("has_permission", { target_org: orgId, perm_key: "view_financial" }),
      supabase.rpc("dashboard_sales_totals", { org_id: orgId, p_from: start, p_to: end }),
      // receivable / payable / inventory value / treasury: summed in SQL (0059) instead of downloading every
      // customer, supplier, stock and treasury row (which also silently cut the totals past 1000 rows)
      supabase.rpc("dashboard_balance_totals", { org_id: orgId }),
      supabase.rpc("report_recent_activity", { org_id: orgId, p_limit: 8 }),
      // Top customers + top representatives in one pass (0021; its trend rows are no longer used); top
      // products still needs invoice-line data so it keeps the report function.
      supabase.rpc("dashboard_sales_rollups", { org_id: orgId, p_from: start, p_to: end }),
      supabase.rpc("report_sales_breakdown", { org_id: orgId, p_from: start, p_to: end, p_group: "product", p_limit: 5, p_offset: 0 }),
      // The chart: same rules as the two KPI cards (0055), so the bars and the line add up to them.
      supabase.rpc("dashboard_sales_trend", { org_id: orgId, p_from: start, p_to: end, p_bucket: period.kind === "month" ? "day" : "month" }),
    ]);

  const rollupRows = (rollups as (BreakdownRow & { kind: string })[] | null) ?? [];

  // Summed in SQL (0021) instead of downloading every invoice of the period.
  const totalsRow = Array.isArray(salesTotals) ? salesTotals[0] : null;
  const totalSales = Number(totalsRow?.total_sales ?? 0);
  const netProfit = Number(totalsRow?.total_profit ?? 0);
  const bt = (Array.isArray(balanceTotals) ? balanceTotals[0] : balanceTotals) as { customer_receivable?: number | string; supplier_payable?: number | string; inventory_value?: number | string; treasury_balance?: number | string } | null;
  const customerReceivable = Number(bt?.customer_receivable ?? 0);
  const supplierPayable = Number(bt?.supplier_payable ?? 0);
  // avg cost is protected (0034): the value is 0 for roles without cost access, so it is only meaningful for financial viewers
  const inventoryValue = Number(bt?.inventory_value ?? 0);
  const treasuryBalance = Number(bt?.treasury_balance ?? 0);

  return (
    <DashboardHome
      period={period}
      // The "add your first product" banner links to /dashboard/products, which only the owner may open.
      // A rep cannot read products (RLS) so the count is 0 for him — treat that as "nothing to prompt" instead of
      // showing a button that bounces him straight back to the dashboard.
      hasProducts={(await getRoleKey()) !== "owner" || (productCount ?? 0) > 0}
      canViewFinancial={!!canViewFinancial}
      totalSales={totalSales}
      netProfit={netProfit}
      treasuryBalance={treasuryBalance}
      customerReceivable={customerReceivable}
      supplierPayable={supplierPayable}
      inventoryValue={inventoryValue}
      recentActivity={recentActivity ?? []}
      analytics={{
        trend: ((trendRows as { bucket_date: string; net_sales: number; gross_profit: number | null; overhead: number | null; net_profit: number | null }[] | null) ?? []).map((r) => ({
          bucket_date: r.bucket_date,
          net_sales: Number(r.net_sales),
          gross_profit: r.gross_profit == null ? null : Number(r.gross_profit),
          overhead: r.overhead == null ? null : Number(r.overhead),
          net_profit: r.net_profit == null ? null : Number(r.net_profit),
        })),
        products: (topProducts as BreakdownRow[]) ?? [],
        customers: rollupRows.filter((r) => r.kind === "customer"),
        representatives: rollupRows.filter((r) => r.kind === "representative" && r.group_key !== ""),
      }}
    />
  );
}
