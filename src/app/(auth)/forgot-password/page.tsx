"use client";

import { useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { translateAuthError } from "@/lib/auth-errors";
import { AuthShell } from "@/components/auth/auth-shell";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";

// §12: "Password reset" — request step. Supabase emails a link that lands
// on /reset-password with a recovery session already attached; that page
// does the actual password change.
export default function ForgotPasswordPage() {
  const supabase = createClient();
  const [email, setEmail] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [sent, setSent] = useState(false);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError(null);

    const { error } = await supabase.auth.resetPasswordForEmail(email, {
      redirectTo: `${window.location.origin}/reset-password`,
    });

    setLoading(false);
    if (error) {
      setError(translateAuthError(error.message));
      return;
    }
    setSent(true);
  }

  if (sent) {
    return (
      <AuthShell>
        <h1 className="text-2xl font-semibold text-ink mb-1">تحقق من بريدك الإلكتروني</h1>
        <p className="text-sm text-ink/50 mb-7">
          إذا كان البريد الإلكتروني <span dir="ltr">{email}</span> مسجّلاً لدينا، فسيصلك رابط لإعادة تعيين كلمة المرور خلال دقائق.
        </p>
        <a href="/login" className="text-brass text-sm font-medium">
          العودة لتسجيل الدخول
        </a>
      </AuthShell>
    );
  }

  return (
    <AuthShell>
      <h1 className="text-2xl font-semibold text-ink mb-1">نسيت كلمة المرور؟</h1>
      <p className="text-sm text-ink/50 mb-7">أدخل بريدك الإلكتروني وسنرسل لك رابطًا لإعادة تعيين كلمة المرور</p>

      <form onSubmit={handleSubmit} className="space-y-4">
        <Field label="البريد الإلكتروني">
          <Input type="email" required dir="ltr" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="بريدك الإلكتروني" />
        </Field>

        {error && <p className="text-sm text-rose">{error}</p>}

        <Button type="submit" disabled={loading} className="w-full">
          {loading ? "جارٍ الإرسال..." : "إرسال رابط إعادة التعيين"}
        </Button>
      </form>

      <p className="mt-6 text-center text-sm text-ink/50">
        تذكرت كلمة المرور؟{" "}
        <a href="/login" className="text-brass font-medium">
          تسجيل الدخول
        </a>
      </p>
    </AuthShell>
  );
}
