"use client";

import { PeriodPicker } from "@/components/ui/period-picker";
import type { PeriodSel } from "@/lib/report-period";

// Month / year / all-time picker for the reports that filter by `period`. The picker swaps only the
// period params (period, m, y) and keeps every other param (tab, group, party, …) exactly as it is.
export function PeriodSelect({ period, monthOnly = false }: { period: PeriodSel; monthOnly?: boolean }) {
  return (
    <div className="w-48 shrink-0">
      <PeriodPicker sel={period} monthOnly={monthOnly} />
    </div>
  );
}
