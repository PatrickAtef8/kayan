"use client";

import { Suspense, useState } from "react";
import { Sidebar } from "./sidebar";
import { Topbar, type AppNotification } from "./topbar";
import { NavigationProgress } from "./navigation-progress";

export function DashboardShell({
  orgId,
  orgName,
  enabledKeys,
  userEmail,
  roleName,
  notifications,
  restrictedRep = false,
  children,
}: {
  orgId: string;
  orgName?: string;
  enabledKeys: Set<string>;
  userEmail?: string;
  roleName?: string;
  notifications: AppNotification[];
  restrictedRep?: boolean;
  children: React.ReactNode;
}) {
  const [mobileOpen, setMobileOpen] = useState(false);
  return (
    <div className="min-h-screen bg-[radial-gradient(circle_at_10%_0%,rgba(52,78,65,0.06),transparent_28rem),#F7F6F2] md:flex md:gap-3 md:px-3">
      <Suspense fallback={null}>
        <NavigationProgress />
      </Suspense>
      <Sidebar orgName={orgName} enabledKeys={enabledKeys} restrictedRep={restrictedRep} open={mobileOpen} onClose={() => setMobileOpen(false)} />
      <div className="min-w-0 flex-1 md:pl-2">
        <Topbar orgId={orgId} userEmail={userEmail} orgName={orgName} roleName={roleName} notifications={notifications} onMenuClick={() => setMobileOpen(true)} />
        <main data-page-content className="mx-auto w-full max-w-[92rem] px-4 pb-8 sm:px-7 lg:px-10">{children}</main>
      </div>
    </div>
  );
}
