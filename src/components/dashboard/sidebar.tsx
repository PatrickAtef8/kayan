"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { usePendingPath } from "./navigation-progress";
import { SignOutForm } from "./sign-out-form";
import { ClipboardCheck, PackageX, Package, Warehouse, Users, Truck, ShoppingCart, ShoppingBag, Boxes, Receipt, Wallet, UserCheck, Handshake, Tag, BarChart3, LayoutGrid, X, Settings2, Globe } from "lucide-react";
import { MODULES } from "@/lib/modules";

const ICONS = { Package, Warehouse, Users, Truck, ShoppingCart, ShoppingBag, Boxes, Receipt, Wallet, UserCheck, Handshake, Tag, BarChart3 } as const;

// What each non-owner role works with (the database enforces the same split on the data itself).
const REP_MODULES = new Set(["customers", "sales", "reports"]);
const KEEPER_MODULES = new Set(["products", "warehouses", "inventory", "reports"]);

export function Sidebar({ orgName, enabledKeys, role = "owner", pendingOrders = 0, shortageBadge = 0, open, onClose }: { orgName?: string; enabledKeys: Set<string>; role?: "owner" | "sales" | "warehouse"; pendingOrders?: number; shortageBadge?: number; open: boolean; onClose: () => void }) {
  const currentPath = usePathname();
  const pendingPath = usePendingPath();
  const pathname = pendingPath ?? currentPath; // highlight the destination as soon as it is clicked
  const restrictedRep = role === "sales";
  const allowed = role === "sales" ? REP_MODULES : role === "warehouse" ? KEEPER_MODULES : null;
  const visibleModules = MODULES.filter((m) => (allowed ? allowed.has(m.key) && ("core" in m && m.core ? true : enabledKeys.has(m.key)) : "core" in m && m.core ? true : enabledKeys.has(m.key)));
  const showOrders = role !== "sales" && (enabledKeys.has("sales") || enabledKeys.has("purchases") || enabledKeys.has("inventory"));
  const showShortages = role !== "warehouse" && enabledKeys.has("sales");
  return <>
    {open && <button onClick={onClose} className="fixed inset-0 z-40 cursor-default bg-charcoal/25 lg:hidden" aria-label="إغلاق القائمة" />}
    <aside className={`fixed inset-y-0 right-0 z-50 flex w-[16rem] max-w-[85vw] flex-col border-l border-borderSoft bg-[#fbfaf7] px-4 py-6 text-charcoal transition-transform duration-300 lg:sticky lg:top-0 lg:h-screen lg:max-w-none lg:translate-x-0 ${open ? "translate-x-0" : "translate-x-full"}`}>
      <div className="mb-10 flex items-center justify-between px-2"><Link href="/dashboard" onClick={onClose} className="flex items-center gap-3"><span className="flex h-9 w-9 items-center justify-center rounded-xl bg-charcoal text-sm font-semibold text-ivory">ك</span><span className="text-sm font-semibold">{orgName ?? "مساحة العمل"}</span></Link><button onClick={onClose} aria-label="إغلاق القائمة" className="rounded-lg p-1.5 text-charcoal/40 hover:bg-paper lg:hidden"><X size={18} /></button></div>
      <nav className="flex-1 overflow-y-auto"><p className="mb-3 px-3 text-[0.625rem] font-medium text-charcoal/30">القائمة</p><NavLink href="/dashboard" active={pathname === "/dashboard"} onNavigate={onClose}><LayoutGrid size={17} />الرئيسية</NavLink><p className="mb-3 mt-8 px-3 text-[0.625rem] font-medium text-charcoal/30">الوحدات</p>{visibleModules.map((m) => { const Icon = ICONS[m.icon as keyof typeof ICONS]; return <NavLink key={m.key} href={m.href} active={pathname.startsWith(m.href)} onNavigate={onClose}><Icon size={17} />{m.label}</NavLink>; })}{showOrders && <NavLink href="/dashboard/warehouse-orders" active={pathname.startsWith("/dashboard/warehouse-orders")} onNavigate={onClose}><ClipboardCheck size={17} />أوامر المخزن{pendingOrders > 0 && <span className="mr-auto rounded-full bg-brass px-1.5 text-[0.6875rem] text-white">{pendingOrders}</span>}</NavLink>}{showShortages && <NavLink href="/dashboard/shortages" active={pathname.startsWith("/dashboard/shortages")} onNavigate={onClose}><PackageX size={17} />بلاغات النقص{shortageBadge > 0 && <span className="mr-auto rounded-full bg-brass px-1.5 text-[0.6875rem] text-white">{shortageBadge}</span>}</NavLink>}</nav>
      <div className="border-t border-borderSoft pt-4"><Link href="/" onClick={onClose} className="flex items-center gap-3 rounded-xl px-3 py-2.5 text-xs text-charcoal/45 hover:bg-paper hover:text-charcoal"><Globe size={17} />الصفحة التعريفية</Link>{role === "owner" && <Link href="/dashboard/settings" onClick={onClose} className="flex items-center gap-3 rounded-xl px-3 py-2.5 text-xs text-charcoal/45 hover:bg-paper hover:text-charcoal"><Settings2 size={17} />الإعدادات</Link>}<SignOutForm /></div>
    </aside>
  </>;
}

function NavLink({ href, active, onNavigate, children }: { href: string; active: boolean; onNavigate: () => void; children: React.ReactNode }) {
  return <Link href={href} onClick={onNavigate} className={`flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm transition-colors ${active ? "bg-sageSoft font-medium text-sage" : "text-charcoal/50 hover:bg-paper hover:text-charcoal"}`}>{children}</Link>;
}
