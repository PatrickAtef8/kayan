"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { usePendingPath } from "./navigation-progress";
import { SignOutForm } from "./sign-out-form";
import { Package, Warehouse, Users, Truck, ShoppingCart, ShoppingBag, Boxes, Receipt, Wallet, UserCheck, Handshake, Tag, BarChart3, LayoutGrid, X, Settings2 } from "lucide-react";
import { MODULES } from "@/lib/modules";

const ICONS = { Package, Warehouse, Users, Truck, ShoppingCart, ShoppingBag, Boxes, Receipt, Wallet, UserCheck, Handshake, Tag, BarChart3 } as const;

// A rep only works with customers, sales and their own reports.
const REP_MODULES = new Set(["customers", "sales", "reports"]);

export function Sidebar({ orgName, enabledKeys, restrictedRep = false, open, onClose }: { orgName?: string; enabledKeys: Set<string>; restrictedRep?: boolean; open: boolean; onClose: () => void }) {
  const currentPath = usePathname();
  const pendingPath = usePendingPath();
  const pathname = pendingPath ?? currentPath; // highlight the destination as soon as it is clicked
  const visibleModules = MODULES.filter((m) => (restrictedRep ? REP_MODULES.has(m.key) && (m.key === "reports" || enabledKeys.has(m.key)) : "core" in m && m.core ? true : enabledKeys.has(m.key)));
  return <>
    {open && <button onClick={onClose} className="fixed inset-0 z-40 cursor-default bg-charcoal/15 md:hidden" aria-label="إغلاق القائمة" />}
    <aside className={`fixed inset-y-0 right-0 z-50 flex w-[16rem] flex-col border-l border-borderSoft bg-[#fbfaf7] px-4 py-6 text-charcoal transition-transform duration-300 md:sticky md:top-0 md:h-screen md:translate-x-0 ${open ? "translate-x-0" : "translate-x-full"}`}>
      <div className="mb-10 flex items-center justify-between px-2"><Link href="/dashboard" onClick={onClose} className="flex items-center gap-3"><span className="flex h-9 w-9 items-center justify-center rounded-xl bg-charcoal text-sm font-semibold text-ivory">ك</span><span className="text-sm font-semibold">{orgName ?? "مساحة العمل"}</span></Link><button onClick={onClose} aria-label="إغلاق القائمة" className="rounded-lg p-1.5 text-charcoal/40 hover:bg-paper md:hidden"><X size={18} /></button></div>
      <nav className="flex-1 overflow-y-auto"><p className="mb-3 px-3 text-[0.625rem] font-medium text-charcoal/30">القائمة</p><NavLink href="/dashboard" active={pathname === "/dashboard"} onNavigate={onClose}><LayoutGrid size={17} />الرئيسية</NavLink><p className="mb-3 mt-8 px-3 text-[0.625rem] font-medium text-charcoal/30">الوحدات</p>{visibleModules.map((m) => { const Icon = ICONS[m.icon as keyof typeof ICONS]; return <NavLink key={m.key} href={m.href} active={pathname.startsWith(m.href)} onNavigate={onClose}><Icon size={17} />{m.label}</NavLink>; })}</nav>
      <div className="border-t border-borderSoft pt-4">{!restrictedRep && <Link href="/dashboard/settings" onClick={onClose} className="flex items-center gap-3 rounded-xl px-3 py-2.5 text-xs text-charcoal/45 hover:bg-paper hover:text-charcoal"><Settings2 size={17} />الإعدادات</Link>}<SignOutForm /></div>
    </aside>
  </>;
}

function NavLink({ href, active, onNavigate, children }: { href: string; active: boolean; onNavigate: () => void; children: React.ReactNode }) {
  return <Link href={href} onClick={onNavigate} className={`flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm transition-colors ${active ? "bg-sageSoft font-medium text-sage" : "text-charcoal/50 hover:bg-paper hover:text-charcoal"}`}>{children}</Link>;
}
