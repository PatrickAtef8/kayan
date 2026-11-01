"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { ArrowLeft, TriangleAlert } from "lucide-react";
import { Spinner } from "@/components/ui/spinner";
import { startPurchase, startRenewal, type CheckoutActionResult } from "@/app/dashboard/billing/actions";

// «متابعة إلى الدفع». It asks the SERVER for a payment page and sends the browser there. What is bought is NOT decided here: only the
// package key and option the customer picked are sent (a renewal sends neither — the server reads them from the company's own license).
// The price, amount and duration are rebuilt on the server. The required checkbox sends the versions of the Terms / Privacy / Refund
// policies that were DISPLAYED; the server compares them with the database, refuses stale ones, and records what it read.
export type LegalVersionsProp = { terms: number; privacy: number; refund: number };
type Props = { legal: LegalVersionsProp | null; disabled?: boolean; children: React.ReactNode } & (
  | { kind: "purchase"; packageKey: string; option: string }
  | { kind: "renew" }
);

export function CheckoutButton(props: Props) {
  const [accepted, setAccepted] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const [leaving, setLeaving] = useState(false);
  const busy = pending || leaving;
  const blocked = props.disabled || !props.legal;
  function go() {
    if (busy || blocked) return;
    if (!accepted) { setError("يلزم الموافقة على الشروط والأحكام وسياسة الخصوصية وسياسة الإلغاء والاسترداد قبل المتابعة."); return; }
    setError(null);
    start(async () => {
      let r: CheckoutActionResult;
      try {
        r = props.kind === "purchase" ? await startPurchase({ packageKey: props.packageKey, option: props.option, accept: props.legal })
          : await startRenewal({ accept: props.legal });
      } catch { setError("تعذّر الاتصال بالخادم. لم يُخصم أي مبلغ — تحقّق من الاتصال وحاول مرة أخرى."); return; }
      if (r.error || !r.url) { setError(r.error ?? "تعذّر بدء عملية الدفع."); return; }
      setLeaving(true);                           // keep the spinner while the browser leaves for XPay
      window.location.assign(r.url);
    });
  }
  const link = "font-medium text-charcoal underline underline-offset-4 hover:text-sage";
  return (
    <div>
      <label className="flex cursor-pointer items-start gap-2.5 text-sm leading-6 text-charcoal/75">
        <input type="checkbox" checked={accepted} onChange={(e) => { setAccepted(e.target.checked); if (e.target.checked) setError(null); }} disabled={blocked}
          aria-required="true" aria-describedby="legal-links" className="mt-1.5 h-4 w-4 shrink-0 accent-[#344E41]" />
        <span id="legal-links">
          أوافق على <Link href="/terms" target="_blank" className={link}>الشروط والأحكام</Link> و<Link href="/privacy" target="_blank" className={link}>سياسة الخصوصية</Link> و<Link href="/refund-policy" target="_blank" className={link}>سياسة الإلغاء والاسترداد</Link>
          <span className="block text-xs text-charcoal/45">(تُفتح في صفحة جديدة · <Link href="/terms?lang=en" target="_blank" className="underline underline-offset-2">English</Link>)</span>
        </span>
      </label>
      <button type="button" onClick={go} disabled={busy || blocked || !accepted}
        className="mt-4 flex w-full items-center justify-center gap-2.5 rounded-xl bg-charcoal px-5 py-3.5 text-sm font-medium text-ivory transition-all duration-200 hover:bg-sage focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sage/40 disabled:cursor-not-allowed disabled:opacity-50 active:scale-[0.99]">
        {busy ? <><Spinner />{leaving ? "جارٍ تحويلك إلى صفحة الدفع الآمنة…" : "جارٍ تجهيز الدفع…"}</> : <>{props.children}<ArrowLeft size={16} /></>}
      </button>
      {error && <p role="alert" className="mt-3 flex items-start gap-2 text-sm text-rose"><TriangleAlert size={15} className="mt-0.5 shrink-0" />{error}</p>}
    </div>
  );
}
