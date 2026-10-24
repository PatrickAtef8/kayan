"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

// Sub-navigation for the inventory reports. New inventory reports (expiry,
// stocktake — later phases) are added here.
const TABS = [
  { href: "/dashboard/reports/inventory", label: "أرصدة المخزون" },
  { href: "/dashboard/reports/inventory/reorder", label: "حد الطلب (النواقص)" },
  { href: "/dashboard/reports/inventory/movement", label: "حركة الأصناف" },
  { href: "/dashboard/reports/inventory/expiry", label: "الصلاحية" },
];

export function InventoryTabs() {
  const pathname = usePathname();
  return (
    <div className="no-print mb-6 flex flex-wrap gap-1.5">
      {TABS.map((tab) => {
        const active = pathname === tab.href;
        return (
          <Link
            key={tab.href}
            href={tab.href}
            aria-current={active ? "page" : undefined}
            className={`rounded-lg px-2.5 py-1.5 text-xs font-medium transition-colors ${active ? "bg-charcoal text-ivory" : "bg-paper text-charcoal/50 hover:text-charcoal"}`}
          >
            {tab.label}
          </Link>
        );
      })}
    </div>
  );
}
