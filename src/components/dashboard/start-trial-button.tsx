"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Gift, TriangleAlert } from "lucide-react";
import { Spinner } from "@/components/ui/spinner";
import { startFreeTrial } from "@/app/dashboard/billing/actions";

// «ابدأ التجربة المجانية» for the owner of a company that has not paid and has not used a trial. The SERVER decides everything (who the
// company is, whether a trial is allowed, how long it lasts); this button only asks, and reloads the dashboard when the answer is yes.
export function StartTrialButton({ label, className }: { label: string; className?: string }) {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  function go() {
    if (pending) return;
    setError(null);
    start(async () => {
      try {
        const r = await startFreeTrial();
        if (r.error) { setError(r.error); return; }
        router.push("/dashboard");
        router.refresh();
      } catch { setError("تعذّر الاتصال بالخادم. حاول مرة أخرى."); }
    });
  }
  return (
    <div>
      <button type="button" onClick={go} disabled={pending}
        className={className ?? "inline-flex items-center justify-center gap-2 rounded-xl bg-sage px-6 py-3 text-sm font-medium text-ivory transition-colors hover:bg-charcoal disabled:cursor-not-allowed disabled:opacity-60"}>
        {pending ? <><Spinner />جارٍ التفعيل…</> : <><Gift size={16} />{label}</>}
      </button>
      {error && <p role="alert" className="mt-3 flex items-start justify-center gap-2 text-sm text-rose"><TriangleAlert size={15} className="mt-0.5 shrink-0" />{error}</p>}
    </div>
  );
}
