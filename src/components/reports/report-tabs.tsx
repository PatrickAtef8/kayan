"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { usePendingPath } from "@/components/dashboard/navigation-progress";

const TABS = [
  { href: "/dashboard/reports/sales", label: "المبيعات والربحية" },
  { href: "/dashboard/reports/inventory", label: "المخزون" },
  { href: "/dashboard/reports/debts", label: "المديونيات" },
  { href: "/dashboard/reports/customers", label: "العملاء" },
  { href: "/dashboard/reports/suppliers", label: "الموردين" },
  { href: "/dashboard/reports/reps", label: "المناديب" },
  { href: "/dashboard/reports/treasury", label: "الخزنة" },
  { href: "/dashboard/reports/position", label: "المركز المالي" },
];

const REP_TABS = ["/dashboard/reports/debts", "/dashboard/reports/reps"];

export function ReportTabs({ restrictedRep = false }: { restrictedRep?: boolean }) {
  const tabs = restrictedRep ? TABS.filter((t) => REP_TABS.includes(t.href)) : TABS;
  const pathname = usePathname();
  const pending = usePendingPath();
  // the clicked tab lights up immediately, before the new page has arrived
  const current = pending && tabs.some((t) => t.href === pending) ? pending : pathname;
  return (
    <div className="mb-7 flex flex-wrap gap-1.5 border-b border-borderSoft pb-3">
      {tabs.map((tab) => {
        const active = current === tab.href;
        return (
          <Link
            key={tab.href}
            href={tab.href}
            aria-current={active ? "page" : undefined}
            className={`rounded-lg px-3 py-2 text-sm font-medium transition-colors ${active ? "bg-sageSoft text-sage" : "text-charcoal/50 hover:bg-paper hover:text-charcoal"}`}
          >
            {tab.label}
          </Link>
        );
      })}
    </div>
  );
}
