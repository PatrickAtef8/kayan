"use client";

import { useState } from "react";
import { useRouter, usePathname, useSearchParams } from "next/navigation";
import { startNavigation } from "@/lib/navigation-state";

export function DateRangeFilter({ from, to }: { from?: string; to?: string }) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  // Show the picked date immediately; the server value catches up when the page arrives.
  const [values, setValues] = useState({ from: from ?? "", to: to ?? "" });
  const [prevRange, setPrevRange] = useState({ from, to });
  if (from !== prevRange.from || to !== prevRange.to) {
    setPrevRange({ from, to });
    setValues({ from: from ?? "", to: to ?? "" });
  }

  function setParam(key: "from" | "to", value: string) {
    setValues((current) => ({ ...current, [key]: value }));
    const params = new URLSearchParams(searchParams.toString());
    if (value) params.set(key, value);
    else params.delete(key);
    params.delete("page");
    const href = `${pathname}?${params.toString()}`;
    startNavigation(href);
    router.push(href, { scroll: false });
  }

  return (
    <div className="flex w-full min-w-0 items-center gap-2 sm:w-auto">
      <input
        type="date"
        dir="ltr"
        value={values.from}
        onChange={(e) => setParam("from", e.target.value)}
        className="h-10 min-w-0 flex-1 rounded-xl border border-borderSoft bg-white px-2.5 text-xs text-charcoal outline-none focus:border-sage sm:w-auto sm:flex-none"
      />
      <span className="text-xs text-charcoal/30">إلى</span>
      <input
        type="date"
        dir="ltr"
        value={values.to}
        onChange={(e) => setParam("to", e.target.value)}
        className="h-10 min-w-0 flex-1 rounded-xl border border-borderSoft bg-white px-2.5 text-xs text-charcoal outline-none focus:border-sage sm:w-auto sm:flex-none"
      />
    </div>
  );
}
