import { redirect } from "next/navigation";
import { getSupabase, getCurrentUser, getMembership, roleNameOf, isRestrictedRep } from "@/lib/org-context";
import type { createClient } from "@/lib/supabase/server";
import { DashboardShell } from "@/components/dashboard/shell";
import type { AppNotification } from "@/components/dashboard/topbar";

export default async function DashboardLayout({ children }: { children: React.ReactNode }) {
  const supabase = getSupabase();
  const user = await getCurrentUser();
  if (!user) redirect("/login");

  const membership = await getMembership();
  if (!membership) {
    // No active membership: either a pending invitation to accept, or a brand-new account.
    const { data: invites } = await supabase.rpc("list_my_invites");
    if (Array.isArray(invites) && invites.length > 0) redirect("/invites");
    redirect("/signup");
  }

  const orgId = membership.organization_id;
  const roleName = roleNameOf(membership);

  // Independent lookups run together instead of one after another.
  const [orgRes, modulesRes, notifications, restrictedRep] = await Promise.all([
    supabase.from("organizations").select("name").eq("id", orgId).maybeSingle(),
    supabase.from("organization_modules").select("module_key").eq("organization_id", orgId).eq("enabled", true),
    buildNotifications(supabase, orgId),
    isRestrictedRep(),
  ]);
  if (orgRes.error) console.error("dashboard: organization lookup failed", orgRes.error);
  if (modulesRes.error) console.error("dashboard: modules lookup failed", modulesRes.error);
  const org = orgRes.data;
  const enabledKeys = new Set((modulesRes.data ?? []).map((m) => m.module_key));

  return (
    <DashboardShell orgId={orgId} orgName={org?.name} enabledKeys={enabledKeys} userEmail={user.email ?? undefined} roleName={roleName} notifications={notifications} restrictedRep={restrictedRep}>
      {children}
    </DashboardShell>
  );
}

// Real, derived alerts (§45: low inventory, customer debt, supplier payment
// due) — not stored, just computed from current data each time the shell
// renders. Balance-related ones are hidden from users without view_financial,
// per "Notifications must respect user permissions."
async function buildNotifications(supabase: ReturnType<typeof createClient>, orgId: string): Promise<AppNotification[]> {
  const [{ data: canViewFinancial }, { data: canViewAudit }, { data: stockRows }, { data: customerBalances }, { data: supplierBalances }] = await Promise.all([
    supabase.rpc("has_permission", { target_org: orgId, perm_key: "view_financial" }),
    supabase.rpc("has_permission", { target_org: orgId, perm_key: "audit.view" }),
    supabase.from("inventory_stock").select("product_id, quantity").eq("organization_id", orgId).lte("quantity", 0),
    supabase.from("customer_balances").select("balance").eq("organization_id", orgId).gt("balance", 0),
    supabase.from("supplier_balances").select("balance").eq("organization_id", orgId).gt("balance", 0),
  ]);

  const notifications: AppNotification[] = [];

  const outOfStockProducts = new Set((stockRows ?? []).filter((r) => Number(r.quantity) <= 0).map((r) => r.product_id));
  if (outOfStockProducts.size > 0) {
    notifications.push({
      id: "low-stock",
      title: `${outOfStockProducts.size} منتج نفدت كميته`,
      description: "راجع المخزون لإعادة الطلب من المورد.",
      href: "/dashboard/inventory",
    });
  }

  if (canViewFinancial) {
    const dueCustomers = (customerBalances ?? []).filter((r) => Number(r.balance) > 0);
    if (dueCustomers.length > 0) {
      const total = dueCustomers.reduce((sum, r) => sum + Number(r.balance), 0);
      notifications.push({
        id: "customer-debt",
        title: `${dueCustomers.length} عميل عليهم مستحقات`,
        description: `إجمالي المستحق: ${total.toLocaleString("ar-EG", { minimumFractionDigits: 2 })} ج.م`,
        href: "/dashboard/customers",
      });
    }

    const dueSuppliers = (supplierBalances ?? []).filter((r) => Number(r.balance) > 0);
    if (dueSuppliers.length > 0) {
      const total = dueSuppliers.reduce((sum, r) => sum + Number(r.balance), 0);
      notifications.push({
        id: "supplier-due",
        title: `مستحقات لـ ${dueSuppliers.length} مورد`,
        description: `إجمالي المطلوب: ${total.toLocaleString("ar-EG", { minimumFractionDigits: 2 })} ج.م`,
        href: "/dashboard/suppliers",
      });
    }
  }

  if (canViewFinancial) {
    // §45 "Outstanding collections" and "Large expenses" — computed in SQL
    // (0019) so this layout doesn't pull whole tables on every page load.
    const [{ data: overdue }, { data: large }] = await Promise.all([
      supabase.rpc("report_overdue_collections", { org_id: orgId, p_days: 30 }),
      supabase.rpc("report_large_expenses", { org_id: orgId, p_days: 7 }),
    ]);

    const overdueRow = Array.isArray(overdue) ? overdue[0] : null;
    if (overdueRow && Number(overdueRow.customer_count) > 0) {
      notifications.push({
        id: "overdue-collections",
        title: `${overdueRow.customer_count} عميل متأخر في السداد`,
        description: `لم يسددوا منذ أكثر من 30 يومًا — ${Number(overdueRow.total_balance).toLocaleString("ar-EG", { minimumFractionDigits: 2 })} ج.م`,
        href: "/dashboard/reports/customers",
      });
    }

    const largeRow = Array.isArray(large) ? large[0] : null;
    if (largeRow && Number(largeRow.expense_count) > 0) {
      notifications.push({
        id: "large-expenses",
        title: `${largeRow.expense_count} مصروف كبير خلال آخر 7 أيام`,
        description: `أكبرها ${Number(largeRow.largest_amount).toLocaleString("ar-EG", { minimumFractionDigits: 2 })} ج.م — أعلى من 3 أضعاف متوسط مصروفاتك`,
        href: "/dashboard/expenses",
      });
    }
  }

  if (canViewAudit) {
    // §45 "Important system events": deletions are the irreversible ones.
    const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    const { count } = await supabase
      .from("audit_logs")
      .select("id", { count: "exact", head: true })
      .eq("organization_id", orgId)
      .like("action", "%deleted")
      .gte("created_at", since);
    if ((count ?? 0) > 0) {
      notifications.push({
        id: "recent-deletions",
        title: `${count} عملية حذف خلال آخر 24 ساعة`,
        description: "راجع سجل العمليات للتأكد من أنها متوقعة.",
        href: "/dashboard/settings/audit",
      });
    }
  }

  return notifications;
}
