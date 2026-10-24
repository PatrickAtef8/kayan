"use client";

import Link from "next/link";
import { usePathname, useSearchParams } from "next/navigation";
import { DateRangeFilter } from "@/components/ui/date-range-filter";
import { ParamSelect } from "@/components/reports/param-select";
import { CHANNELS } from "@/lib/sales-report";

// Date range + warehouse (+ rep, + channel where they apply). Everything is a URL param, so a filtered
// view can be bookmarked and the sub-tabs keep it.
export function SalesReportFilters({
  from,
  to,
  all,
  warehouse,
  rep,
  channel,
  warehouses,
  reps,
  showRep = true,
  showChannel = true,
}: {
  from: string | null;
  to: string | null;
  all: boolean;
  warehouse: string | null;
  rep: string | null;
  channel: string | null;
  warehouses: { id: string; name: string }[];
  reps: { id: string; name: string }[];
  showRep?: boolean;
  showChannel?: boolean;
}) {
  const pathname = usePathname();
  const sp = useSearchParams();
  const allHref = (() => {
    const p = new URLSearchParams(sp.toString());
    p.delete("from");
    p.delete("to");
    p.set("all", "1");
    return `${pathname}?${p.toString()}`;
  })();
  const monthHref = (() => {
    const p = new URLSearchParams(sp.toString());
    p.delete("from");
    p.delete("to");
    p.delete("all");
    const q = p.toString();
    return q ? `${pathname}?${q}` : pathname;
  })();

  return (
    <div className="no-print mb-6 flex flex-wrap items-center gap-2">
      <DateRangeFilter from={all ? undefined : (from ?? undefined)} to={all ? undefined : (to ?? undefined)} />
      <Link href={monthHref} scroll={false} className="rounded-lg bg-paper px-2.5 py-1.5 text-xs text-charcoal/60 hover:text-charcoal">هذا الشهر</Link>
      <Link href={allHref} scroll={false} className={`rounded-lg px-2.5 py-1.5 text-xs ${all ? "bg-charcoal text-ivory" : "bg-paper text-charcoal/60 hover:text-charcoal"}`}>كل الفترات</Link>
      <ParamSelect param="warehouse" value={warehouse ?? ""} placeholder="كل المخازن" clearLabel="كل المخازن" options={warehouses.map((w) => ({ value: w.id, label: w.name }))} />
      {showRep && reps.length > 0 && (
        <ParamSelect param="rep" value={rep ?? ""} placeholder="كل المناديب" clearLabel="كل المناديب" options={reps.map((r) => ({ value: r.id, label: r.name }))} />
      )}
      {showChannel && <ParamSelect param="channel" value={channel ?? ""} placeholder="كل القنوات" clearLabel="كل القنوات" options={CHANNELS} />}
    </div>
  );
}
