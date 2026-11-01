import type { Metadata } from "next";
import { Suspense } from "react";
import { LogOut } from "lucide-react";
import { NavigationProgress } from "@/components/dashboard/navigation-progress";
import { requireSuperAdminPage } from "@/lib/admin/auth.server";
import { AdminNav } from "@/components/admin/admin-nav";
import { AdminSwitcher } from "@/components/admin/admin-switcher";

export const metadata: Metadata = { title: "إدارة المنصة — كيان", robots: { index: false, follow: false } };

// The whole /admin area. Authorization happens HERE (server-side) and again inside every action and data call.
export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  const user = await requireSuperAdminPage();
  return (
    <div className="min-h-screen bg-paper text-charcoal">
      <Suspense fallback={null}><NavigationProgress /></Suspense>
      <header className="border-b border-borderSoft bg-white/80 backdrop-blur">
        <div className="mx-auto flex max-w-6xl flex-col gap-3 px-4 py-4 sm:px-6">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div className="flex items-center gap-3">
              <span className="text-xl font-semibold tracking-tight">كيان</span>
              <span className="bg-charcoal px-2.5 py-1 text-[0.6875rem] font-medium text-ivory">إدارة المنصة</span>
            </div>
            <div className="flex flex-wrap items-center gap-3">
              <AdminSwitcher current="admin" />
              <span className="hidden text-xs text-charcoal/50 lg:inline" dir="ltr">{user.email}</span>
              <form action="/api/auth/signout" method="post">
                <button aria-label="تسجيل الخروج" title="تسجيل الخروج" className="flex h-9 w-9 items-center justify-center rounded-lg border border-borderSoft text-charcoal/55 hover:border-rose/40 hover:text-rose"><LogOut size={16} /></button>
              </form>
            </div>
          </div>
          <AdminNav />
        </div>
      </header>
      <main data-page-content className="mx-auto max-w-6xl px-4 py-6 sm:px-6 sm:py-8">{children}</main>
    </div>
  );
}
