"use client";

import { useEffect } from "react";
import * as Sentry from "@sentry/browser";

// One friendly, Arabic error screen shared by every error boundary. It reports the error (a no-op without a Sentry DSN) and offers
// "try again" (re-renders the segment) and a way out. It never prints the error message: that can contain internals.
export function ErrorView({ error, reset, homeHref = "/", scope = "التطبيق" }: { error: Error & { digest?: string }; reset: () => void; homeHref?: string; scope?: string }) {
  useEffect(() => {
    Sentry.captureException(error);
    console.error(`[${scope}] unhandled error`, error.digest ?? "");
  }, [error, scope]);
  return (
    <div dir="rtl" role="alert" className="mx-auto flex min-h-[50vh] max-w-md flex-col items-center justify-center px-5 py-16 text-center">
      <div className="mb-5 flex h-14 w-14 items-center justify-center rounded-2xl bg-rose/10 text-2xl text-rose" aria-hidden="true">!</div>
      <h1 className="text-xl font-semibold text-charcoal">حدث خطأ غير متوقع</h1>
      <p className="mt-2 text-sm leading-7 text-charcoal/60">لم يكتمل ما كنت تفعله. بياناتك لم تتأثر. جرّب مرة أخرى، وإن تكرر الأمر تواصل معنا وأرسل الرمز أدناه.</p>
      {error.digest && <p dir="ltr" className="mt-3 rounded-lg bg-paper px-3 py-1.5 text-xs text-charcoal/50">{error.digest}</p>}
      <div className="mt-6 flex gap-2">
        <button type="button" onClick={reset} className="rounded-xl bg-charcoal px-5 py-2.5 text-sm font-medium text-ivory hover:bg-sage">حاول مرة أخرى</button>
        <a href={homeHref} className="rounded-xl border border-borderSoft px-5 py-2.5 text-sm font-medium text-charcoal hover:border-sage">{homeHref === "/" ? "الصفحة الرئيسية" : "العودة"}</a>
      </div>
    </div>
  );
}
