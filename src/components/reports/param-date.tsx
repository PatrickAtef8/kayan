"use client";

import { useRouter, usePathname, useSearchParams } from "next/navigation";
import { startNavigation } from "@/lib/navigation-state";

// A date that lives in the URL (?as_of=2026-10-25). It applies the moment a date is picked — no apply button — and
// shows the top progress bar while the report reloads. Clearing it goes back to the default (today).
export function ParamDate({ param, value, label }: { param: string; value: string; label: string }) {
  const router = useRouter();
  const pathname = usePathname();
  const sp = useSearchParams();

  function change(next: string) {
    const params = new URLSearchParams(sp.toString());
    if (next) params.set(param, next);
    else params.delete(param);
    params.delete("page");
    const href = `${pathname}?${params.toString()}`;
    startNavigation(href);
    router.push(href, { scroll: false });
  }

  return (
    <label className="block text-xs text-charcoal/50">
      {label}
      <input
        type="date"
        value={value}
        onChange={(e) => change(e.target.value)}
        dir="ltr"
        className="mt-1 block h-10 w-full min-w-0 rounded-xl border border-borderSoft bg-white px-3 text-sm text-charcoal focus:border-sage focus:outline-none sm:w-auto"
      />
    </label>
  );
}
