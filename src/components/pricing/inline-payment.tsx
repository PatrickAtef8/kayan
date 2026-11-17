"use client";
import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import { Lock, ShieldCheck, TriangleAlert } from "lucide-react";
import { mountInlineCheckout, successPath } from "@/lib/billing/xpay-sdk";

// The payment form on Kayan's own /checkout/pay page. XPay's form (cards, ValU, Fawry, Apple Pay, 3-D Secure) is mounted INSIDE this page, so the customer
// never leaves Kayan and Kayan never sees card data. When XPay reports a finished payment the browser goes to Kayan's result page, which asks XPay what
// really happened (the webhook stays the only thing that marks an order paid). Anything that goes wrong shows a calm message; nothing is charged by a failed load.
type Phase = "loading" | "ready" | "confirming" | "failed";
const SLOW_MS = 25_000;   // no form after this long: say so instead of showing a skeleton forever

export function InlinePayment({ publishableKey, clientSecret, orderId, testMode, backHref }: { publishableKey: string; clientSecret: string; orderId: string; testMode: boolean; backHref: string }) {
  const host = useRef<HTMLDivElement>(null);
  const [phase, setPhase] = useState<Phase>("loading");
  const [attempt, setAttempt] = useState(0);
  const [notice, setNotice] = useState<string | null>(null);

  useEffect(() => {
    const container = host.current;
    if (!container) return;
    let cancelled = false;
    let handle: { destroy(): void } | null = null;
    const slow = setTimeout(() => { if (!cancelled) setPhase((p) => (p === "loading" ? "failed" : p)); }, SLOW_MS);
    // one tick later: React's development double-mount (mount, clean up, mount) then never starts two forms in the same container
    const start = setTimeout(() => mountInlineCheckout({
      publishableKey, clientSecret, container,
      onReady: () => { clearTimeout(slow); if (!cancelled) setPhase("ready"); },
      onComplete: () => { if (!cancelled) { setPhase("confirming"); window.location.assign(successPath(orderId)); } },
      onError: () => { if (!cancelled) setNotice("لم تكتمل هذه المحاولة. يمكنك المحاولة مرة أخرى من النموذج أعلاه، ولا يُخصم أي مبلغ لم يُؤكَّد."); },
    })
      .then((h) => { if (cancelled) h.destroy(); else handle = h; })
      .catch(() => { clearTimeout(slow); if (!cancelled) setPhase("failed"); }), 0);
    return () => { cancelled = true; clearTimeout(start); clearTimeout(slow); handle?.destroy(); container.replaceChildren(); };
  }, [publishableKey, clientSecret, orderId, attempt]);

  const retry = () => { setPhase("loading"); setNotice(null); setAttempt((a) => a + 1); };

  return (
    <div>
      {testMode && <p className="mb-4 bg-amber-50 px-3 py-2 text-xs text-amber-800">وضع تجريبي: لن يُخصم أي مبلغ حقيقي. استخدم بطاقة اختبار من XPay.</p>}

      <div className="relative min-h-[16rem]">
        <div ref={host} className={phase === "failed" ? "hidden" : ""} />

        {phase === "loading" && (
          <div aria-hidden className="absolute inset-x-0 top-0 animate-pulse space-y-3">
            <div className="h-14 rounded-xl bg-ivory" />
            <div className="h-14 rounded-xl bg-ivory" />
            <div className="h-14 rounded-xl bg-ivory" />
            <div className="h-12 rounded-xl bg-sageSoft/70" />
          </div>
        )}

        {phase === "failed" && (
          <div role="alert" className="flex flex-col items-center px-2 py-8 text-center">
            <span className="flex h-12 w-12 items-center justify-center rounded-full bg-rose/10 text-rose"><TriangleAlert size={22} /></span>
            <h3 className="mt-4 text-base font-semibold text-charcoal">تعذّر تحميل نموذج الدفع</h3>
            <p className="mt-2 max-w-sm text-sm leading-7 text-charcoal/60">تحقّق من الاتصال بالإنترنت، وأوقف مانع الإعلانات لهذه الصفحة إن وُجد، ثم أعد المحاولة. لم يُخصم أي مبلغ.</p>
            <div className="mt-5 flex flex-wrap justify-center gap-3">
              <button type="button" onClick={retry} className="rounded-xl bg-charcoal px-5 py-2.5 text-sm font-medium text-ivory hover:bg-sage">إعادة المحاولة</button>
              <Link href={backHref} className="rounded-xl border border-borderSoft bg-white px-5 py-2.5 text-sm font-medium text-charcoal hover:border-sage">العودة إلى الطلب</Link>
            </div>
          </div>
        )}

        {phase === "confirming" && (
          <div role="status" aria-live="polite" className="absolute inset-0 z-10 flex flex-col items-center justify-center gap-3 bg-white/92 text-center">
            <span className="h-7 w-7 animate-spin rounded-full border-2 border-sage/25 border-t-sage" />
            <p className="text-sm font-medium text-charcoal">تم استلام الدفع… جارٍ تأكيد اشتراكك</p>
            <p className="text-xs text-charcoal/50">لا تغلق هذه الصفحة.</p>
          </div>
        )}
      </div>

      {notice && <p role="status" className="mt-3 text-sm leading-6 text-charcoal/65">{notice}</p>}

      <ul className="mt-6 flex flex-wrap gap-x-5 gap-y-2 border-t border-borderSoft pt-4 text-xs text-charcoal/50">
        <li className="flex items-center gap-1.5"><Lock size={13} className="shrink-0" />اتصال مشفّر</li>
        <li className="flex items-center gap-1.5"><ShieldCheck size={13} className="shrink-0" />تحقّق 3D Secure للبطاقات</li>
        <li className="basis-full leading-5 sm:basis-auto">بيانات بطاقتك تُدخل في نموذج XPay المحمي، ولا تصل إلى خوادم كيان.</li>
      </ul>
    </div>
  );
}
