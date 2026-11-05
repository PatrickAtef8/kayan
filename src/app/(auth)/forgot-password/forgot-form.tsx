"use client";

import { useState } from "react";
import Link from "next/link";
import { ArrowRight, MailCheck, Mail } from "lucide-react";
import { requestPasswordReset } from "./actions";
import { AuthShell } from "@/components/auth/auth-shell";
import { AuthAlert, AuthField, AuthInput, SubmitButton } from "@/components/auth/auth-fields";

// §12: "Password reset" — request step. The server action sends the reset email (Resend) with a link to
// /reset-password; that page does the actual password change.
export function ForgotPasswordForm({ initialEmail = "" }: { initialEmail?: string }) {
  const [email, setEmail] = useState(initialEmail);
  const [error, setError] = useState<string | null>(null);
  const [sent, setSent] = useState(false);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError(null);

    const result = await requestPasswordReset(email.trim()).catch(() => ({ error: "تعذّر إرسال الطلب. حاول مرة أخرى." }));

    setLoading(false);
    if (result.error) {
      setError(result.error);
      return;
    }
    setSent(true);
  }

  if (sent) {
    return (
      <AuthShell>
        <div className="flex flex-col items-center text-center">
          <div className="mb-5 flex h-14 w-14 items-center justify-center rounded-2xl bg-sageSoft text-sage"><MailCheck size={26} strokeWidth={1.6} /></div>
          <h1 className="text-2xl font-semibold tracking-tight text-charcoal">تحقق من بريدك الإلكتروني</h1>
          <p className="mt-3 text-sm leading-7 text-charcoal/55">
            إذا كان البريد <span dir="ltr" className="font-medium text-charcoal">{email}</span> مسجّلاً لدينا، فسيصلك رابط لإعادة تعيين كلمة المرور خلال دقائق. تفقّد مجلد الرسائل غير المرغوب فيها أيضًا.
          </p>
          <Link href="/login" className="mt-7 flex w-full items-center justify-center gap-1.5 rounded-xl border border-borderSoft bg-white px-4 py-3 text-[0.9rem] font-medium transition-all hover:border-sage hover:bg-sageSoft/40">
            <ArrowRight size={16} /> العودة لتسجيل الدخول
          </Link>
        </div>
      </AuthShell>
    );
  }

  return (
    <AuthShell>
      <div className="mb-8">
        <h1 className="text-2xl font-semibold tracking-tight text-charcoal">نسيت كلمة المرور؟</h1>
        <p className="mt-1.5 text-sm leading-7 text-charcoal/50">أدخل بريدك الإلكتروني وسنرسل لك رابطًا لإعادة تعيين كلمة المرور</p>
      </div>

      <form onSubmit={handleSubmit} className="space-y-5">
        <AuthField label="البريد الإلكتروني" htmlFor="fp-email">
          <AuthInput id="fp-email" icon={Mail} type="email" required dir="ltr" inputMode="email" autoComplete="email" autoFocus value={email} onChange={(e) => setEmail(e.target.value)} placeholder="name@company.com" />
        </AuthField>

        {error && <AuthAlert>{error}</AuthAlert>}

        <SubmitButton loading={loading} loadingText="جارٍ الإرسال...">إرسال رابط إعادة التعيين</SubmitButton>
      </form>

      <p className="mt-7 text-center text-sm text-charcoal/50">
        تذكرت كلمة المرور؟{" "}
        <Link href="/login" className="font-medium text-sage hover:underline">تسجيل الدخول</Link>
      </p>
    </AuthShell>
  );
}
