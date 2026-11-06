"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Spinner } from "@/components/ui/spinner";
import { extendTrial } from "@/app/admin/actions";
import { isValidTrialDays } from "@/lib/billing/trial";

// Give one company more trial days (counted from today when the trial already ended, which re-opens the company).
export function ExtendTrial({ orgId }: { orgId: string }) {
  const router = useRouter();
  const [days, setDays] = useState("7");
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const n = Number(days);
  const valid = days.trim() !== "" && isValidTrialDays(n);
  function go() {
    setMsg(null);
    start(async () => {
      try {
        const r = await extendTrial(orgId, n);
        setMsg(r.error ? { ok: false, text: r.error } : { ok: true, text: r.message ?? "تم." });
        if (!r.error) router.refresh();
      } catch { setMsg({ ok: false, text: "تعذّر الاتصال بالخادم." }); }
    });
  }
  return (
    <div>
      <div className="flex flex-wrap items-center gap-2">
        <input inputMode="numeric" value={days} onChange={(e) => setDays(e.target.value)} aria-label="عدد أيام التمديد" className="num w-20 rounded-xl border border-borderSoft bg-white px-3 py-2 text-sm outline-none focus:border-sage" />
        <button type="button" onClick={go} disabled={pending || !valid} className="inline-flex items-center gap-2 rounded-xl border border-borderSoft bg-white px-4 py-2 text-sm font-medium hover:border-sage disabled:cursor-not-allowed disabled:opacity-50">{pending ? <><Spinner />جارٍ التمديد…</> : "تمديد التجربة (أيام)"}</button>
      </div>
      {msg && <p role="alert" className={`mt-2 text-xs ${msg.ok ? "text-sage" : "text-rose"}`}>{msg.text}</p>}
    </div>
  );
}
