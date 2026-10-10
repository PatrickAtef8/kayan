import { getSupabase, getMembership } from "@/lib/org-context";

export async function getSettingsContext() {
  const supabase = (await getSupabase());
  const membership = await getMembership();

  if (!membership) return { supabase, orgId: null as string | null, canManage: false };

  const { data: canManage } = await supabase.rpc("has_permission", {
    target_org: membership.organization_id,
    perm_key: "manage_settings",
  });

  return { supabase, orgId: membership.organization_id as string, canManage: !!canManage };
}
