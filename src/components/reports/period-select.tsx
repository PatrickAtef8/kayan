"use client";

import { useEffect, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { startNavigation } from "@/lib/navigation-state";
import { ModernSelect } from "@/components/ui/select";
import { PERIOD_OPTIONS, type ReportPeriod } from "@/lib/report-period";

// Swaps the `period` query param while keeping every other param (tab,
// group, party, …) exactly as it is — each report page reads searchParams
// itself, so this component never needs to know what page it's on.
export function PeriodSelect({ period }: { period: ReportPeriod }) {
  const router = useRouter();
  const searchParams = useSearchParams();
  // Show the chosen period immediately; the server value catches up when the report arrives.
  const [selected, setSelected] = useState<string>(period);
  useEffect(() => setSelected(period), [period]);

  function setPeriod(value: string) {
    setSelected(value);
    const params = new URLSearchParams(searchParams.toString());
    params.set("period", value);
    const href = `?${params.toString()}`;
    startNavigation(href);
    router.push(href, { scroll: false });
  }

  return (
    <div className="w-40 shrink-0">
      <ModernSelect value={selected} onChange={setPeriod} allowClear={false} options={PERIOD_OPTIONS} />
    </div>
  );
}
