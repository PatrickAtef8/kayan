import { getSupabase, getMembership } from "@/lib/org-context";
import { DashboardHome } from "./dashboard-home";
import type { BreakdownRow, DashboardAnalyticsData } from "./dashboard-analytics";

export type Period = "month" | "year" | "all";

function periodStart(period: Period): string | null {
  const now = new Date();
  if (period === "month") return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString().slice(0, 10);
  if (period === "year") return new Date(Date.UTC(now.getUTCFullYear(), 0, 1)).toISOString().slice(0, 10);
  return null;
}

export default async function DashboardPage({ searchParams }: { searchParams: { period?: string } }) {
  const period: Period = searchParams.period === "year" || searchParams.period === "all" ? (searchParams.period as Period) : "month";
  const start = periodStart(period);

  const supabase = getSupabase();
  const membership = await getMembership();

  if (!membership) {
    return (
      <DashboardHome period={period} hasProducts={false} canViewFinancial={false} totalSales={0} netProfit={0} treasuryBalance={0} customerReceivable={0} supplierPayable={0} inventoryValue={0} recentActivity={[]} analytics={{ trend: [], products: [], customers: [], representatives: [] }} />
    );
  }

  const orgId = membership.organization_id;

  const [{ count: productCount }, { data: canViewFinancial }, { data: salesTotals }, { data: customerBalances }, { data: supplierBalances }, { data: stockRows }, { data: treasuryRows }, { data: recentActivity }, { data: rollups }, { data: topProducts }] =
    await Promise.all([
      supabase.from("products").select("id", { count: "exact", head: true }).eq("organization_id", orgId),
      supabase.rpc("has_permission", { target_org: orgId, perm_key: "view_financial" }),
      supabase.rpc("dashboard_sales_totals", { org_id: orgId, p_from: start }),
      supabase.from("customer_balances").select("balance").eq("organization_id", orgId),
      supabase.from("supplier_balances").select("balance").eq("organization_id", orgId),
      supabase.from("inventory_stock").select("quantity, avg_cost").eq("organization_id", orgId),
      supabase.from("treasury_balances").select("balance").eq("organization_id", orgId),
      supabase.rpc("report_recent_activity", { org_id: orgId, p_limit: 8 }),
      // Trend + top customers + top representatives in one pass (0021); top
      // products still needs invoice-line data so it keeps the report function.
      supabase.rpc("dashboard_sales_rollups", { org_id: orgId, p_from: start }),
      supabase.rpc("report_sales_breakdown", { org_id: orgId, p_from: start, p_to: null, p_group: "product", p_limit: 5, p_offset: 0 }),
    ]);

  const rollupRows = (rollups as (BreakdownRow & { kind: string })[] | null) ?? [];

  // Summed in SQL (0021) instead of downloading every invoice of the period.
  const totalsRow = Array.isArray(salesTotals) ? salesTotals[0] : null;
  const totalSales = Number(totalsRow?.total_sales ?? 0);
  const netProfit = Number(totalsRow?.total_profit ?? 0);
  const customerReceivable = (customerBalances ?? []).reduce((sum, r) => sum + Number(r.balance), 0);
  const supplierPayable = (supplierBalances ?? []).reduce((sum, r) => sum + Number(r.balance), 0);
  const inventoryValue = (stockRows ?? []).reduce((sum, r) => sum + Number(r.quantity) * Number(r.avg_cost), 0);
  const treasuryBalance = (treasuryRows ?? []).reduce((sum, r) => sum + Number(r.balance), 0);

  return (
    <DashboardHome
      period={period}
      hasProducts={(productCount ?? 0) > 0}
      canViewFinancial={!!canViewFinancial}
      totalSales={totalSales}
      netProfit={netProfit}
      treasuryBalance={treasuryBalance}
      customerReceivable={customerReceivable}
      supplierPayable={supplierPayable}
      inventoryValue={inventoryValue}
      recentActivity={recentActivity ?? []}
      analytics={{
        trend: rollupRows.filter((r) => r.kind === "trend"),
        products: (topProducts as BreakdownRow[]) ?? [],
        customers: rollupRows.filter((r) => r.kind === "customer"),
        representatives: rollupRows.filter((r) => r.kind === "representative" && r.group_key !== ""),
      }}
    />
  );
}
