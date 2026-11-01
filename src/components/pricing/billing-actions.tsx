"use client";

import { useState, useTransition } from "react";
import { ArrowLeft, TriangleAlert } from "lucide-react";
import { Spinner } from "@/components/ui/spinner";
import { startRenewal, retryOrder, type CheckoutActionResult } from "@/app/dashboard/billing/actions";

// A button that asks the server for a payment page and sends the browser there. Used for «جدّد الآن» and «حاول مرة أخرى».
export function PayButton({ kind, orderId, children, variant = "primary" }: { kind: "renew" | "retry"; orderId?: string; children: React.ReactNode; variant?: "primary" | "secondary" }) {
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const [leaving, setLeaving] = useState(false);
  const busy = pending || leaving;
  function go() {
    if (busy) return;
    setError(null);
    start(async () => {
      let r: CheckoutActionResult;
      try { r = kind === "renew" ? await startRenewal() : await retryOrder(orderId ?? ""); }
      catch { setError("تعذّر الاتصال بالخادم. لم يُخصم أي مبلغ — حاول مرة أخرى."); return; }
      if (r.error || !r.url) { setError(r.error ?? "تعذّر بدء عملية الدفع."); return; }
      setLeaving(true);
      window.location.assign(r.url);
    });
  }
  return (
    <div>
      <button type="button" onClick={go} disabled={busy}
        className={`inline-flex items-center justify-center gap-2 rounded-xl px-5 py-2.5 text-sm font-medium transition-all duration-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sage/40 disabled:cursor-not-allowed disabled:opacity-60 active:scale-[0.98] ${variant === "primary" ? "bg-charcoal text-ivory hover:bg-sage" : "border border-borderSoft bg-white text-charcoal hover:border-sage"}`}>
        {busy ? <><Spinner />جارٍ تجهيز الدفع…</> : <>{children}<ArrowLeft size={15} /></>}
      </button>
      {error && <p role="alert" className="mt-2 flex items-start gap-2 text-sm text-rose"><TriangleAlert size={15} className="mt-0.5 shrink-0" />{error}</p>}
    </div>
  );
}
