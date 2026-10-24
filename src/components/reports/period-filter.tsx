"use client";

import Link from "next/link";
import { usePathname, useSearchParams } from "next/navigation";
import { DateRangeFilter } from "@/components/ui/date-range-filter";

// Date range + "this month" + "all periods" for reports that have no other filter. Everything is a URL param.
export function PeriodFilter({ from, to, all }: { from: string | null; to: string | null; all: boolean }) {
  const pathname = usePathname();
  const sp = useSearchParams();
  const href = (patch: (p: URLSearchParams) => void) => {
    const p = new URLSearchParams(sp.toString());
    p.delete("from");
    p.delete("to");
    p.delete("all");
    patch(p);
    const q = p.toString();
    return q ? `${pathname}?${q}` : pathname;
  };
  return (
    <div className="no-print mb-5 flex flex-wrap items-center gap-2">
      <DateRangeFilter from={all ? undefined : (from ?? undefined)} to={all ? undefined : (to ?? undefined)} />
      <Link href={href(() => {})} scroll={false} className="rounded-lg bg-paper px-2.5 py-1.5 text-xs text-charcoal/60 hover:text-charcoal">هذا الشهر</Link>
      <Link href={href((p) => p.set("all", "1"))} scroll={false} className={`rounded-lg px-2.5 py-1.5 text-xs ${all ? "bg-charcoal text-ivory" : "bg-paper text-charcoal/60 hover:text-charcoal"}`}>كل الفترات</Link>
    </div>
  );
}
