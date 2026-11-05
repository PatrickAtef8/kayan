"use client";

import { useEffect } from "react";
import * as Sentry from "@sentry/browser";

// Last line of defence: an error in the ROOT layout itself. It replaces the whole document, so it carries its own <html> and <body> and
// uses plain inline styles (no CSS, fonts or components that might be what failed).
export default function GlobalError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => { Sentry.captureException(error); }, [error]);
  return (
    <html lang="ar" dir="rtl">
      <body style={{ margin: 0, fontFamily: "Tahoma, Arial, sans-serif", background: "#F7F6F2", color: "#1C1C1A" }}>
        <div role="alert" style={{ maxWidth: 420, margin: "0 auto", padding: "96px 20px", textAlign: "center" }}>
          <h1 style={{ fontSize: 22 }}>حدث خطأ غير متوقع</h1>
          <p style={{ color: "#6B6B66", lineHeight: 1.9, fontSize: 14 }}>تعذّر تحميل التطبيق. جرّب مرة أخرى، وإن تكرر الأمر تواصل معنا.</p>
          {error.digest && <p dir="ltr" style={{ fontSize: 12, color: "#999" }}>{error.digest}</p>}
          <button type="button" onClick={reset} style={{ background: "#344E41", color: "#fff", border: 0, borderRadius: 10, padding: "12px 24px", fontSize: 15, cursor: "pointer" }}>حاول مرة أخرى</button>
        </div>
      </body>
    </html>
  );
}
