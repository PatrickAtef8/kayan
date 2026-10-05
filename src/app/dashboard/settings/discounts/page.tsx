import { getSettingsContext } from "@/lib/settings-context";
import { NoSettingsAccess } from "@/components/settings/no-settings-access";
import { DiscountsManager } from "./discounts-manager";

export type Tier = { id: string; applies_to: "sales" | "purchases"; min_amount: number; discount_pct: number; is_active: boolean };

export default async function DiscountsSettingsPage() {
  const { supabase, orgId, canManage } = await getSettingsContext();
  if (!orgId) return null;
  if (!canManage) return <NoSettingsAccess />;

  const { data: tiers } = await supabase
    .from("discount_tiers")
    .select("id, applies_to, min_amount, discount_pct, is_active")
    .eq("organization_id", orgId)
    .order("min_amount");

  return <DiscountsManager tiers={(tiers as Tier[]) ?? []} />;
}
