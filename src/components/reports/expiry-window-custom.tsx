"use client";

import { useState, useTransition } from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { ModernSelect } from "@/components/ui/select";
import { MAX_WINDOW_DAYS, toDays, windowLabel } from "@/lib/expiry-window";
import { startNavigation } from "@/lib/navigation-state";

// "Other…": any number of days, months or years (e.g. 18 months, 4 years).
// The button always answers: a message when the number is missing or wrong, a busy state while the report loads.
export function ExpiryWindowCustom() {
  const router = useRouter();
  const pathname = usePathname();
  const sp = useSearchParams();
  const [value, setValue] = useState("");
  const [unit, setUnit] = useState<"day" | "month" | "year">("year");
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function apply() {
    const n = Number(value);
    if (value.trim() === "" || !Number.isFinite(n) || n <= 0) {
      setError("اكتب رقمًا أكبر من صفر، ثم اختر اليوم أو الشهر أو السنة.");
      return;
    }
    const days = toDays(n, unit);
    setError(null);
    const p = new URLSearchParams(sp.toString());
    p.set("days", String(days));
    p.delete("page");
    const href = `${pathname}?${p.toString()}`;
    startNavigation(href);
    startTransition(() => router.push(href, { scroll: false }));
    // a value past the limit is shortened to it; say so instead of silently changing it
    if (n * (unit === "year" ? 365 : unit === "month" ? 30 : 1) > MAX_WINDOW_DAYS) {
      setError(`الحد الأقصى ${windowLabel(MAX_WINDOW_DAYS)}؛ تم تطبيق ${windowLabel(MAX_WINDOW_DAYS)}.`);
    }
  }

  return (
    <div>
      <div className="flex flex-wrap items-center gap-1.5">
        <input
          type="number"
          min="1"
          step="1"
          inputMode="numeric"
          dir="ltr"
          value={value}
          onChange={(e) => { setValue(e.target.value); setError(null); }}
          onKeyDown={(e) => e.key === "Enter" && apply()}
          placeholder="مدة أخرى"
          aria-label="مدة أخرى"
          aria-invalid={error ? true : undefined}
          className={`h-9 w-28 rounded-lg border bg-white px-2.5 text-xs text-charcoal outline-none focus:border-sage ${error ? "border-rose" : "border-borderSoft"}`}
        />
        <div className="w-24">
          <ModernSelect
            value={unit}
            onChange={(v) => setUnit((v || "year") as "day" | "month" | "year")}
            allowClear={false}
            options={[{ value: "day", label: "يوم" }, { value: "month", label: "شهر" }, { value: "year", label: "سنة" }]}
          />
        </div>
        <button
          type="button"
          onClick={apply}
          disabled={pending}
          className="h-9 min-w-[5.5rem] cursor-pointer rounded-lg bg-charcoal px-3 text-xs font-medium text-ivory hover:bg-charcoal/90 disabled:cursor-wait disabled:opacity-60"
        >
          {pending ? "جارٍ التطبيق..." : "تطبيق"}
        </button>
      </div>
      {error && <p role="alert" className="mt-1.5 text-xs text-rose">{error}</p>}
    </div>
  );
}
