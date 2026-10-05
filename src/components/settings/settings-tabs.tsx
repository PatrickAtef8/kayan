"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { usePendingPath } from "@/components/dashboard/navigation-progress";

const TABS = [
  { href: "/dashboard/settings/general", label: "عام" },
  { href: "/dashboard/settings/modules", label: "الوحدات" },
  { href: "/dashboard/settings/discounts", label: "خصومات الشرائح" },
  { href: "/dashboard/settings/team", label: "الفريق" },
  { href: "/dashboard/settings/audit", label: "سجل العمليات" },
];

export function SettingsTabs() {
  const pathname = usePathname();
  const pending = usePendingPath();
  // the clicked tab lights up immediately, before the new page has arrived
  const current = pending && TABS.some((t) => t.href === pending) ? pending : pathname;
  return (
    <div className="mb-7 flex flex-wrap gap-1.5 border-b border-borderSoft pb-3">
      {TABS.map((tab) => {
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
