import { redirect } from "next/navigation";
import { getSupabase, getCurrentUser, getMembership, roleNameOf, getRoleKey } from "@/lib/org-context";
import { DashboardShell } from "@/components/dashboard/shell";
import type { AppNotification } from "@/lib/notifications";
import { createAdminClient } from "@/lib/supabase/admin";

export default async function DashboardLayout({ children }: { children: React.ReactNode }) {
  const supabase = (await getSupabase());
  const user = await getCurrentUser();
  if (!user) redirect("/login");

  const membership = await getMembership();
  if (!membership) {
    // Signed up while email confirmation was required: the company entered at signup was kept on the
    // account; create it now that the person has confirmed and logged in.
    const pending = user.user_metadata?.pending_org as { name?: string; business_type?: string; modules?: string[] } | undefined;
    if (pending?.name) {
      let created = false;
      const { data: again } = await supabase.from("organization_users").select("organization_id").eq("user_id", user.id).eq("status", "active").limit(1);
      if (again && again.length > 0) created = true;   // another request already created it
      else {
        const { error } = await supabase.rpc("create_organization", {
          org_name: pending.name,
          org_business_type: pending.business_type ?? "",
          org_country: "EG",
          org_currency: "EGP",
          org_language: "ar",
          module_keys: pending.modules ?? [],
        });
        if (error) console.error("dashboard: pending organization creation failed", error);
        else {
          created = true;
          try {
            await createAdminClient().auth.admin.updateUserById(user.id, { user_metadata: { ...user.user_metadata, pending_org: null } });
          } catch { /* best effort: the membership now exists, so the stored details are never used again */ }
        }
      }
      if (created) redirect("/dashboard");
    }

    // No active membership: either a pending invitation to accept, or a brand-new account.
    const { data: invites } = await supabase.rpc("list_my_invites");
    if (Array.isArray(invites) && invites.length > 0) redirect("/invites");
    redirect("/signup");
  }

  const orgId = membership.organization_id;
  const roleName = roleNameOf(membership);

  // Independent lookups run together instead of one after another.
  const [orgRes, modulesRes, notificationsRes, unreadRes, roleKey] = await Promise.all([
    supabase.from("organizations").select("name").eq("id", orgId).maybeSingle(),
    supabase.from("organization_modules").select("module_key").eq("organization_id", orgId).eq("enabled", true),
    // stored notifications of THIS user (0046): the first page now, the rest follows over Realtime
    supabase.rpc("list_my_notifications", { org_id: orgId, p_filter: "all", p_limit: 20 }),
    supabase.rpc("my_unread_notification_count", { org_id: orgId }),
    getRoleKey(),
  ]);
  // storekeeper work queue (also shown to the owner): quantities only
  const pendingRes = roleKey === "sales" || !roleKey ? null : await supabase.rpc("warehouse_pending_counts", { org_id: orgId });
  const pending = (pendingRes?.data as { sales: number; purchases: number } | null) ?? { sales: 0, purchases: 0 };
  const pendingOrders = Number(pending.sales) + Number(pending.purchases);
  // stock-shortage reports: the owner's open ones, or the rep's own (open + recently provided)
  const shortageRes = roleKey === "owner" || roleKey === "sales" ? await supabase.rpc("stock_shortage_counts", { org_id: orgId }) : null;
  const sc = (shortageRes?.data as { new: number; in_progress: number; ready: number } | null) ?? { new: 0, in_progress: 0, ready: 0 };
  const shortageBadge = roleKey === "owner" ? Number(sc.new) : Number(sc.ready);
  if (orgRes.error) console.error("dashboard: organization lookup failed", orgRes.error);
  if (modulesRes.error) console.error("dashboard: modules lookup failed", modulesRes.error);
  if (notificationsRes.error) console.error("dashboard: notifications lookup failed", notificationsRes.error);
  const notifications = (notificationsRes.data as AppNotification[] | null) ?? [];
  const unread = Number(unreadRes.data) || 0;
  const org = orgRes.data;
  const enabledKeys = new Set((modulesRes.data ?? []).map((m) => m.module_key));

  return (
    <DashboardShell orgId={orgId} userId={user.id} orgName={org?.name} enabledKeys={enabledKeys} userEmail={user.email ?? undefined} roleName={roleName} initialNotifications={notifications} initialUnread={unread} role={roleKey ?? "owner"} pendingOrders={pendingOrders} shortageBadge={shortageBadge}>
      {children}
    </DashboardShell>
  );
}
