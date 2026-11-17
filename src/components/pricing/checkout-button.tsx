"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import Link from "next/link";
import { ArrowLeft, Lock, TriangleAlert } from "lucide-react";
import { Spinner } from "@/components/ui/spinner";
import { startPurchase, startRenewal, type CheckoutActionResult } from "@/app/dashboard/billing/actions";
import { openEmbeddedCheckout, successPath } from "@/lib/billing/xpay-sdk";

// «متابعة إلى الدفع». It asks the SERVER for a payment page. Either the server answers with an address (the browser goes there), or — when the
// in-page payment window is switched on (XPAY_PUBLISHABLE_KEY) — with the session's clientSecret, and XPay's checkout opens in a window ON this page:
// the customer never leaves Kayan. When the window reports a finished payment the browser goes to Kayan's own result page, which asks XPay what
// really happened (the webhook stays the authority). Closing the window without paying just re-enables the button: clicking again resumes the same session. What is bought is NOT decided here: only the
// plan the customer picked is sent (a renewal sends nothing — the server reads the plan from the company's own license).
// The price, amount and duration are rebuilt on the server. The required checkbox sends the versions of the Terms / Privacy / Refund
// policies that were DISPLAYED; the server compares them with the database, refuses stale ones, and records what it read.
export type LegalVersionsProp = { terms: number; privacy: number; refund: number };
type Props = { legal: LegalVersionsProp | null; disabled?: boolean; children: React.ReactNode } & (
  | { kind: "purchase"; plan: string }
  | { kind: "renew" }
);

export function CheckoutButton(props: Props) {
  const [accepted, setAccepted] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const [leaving, setLeaving] = useState(false);
  const [confirming, setConfirming] = useState(false);       // the window said «paid»: Kayan is about to show the result page
  const [windowOpen, setWindowOpen] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const handle = useRef<{ reopen(): void; destroy(): void } | null>(null);
  useEffect(() => () => { handle.current?.destroy(); }, []);
  const busy = pending || leaving || confirming;
  const blocked = props.disabled || !props.legal;
  function go() {
    if (busy || blocked) return;
    if (!accepted) { setError("يلزم الموافقة على الشروط والأحكام وسياسة الخصوصية وسياسة الإلغاء والاسترداد قبل المتابعة."); return; }
    setError(null);
    start(async () => {
      let r: CheckoutActionResult;
      try {
        r = props.kind === "purchase" ? await startPurchase({ plan: props.plan, accept: props.legal })
          : await startRenewal({ accept: props.legal });
      } catch { setError("تعذّر الاتصال بالخادم. لم يُخصم أي مبلغ — تحقّق من الاتصال وحاول مرة أخرى."); return; }
      if (r.error || (!r.url && !r.embedded)) { setError(r.error ?? "تعذّر بدء عملية الدفع."); return; }
      if (r.embedded) {
        const e = r.embedded;
        setNotice(null);
        handle.current?.destroy();
        try {
          handle.current = await openEmbeddedCheckout({
            publishableKey: e.publishableKey, clientSecret: e.clientSecret,
            onComplete: () => { setWindowOpen(false); setConfirming(true); window.location.assign(successPath(e.orderId)); },
            onClose: () => setWindowOpen(false),
            onError: () => setNotice("لم تكتمل هذه المحاولة. يمكنك المحاولة مرة أخرى من نافذة الدفع، ولم يُخصم أي مبلغ لم يُؤكَّد."),
          });
          setWindowOpen(true);
        } catch {
          setError("تعذّر تحميل نافذة الدفع الآمنة. تحقّق من الاتصال، وأوقف مانع الإعلانات لهذه الصفحة إن وُجد، ثم حاول مرة أخرى. لم يُخصم أي مبلغ.");
        }
        return;
      }
      setLeaving(true);                           // keep the spinner while the browser leaves for XPay
      window.location.assign(r.url!);
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
        {busy ? <><Spinner />{confirming ? "تم استلام الدفع… جارٍ تأكيد اشتراكك" : leaving ? "جارٍ تحويلك إلى صفحة الدفع الآمنة…" : "جارٍ تجهيز الدفع…"}</> : <>{props.children}<ArrowLeft size={16} /></>}
      </button>
      {windowOpen && !busy && (
        <p className="mt-3 flex items-center justify-center gap-2 text-xs text-charcoal/55">
          <Lock size={13} className="shrink-0" />نافذة الدفع الآمنة مفتوحة.
          <button type="button" onClick={() => handle.current?.reopen()} className="font-medium text-sage underline underline-offset-4">أعد فتحها</button>
        </p>
      )}
      {notice && <p role="status" className="mt-3 text-sm text-charcoal/65">{notice}</p>}
      {error && <p role="alert" className="mt-3 flex items-start gap-2 text-sm text-rose"><TriangleAlert size={15} className="mt-0.5 shrink-0" />{error}</p>}
    </div>
  );
}
