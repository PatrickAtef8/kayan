"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { translateAuthError } from "@/lib/auth-errors";
import { AuthShell } from "@/components/auth/auth-shell";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";

// §12: "Password reset" — completion step. The emailed link (built by
// forgot-password's resetPasswordForEmail redirectTo) lands here; the
// Supabase browser client's own detectSessionInUrl parses the link and
// fires PASSWORD_RECOVERY once the recovery session is attached, before
// the person can be trusted to set a new password.
export default function ResetPasswordPage() {
  const router = useRouter();
  const supabase = createClient();

  const [ready, setReady] = useState(false);
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((event) => {
      if (event === "PASSWORD_RECOVERY") setReady(true);
    });

    // The link may have already been consumed and the session attached by
    // the time this component mounts, in which case no PASSWORD_RECOVERY
    // event fires here — fall back to checking for an existing session.
    supabase.auth.getSession().then(({ data }) => {
      if (data.session) setReady(true);
    });

    return () => subscription.unsubscribe();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);

    if (password.length < 6) {
      setError("كلمة المرور قصيرة جدًا — يجب ألا تقل عن 6 أحرف.");
      return;
    }
    if (password !== confirmPassword) {
      setError("كلمتا المرور غير متطابقتين.");
      return;
    }

    setLoading(true);
    const { error } = await supabase.auth.updateUser({ password });
    setLoading(false);

    if (error) {
      setError(translateAuthError(error.message));
      return;
    }
    setDone(true);
    setTimeout(() => {
      router.push("/dashboard");
      router.refresh();
    }, 1500);
  }

  if (done) {
    return (
      <AuthShell>
        <h1 className="text-2xl font-semibold text-ink mb-1">تم تغيير كلمة المرور</h1>
        <p className="text-sm text-ink/50">جارٍ تحويلك إلى لوحة التحكم...</p>
      </AuthShell>
    );
  }

  if (!ready) {
    return (
      <AuthShell>
        <h1 className="text-2xl font-semibold text-ink mb-1">رابط إعادة التعيين</h1>
        <p className="text-sm text-ink/50">
          جارٍ التحقق من الرابط... إذا لم يفتح تلقائيًا خلال لحظات، فقد يكون الرابط منتهي الصلاحية —{" "}
          <a href="/forgot-password" className="text-brass font-medium">
            اطلب رابطًا جديدًا
          </a>
          .
        </p>
      </AuthShell>
    );
  }

  return (
    <AuthShell>
      <h1 className="text-2xl font-semibold text-ink mb-1">كلمة مرور جديدة</h1>
      <p className="text-sm text-ink/50 mb-7">اختر كلمة مرور جديدة لحسابك</p>

      <form onSubmit={handleSubmit} className="space-y-4">
        <Field label="كلمة المرور الجديدة">
          <Input type="password" required dir="ltr" value={password} onChange={(e) => setPassword(e.target.value)} />
        </Field>
        <Field label="تأكيد كلمة المرور">
          <Input type="password" required dir="ltr" value={confirmPassword} onChange={(e) => setConfirmPassword(e.target.value)} />
        </Field>

        {error && <p className="text-sm text-rose">{error}</p>}

        <Button type="submit" disabled={loading} className="w-full">
          {loading ? "جارٍ الحفظ..." : "حفظ كلمة المرور"}
        </Button>
      </form>
    </AuthShell>
  );
}
