"use client";

import { useState, useTransition } from "react";
import { toggleModule } from "./actions";
import { Spinner } from "@/components/ui/spinner";
import type { ModuleKey } from "@/lib/modules";

export function ModuleToggleRow({ moduleKey, label, initialEnabled, locked = false }: { moduleKey: ModuleKey; label: string; initialEnabled: boolean; locked?: boolean }) {
  const [enabled, setEnabled] = useState(initialEnabled);
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  // A module outside the package cannot be switched on (a module that is already on can still be switched off).
  const blocked = locked && !enabled;

  function toggle() {
    if (blocked) return;
    const next = !enabled;
    setEnabled(next);
    setError(null);
    startTransition(async () => {
      const result = await toggleModule(moduleKey, next);
      if (result.error) {
        setEnabled(!next);
        setError(result.error);
      }
    });
  }

  return (
    <div className="flex items-center justify-between px-3.5 py-3 text-sm">
      <span className="text-charcoal">{label}</span>
      <div className="flex items-center gap-2.5">
        {blocked && <span className="text-[0.6875rem] text-charcoal/45">غير مشمولة في باقتك</span>}
        {error && <span className="text-[0.6875rem] text-rose">{error}</span>}
        {pending && <Spinner size={13} className="text-sage" />}
        <button
          onClick={toggle}
          disabled={pending || blocked}
          role="switch"
          aria-checked={enabled}
          aria-label={label}
          className={`relative h-6 w-11 rounded-full transition-colors disabled:opacity-50 ${blocked ? "cursor-not-allowed" : ""} ${enabled ? "bg-sage" : "bg-borderSoft"}`}
        >
          <span className={`absolute top-0.5 h-5 w-5 rounded-full bg-white shadow-sm transition-all ${enabled ? "right-[1.375rem]" : "right-0.5"}`} />
        </button>
      </div>
    </div>
  );
}
