import type { SupabaseClient } from "@supabase/supabase-js";

// Opening balances live in their own RLS-protected tables (migration 0032):
//   read  -> view_financial | customers.view_balance | suppliers.view_balance
//   write -> view_financial | treasury.manage | manage_settings
// The database enforces this; these helpers only talk to those tables.

export type PartyKind = "customer" | "supplier";

const TABLE = { customer: "customer_opening_balances", supplier: "supplier_opening_balances" } as const;
const COL = { customer: "customer_id", supplier: "supplier_id" } as const;

export async function setOpeningBalance(supabase: SupabaseClient, kind: PartyKind, id: string, amount: number) {
  if (!Number.isFinite(amount)) return { error: "الرصيد الافتتاحي غير صحيح" };
  const { error } = await supabase.from(TABLE[kind]).upsert({ [COL[kind]]: id, amount }, { onConflict: COL[kind] });
  return { error: error ? error.message : null };
}

// Roles allowed to WRITE opening balances (mirrors balance_edit_org_ids() in the database).
export async function canEditOpeningBalance(supabase: SupabaseClient, orgId: string) {
  const checks = await Promise.all(
    ["view_financial", "treasury.manage", "manage_settings"].map((perm_key) =>
      supabase.rpc("has_permission", { target_org: orgId, perm_key })
    )
  );
  return checks.some((c) => !!c.data);
}

export async function getOpeningBalances(supabase: SupabaseClient, kind: PartyKind, ids: string[]) {
  const map = new Map<string, number>();
  if (ids.length === 0) return map;
  const { data } = await supabase.from(TABLE[kind]).select(`${COL[kind]}, amount`).in(COL[kind], ids);
  for (const r of (data ?? []) as unknown as Record<string, string | number>[]) {
    map.set(String(r[COL[kind]]), Number(r.amount));
  }
  return map;
}
