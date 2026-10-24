"use client";

import Link from "next/link";
import { usePathname, useSearchParams } from "next/navigation";

// Sub-navigation of the sales reports. The filters live in the query string, so they follow the user
// from one view to the next (the existing overview page has its own period filter and keeps its URL).
const TABS = [
  { href: "/dashboard/reports/sales", label: "نظرة عامة", keep: false },
  { href: "/dashboard/reports/sales/by-rep", label: "حسب المندوب", keep: true },
  { href: "/dashboard/reports/sales/by-channel", label: "حسب القناة", keep: true },
  { href: "/dashboard/reports/sales/by-product", label: "حسب الصنف", keep: true },
];

export function SalesReportTabs() {
  const pathname = usePathname();
  const sp = useSearchParams();
  const keep = new URLSearchParams();
  for (const k of ["from", "to", "all", "warehouse", "rep", "channel"]) {
    const v = sp.get(k);
    if (v) keep.set(k, v);
  }
  const qs = keep.toString();
  return (
    <div className="no-print mb-6 flex flex-wrap gap-1.5">
      {TABS.map((tab) => {
        const active = pathname === tab.href;
        return (
          <Link
            key={tab.href}
            href={tab.keep && qs && pathname.startsWith("/dashboard/reports/sales/") ? `${tab.href}?${qs}` : tab.href}
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
