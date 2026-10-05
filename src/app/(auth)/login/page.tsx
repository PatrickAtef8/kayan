"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { AuthShell } from "@/components/auth/auth-shell";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";

export default function LoginPage() {
  const router = useRouter();
  const supabase = createClient();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError(null);
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    setLoading(false);
    if (error) {
      setError("البريد الإلكتروني أو كلمة المرور غير صحيحة");
      return;
    }
    router.push("/dashboard");
    router.refresh();
  }

  return (
    <AuthShell>
      <h1 className="text-2xl font-semibold text-ink mb-1">تسجيل الدخول</h1>
      <p className="text-sm text-ink/50 mb-7">أهلًا بعودتك — أدخل بياناتك للمتابعة</p>

      <form onSubmit={handleSubmit} className="space-y-4">
        <Field label="البريد الإلكتروني">
          <Input
            type="email"
            required
            dir="ltr"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder="بريدك الإلكتروني"
          />
        </Field>
        <Field label="كلمة المرور">
          <Input
            type="password"
            required
            dir="ltr"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </Field>

        <div className="flex justify-end">
          <a href="/forgot-password" className="text-xs font-medium text-brass">
            نسيت كلمة المرور؟
          </a>
        </div>

        {error && <p className="text-sm text-rose">{error}</p>}

        <Button type="submit" disabled={loading} className="w-full">
          {loading ? "جارٍ الدخول..." : "دخول"}
        </Button>
      </form>

      <p className="mt-6 text-center text-sm text-ink/50">
        ليس لديك حساب؟{" "}
        <a href="/signup" className="text-brass font-medium">
          إنشاء حساب شركة جديد
        </a>
      </p>
    </AuthShell>
  );
}
