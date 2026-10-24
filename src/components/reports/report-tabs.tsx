"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { usePendingPath } from "@/components/dashboard/navigation-progress";

const TABS = [
  { href: "/dashboard/reports/sales", label: "المبيعات والربحية" },
  { href: "/dashboard/reports/profit-loss", label: "الأرباح والخسائر" },
  { href: "/dashboard/reports/inventory", label: "المخزون" },
  { href: "/dashboard/reports/debts", label: "المديونيات" },
  { href: "/dashboard/reports/customers", label: "العملاء" },
  { href: "/dashboard/reports/suppliers", label: "الموردين" },
  { href: "/dashboard/reports/reps", label: "المناديب" },
  { href: "/dashboard/reports/payroll", label: "المرتبات" },
  { href: "/dashboard/reports/expenses", label: "المصروفات" },
  { href: "/dashboard/reports/returns", label: "المرتجعات" },
  { href: "/dashboard/reports/treasury", label: "الخزنة" },
  { href: "/dashboard/reports/position", label: "المركز المالي" },
];

// What each role may open. The database refuses everything else; this only keeps the tabs honest.
const REP_TABS = ["/dashboard/reports/sales", "/dashboard/reports/debts", "/dashboard/reports/customers", "/dashboard/reports/reps", "/dashboard/reports/returns"];
const KEEPER_TABS = ["/dashboard/reports/inventory"];

// Wording that says whose numbers these are, so nobody mistakes them for company figures.
const REP_LABELS: Record<string, string> = {
  "/dashboard/reports/sales": "مبيعات عملائي",
  "/dashboard/reports/debts": "مديونيات عملائي",
  "/dashboard/reports/customers": "عملائي",
  "/dashboard/reports/reps": "أدائي وعمولتي",
  "/dashboard/reports/returns": "مرتجعات عملائي",
};
const KEEPER_LABELS: Record<string, string> = { "/dashboard/reports/inventory": "المخزون (الكميات)" };

export function ReportTabs({ role = "owner" }: { role?: "owner" | "sales" | "warehouse" }) {
  const labels = role === "sales" ? REP_LABELS : role === "warehouse" ? KEEPER_LABELS : {};
  const tabs = (role === "sales" ? TABS.filter((t) => REP_TABS.includes(t.href)) : role === "warehouse" ? TABS.filter((t) => KEEPER_TABS.includes(t.href)) : TABS).map((t) => ({ ...t, label: labels[t.href] ?? t.label }));
  const pathname = usePathname();
  const pending = usePendingPath();
  // the clicked tab lights up immediately, before the new page has arrived
  const current = pending && tabs.some((t) => t.href === pending) ? pending : pathname;
  return (
    <div className="mb-7 flex flex-wrap gap-1.5 border-b border-borderSoft pb-3">
      {tabs.map((tab) => {
        const active = current === tab.href || current.startsWith(tab.href + "/");
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
