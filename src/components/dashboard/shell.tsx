"use client";

import { Suspense, useState } from "react";
import { Sidebar } from "./sidebar";
import { Topbar } from "./topbar";
import type { AppNotification } from "@/lib/notifications";
import { NavigationProgress } from "./navigation-progress";
import { ExportOrgProvider } from "@/components/ui/export-context";

export function DashboardShell({
  isAdmin = false,
  orgId,
  userId,
  orgName,
  enabledKeys,
  userEmail,
  roleName,
  initialNotifications,
  initialUnread,
  role = "owner",
  pendingOrders = 0,
  shortageBadge = 0,
  children,
}: {
  /** a verified platform administrator: gets the two-door switcher and no billing link */
  isAdmin?: boolean;
  orgId: string;
  userId: string;
  orgName?: string;
  enabledKeys: Set<string>;
  userEmail?: string;
  roleName?: string;
  initialNotifications: AppNotification[];
  initialUnread: number;
  role?: "owner" | "sales" | "warehouse";
  pendingOrders?: number;
  shortageBadge?: number;
  children: React.ReactNode;
}) {
  const [mobileOpen, setMobileOpen] = useState(false);
  return (
    <div className="min-h-dvh bg-[radial-gradient(circle_at_10%_0%,rgba(52,78,65,0.06),transparent_28rem),#F7F6F2] lg:flex lg:gap-3 lg:px-3">
      <Suspense fallback={null}>
        <NavigationProgress />
      </Suspense>
      <Sidebar isAdmin={isAdmin} orgName={orgName} enabledKeys={enabledKeys} role={role} pendingOrders={pendingOrders} shortageBadge={shortageBadge} open={mobileOpen} onClose={() => setMobileOpen(false)} />
      <div className="min-w-0 flex-1 lg:pl-2">
        <Topbar isAdmin={isAdmin} orgId={orgId} userId={userId} userEmail={userEmail} orgName={orgName} roleName={roleName} initialNotifications={initialNotifications} initialUnread={initialUnread} onMenuClick={() => setMobileOpen(true)} />
        <main data-page-content className="mx-auto w-full min-w-0 max-w-[92rem] px-3.5 pb-10 pt-5 sm:px-6 sm:pt-6 lg:px-8 xl:px-10"><ExportOrgProvider orgName={orgName}>{children}</ExportOrgProvider></main>
      </div>
    </div>
  );
}
