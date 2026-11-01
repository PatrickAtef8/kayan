"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import clsx from "clsx";
import { usePendingPath } from "@/components/dashboard/navigation-progress";

const ITEMS = [
  { href: "/admin", label: "نظرة عامة", exact: true },
  { href: "/admin/companies", label: "الشركات" },
  { href: "/admin/users", label: "المستخدمون" },
  { href: "/admin/packages", label: "الباقات والأسعار" },
  { href: "/admin/legal", label: "الصفحات القانونية" },
];

export function AdminNav() {
  const current = usePathname();
  const pending = usePendingPath();
  const path = pending ?? current;   // the clicked tab lights up at once, before the server answers
  return (
    <nav aria-label="إدارة المنصة" className="-mx-1 flex gap-1 overflow-x-auto px-1 pb-1">
      {ITEMS.map((i) => {
        const on = i.exact ? path === i.href : path.startsWith(i.href);
        return <Link key={i.href} href={i.href} aria-current={on ? "page" : undefined} className={clsx("whitespace-nowrap rounded-xl px-3.5 py-2 text-sm transition-colors", on ? "bg-sageSoft font-medium text-sage" : "text-charcoal/55 hover:bg-white hover:text-charcoal")}>{i.label}</Link>;
      })}
    </nav>
  );
}
