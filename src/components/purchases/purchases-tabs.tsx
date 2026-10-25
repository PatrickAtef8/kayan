"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

export function PurchasesTabs() {
  const pathname = usePathname();
  const tabs = [
    { href: "/dashboard/purchases", label: "فواتير الشراء" },
    { href: "/dashboard/purchases/returns", label: "المرتجعات" },
  ];

  return (
    <div className="mb-6 flex flex-wrap gap-1.5 border-b border-borderSoft pb-3">
      {tabs.map((tab) => {
        const active = pathname === tab.href;
        return (
          <Link
            key={tab.href}
            href={tab.href}
            className={`rounded-lg px-3 py-2 text-sm font-medium transition-colors ${active ? "bg-sageSoft text-sage" : "text-charcoal/50 hover:bg-paper hover:text-charcoal"}`}
          >
            {tab.label}
          </Link>
        );
      })}
    </div>
  );
}
