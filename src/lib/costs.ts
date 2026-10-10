import type { SupabaseClient } from "@supabase/supabase-js";

// Cost data lives in RLS-protected tables (migration 0034), not on product_prices / inventory_stock:
//   product_costs, stock_costs (+ movement / transfer cost tables used only by reports).
//   READ  -> view_financial | products.view_cost
//   WRITE -> (product_costs only) view_financial | purchases.approve | manage_settings
// The database enforces this; these helpers only talk to those tables.

const has = (supabase: SupabaseClient, orgId: string, perm_key: string) =>
  supabase.rpc("has_permission", { target_org: orgId, perm_key });

export async function canViewCost(supabase: SupabaseClient, orgId: string) {
  const r = await Promise.all(["view_financial", "products.view_cost"].map((k) => has(supabase, orgId, k)));
  return r.some((c) => !!c.data);
}

export async function canEditCost(supabase: SupabaseClient, orgId: string) {
  const r = await Promise.all(["view_financial", "purchases.approve", "manage_settings"].map((k) => has(supabase, orgId, k)));
  return r.some((c) => !!c.data);
}

export async function setProductCost(supabase: SupabaseClient, productId: string, cost: number) {
  if (!Number.isFinite(cost) || cost < 0) return { error: "التكلفة غير صحيحة" };
  const { error } = await supabase.from("product_costs").upsert({ product_id: productId, cost }, { onConflict: "product_id" });
  return { error: error ? error.message : null };
}

export async function getProductCosts(supabase: SupabaseClient, productIds: string[]) {
  const map = new Map<string, number>();
  if (productIds.length === 0) return map;
  const { data } = await supabase.from("product_costs").select("product_id, cost").in("product_id", productIds);
  for (const r of (data ?? []) as { product_id: string; cost: number | string }[]) map.set(r.product_id, Number(r.cost));
  return map;
}
