import { getSupabase, getMembership } from "@/lib/org-context";

export async function getReportContext() {
  const supabase = (await getSupabase());
  const membership = await getMembership();

  if (!membership) return { supabase, orgId: null as string | null, canViewFinancial: false, canExport: false };

  const [{ data: canViewFinancial }, { data: canExport }] = await Promise.all([
    supabase.rpc("has_permission", { target_org: membership.organization_id, perm_key: "view_financial" }),
    supabase.rpc("has_permission", { target_org: membership.organization_id, perm_key: "reports.export" }),
  ]);

  return { supabase, orgId: membership.organization_id as string, canViewFinancial: !!canViewFinancial, canExport: !!canExport };
}
