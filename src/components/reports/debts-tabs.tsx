"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

// Sub-navigation of the account reports. The new views need the balance permission, so a restricted rep
// (who only gets the existing debts page) is not shown them.
const TABS = [
  { href: "/dashboard/reports/debts", label: "المديونيات", repOk: true },
  { href: "/dashboard/reports/debts/by-rep", label: "العملاء حسب المندوب", repOk: false },
  { href: "/dashboard/reports/debts/supplier-dues", label: "استحقاقات الموردين", repOk: false },
  { href: "/dashboard/reports/debts/payments", label: "سجل المدفوعات", repOk: false },
  { href: "/dashboard/reports/debts/supplier-items", label: "أصناف الموردين", repOk: false },
];

export function DebtsTabs({ restrictedRep = false }: { restrictedRep?: boolean }) {
  const pathname = usePathname();
  const tabs = restrictedRep ? TABS.filter((t) => t.repOk) : TABS;
  if (tabs.length < 2) return null;
  return (
    <div className="no-print mb-6 flex flex-wrap gap-1.5">
      {tabs.map((tab) => {
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
