import { getSettingsContext } from "@/lib/settings-context";
import { NoSettingsAccess } from "@/components/settings/no-settings-access";
import { LimitsManager } from "./limits-manager";

export type RoleRow = { id: string; name: string; key: string | null };
export type LimitRow = { role_id: string; max_discount_pct: number | null; can_give_manual_bonus: boolean };

export default async function LimitsSettingsPage() {
  const { supabase, orgId, canManage } = await getSettingsContext();
  if (!orgId) return null;
  if (!canManage) return <NoSettingsAccess />;

  const [{ data: roles }, { data: limits }] = await Promise.all([
    supabase.from("roles").select("id, name, key").order("name"),
    supabase.from("role_sales_limits").select("role_id, max_discount_pct, can_give_manual_bonus").eq("organization_id", orgId),
  ]);

  return <LimitsManager roles={(roles as RoleRow[]) ?? []} limits={(limits as LimitRow[]) ?? []} />;
}
