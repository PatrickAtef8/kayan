import { redirect } from "next/navigation";
import { headers } from "next/headers";
import { getSupabase, getCurrentUser, getMembership, roleNameOf, getRoleKey, getOrgAccess } from "@/lib/org-context";
import { DashboardShell } from "@/components/dashboard/shell";
import type { AppNotification } from "@/lib/notifications";
import { createAdminClient } from "@/lib/supabase/admin";
import { BillingBanner } from "@/components/dashboard/billing-banner";
import { PaywallShell, WorkspaceNotActive, GateUnavailable } from "@/components/dashboard/paywall";
import { OwnerPaywallBody } from "@/components/dashboard/owner-paywall-body";
import { isSuperAdminSession } from "@/lib/admin/auth.server";
import { COMPLIMENTARY_ENTITLEMENTS } from "@/lib/billing/complimentary";
import { GraceBanner } from "@/components/dashboard/grace-banner";
import { TrialBanner } from "@/components/dashboard/trial-banner";
import { startTrialForOwner } from "@/lib/billing/trial.server";
import { decideAccess, isBillingPath, parseAccess, type GateDecision } from "@/lib/billing/access-gate";

export const metadata = { robots: { index: false, follow: false, nocache: true } };

export default async function DashboardLayout({ children }: { children: React.ReactNode }) {
  const supabase = (await getSupabase());
  const user = await getCurrentUser();
  if (!user) redirect("/login");

  // A platform administrator (SUPER_ADMIN_USER_IDS) is never subject to payment: this is checked first and costs no database call.
  const isAdmin = await isSuperAdminSession(user);

  const membership = await getMembership();
  if (!membership) {
    // Signed up while email confirmation was required: the company entered at signup was kept on the
    // account; create it now that the person has confirmed and logged in.
    const pending = user.user_metadata?.pending_org as { name?: string; business_type?: string } | undefined;
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
          module_keys: [],   // the package decides the modules (switched on when the first payment is verified)
        });
        if (error) console.error("dashboard: pending organization creation failed", error);
        else {
          created = true;
          // "Start for free" was chosen at sign-up and the email had to be confirmed first: the trial starts now, once, for the company just
          // created. (The database re-checks everything: owner, trials on, no license, one trial per account.)
          const wantsTrial = user.user_metadata?.start_trial === true && !isAdmin;
          if (wantsTrial) {
            try {
              const { data: m } = await supabase.from("organization_users").select("organization_id").eq("user_id", user.id).eq("status", "active").limit(1).maybeSingle();
              if (m?.organization_id) await startTrialForOwner({ userId: user.id, organizationId: m.organization_id as string });
            } catch (e) { console.error("dashboard: could not start the requested free trial", e instanceof Error ? e.message : e); }
          }
          try {
            await createAdminClient().auth.admin.updateUserById(user.id, { user_metadata: { ...user.user_metadata, pending_org: null, start_trial: null } });
          } catch { /* best effort: the membership now exists, so the stored details are never used again */ }
        }
      }
      if (created) redirect("/dashboard");
    }

    // No active membership: either a pending invitation to accept, or a brand-new account.
    const { data: invites } = await supabase.rpc("list_my_invites");
    if (Array.isArray(invites) && invites.length > 0) redirect("/invites");
    // A platform administrator with no company of their own belongs in the back office. /signup creates a NEW account (email +
    // password), so sending a signed-in administrator there was a dead end.
    if (isAdmin) redirect("/admin");
    redirect("/signup");
  }

  const orgId = membership.organization_id;
  const roleName = roleNameOf(membership);

  // Independent lookups run together. The two role-dependent counters used to be awaited one after the other
  // AFTER the batch (two extra sequential round trips on every page); they now hang off the role lookup inside
  // the same batch, so the whole layout costs max(...) instead of sum(...).
  const rolePromise = getRoleKey();
  // storekeeper work queue (also shown to the owner): quantities only
  const pendingPromise = rolePromise.then((rk) => (rk === "sales" || !rk ? null : supabase.rpc("warehouse_pending_counts", { org_id: orgId })));
  // stock-shortage reports: the owner's open ones, or the rep's own (open + recently provided)
  const shortagePromise = rolePromise.then((rk) => (rk === "owner" || rk === "sales" ? supabase.rpc("stock_shortage_counts", { org_id: orgId }) : null));
  // the owner is reminded when the paid period is about to end / has ended (0060); nobody else needs the license row
  // The payment gate: what the company has paid for, readable by ANY member (the license table itself is owner-only). Skipped for administrators.
  // The administrator's own demo company gets FREE access (a complimentary license) the first time they open it, so their demo team
  // (reps, storekeepers) can work: members always follow the company's real subscription, never the owner's status.
  let adminAccess = isAdmin ? await supabase.rpc("my_org_access", { target_org: orgId }) : null;
  if (adminAccess) {
    const a = parseAccess(adminAccess.data);
    if (a && !a.license && a.owners.some((o) => o.id === user.id)) {
      try {
        await createAdminClient().rpc("admin_grant_complimentary_license", { p_admin: user.id, p_org: orgId, p_package: "one_time", p_entitlements: COMPLIMENTARY_ENTITLEMENTS });
        adminAccess = await supabase.rpc("my_org_access", { target_org: orgId });
      } catch (e) { console.error("dashboard: could not give the administrator's company free access", e instanceof Error ? e.message : e); }
    }
  }
  const accessPromise = adminAccess ? Promise.resolve(adminAccess) : getOrgAccess(orgId);   // shared with the billing page
  const [orgRes, modulesRes, notificationsRes, unreadRes, roleKey, pendingRes, shortageRes, accessRes] = await Promise.all([
    supabase.from("organizations").select("name").eq("id", orgId).maybeSingle(),
    supabase.from("organization_modules").select("module_key").eq("organization_id", orgId).eq("enabled", true),
    // stored notifications of THIS user (0046): the first page now, the rest follows over Realtime
    supabase.rpc("list_my_notifications", { org_id: orgId, p_filter: "all", p_limit: 20 }),
    supabase.rpc("my_unread_notification_count", { org_id: orgId }),
    rolePromise,
    pendingPromise,
    shortagePromise,
    accessPromise,
  ]);
  // ---- the payment gate ---------------------------------------------------------------------------------------------------
  // Server-side, on every page render of the dashboard: nothing the browser sends can skip it. (It fails CLOSED: if the state of
  // the subscription cannot be read, the dashboard stays shut rather than opening by mistake.)
  if (accessRes?.error) {
    console.error("dashboard: could not read the company's access state (is migration 0063 applied?)", accessRes.error);
    return <PaywallShell userEmail={user.email}><GateUnavailable /></PaywallShell>;
  }
  const access = parseAccess(accessRes?.data);
  if (!access?.access) {
    console.error("dashboard: my_org_access returned no access state (migration 0063 not applied?)");
    return <PaywallShell orgName={orgRes.data?.name} userEmail={user.email}><GateUnavailable /></PaywallShell>;
  }
  const orgName = access.orgName ?? orgRes.data?.name;
  const decision: GateDecision = decideAccess({ isPlatformAdmin: isAdmin, access: access.access });
  if (!decision.open) {
    const lapsed = decision.reason === "expired";
    const trialEnded = decision.reason === "trial_expired";
    if (roleKey !== "owner") return <PaywallShell orgName={orgName} userEmail={user.email}><WorkspaceNotActive lapsed={lapsed} trialEnded={trialEnded} /></PaywallShell>;
    // The owner is NOT redirected: they see the "activate your account" card and press its button to open the billing page. The layout
    // is not re-rendered when the owner clicks around (Next.js keeps it mounted), so the billing-or-prompt decision is handed to a
    // client component that follows the browser's current path — otherwise the card stayed on screen on /dashboard/billing itself.
    const promptReason = trialEnded ? "trial_ended" : lapsed ? "expired" : "never_paid";
    return <PaywallShell orgName={orgName} userEmail={user.email}><OwnerPaywallBody reason={promptReason} trial={{ eligible: access.trialOffer.eligible, days: access.trialOffer.days }}>{children}</OwnerPaywallBody></PaywallShell>;
  }

  const pending = (pendingRes?.data as { sales: number; purchases: number } | null) ?? { sales: 0, purchases: 0 };
  const pendingOrders = Number(pending.sales) + Number(pending.purchases);
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
    <DashboardShell isAdmin={isAdmin} orgId={orgId} userId={user.id} orgName={org?.name} enabledKeys={enabledKeys} userEmail={user.email ?? undefined} roleName={roleName} initialNotifications={notifications} initialUnread={unread} role={roleKey ?? "owner"} pendingOrders={pendingOrders} shortageBadge={shortageBadge}>
      {!isAdmin && access.access.state === "grace" && access.access.secondsLeft !== null ? <GraceBanner secondsLeft={access.access.secondsLeft} isOwner={roleKey === "owner"} monthly={access.license?.payment_option === "monthly"} /> : null}
      {!isAdmin && access.access.state === "trial" && access.access.secondsLeft !== null ? <TrialBanner secondsLeft={access.access.secondsLeft} isOwner={roleKey === "owner"} /> : null}
      {!isAdmin && roleKey === "owner" ? <BillingBanner access={access.access} /> : null}
      {children}
    </DashboardShell>
  );
}
