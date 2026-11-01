"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { ArrowLeft, Lock, Mail } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { translateAuthError } from "@/lib/auth-errors";
import { AuthShell } from "@/components/auth/auth-shell";
import { checkoutPath, signupPath, type PlanSelection } from "@/lib/billing/selection";
import { AuthAlert, AuthField, AuthInput, PasswordInput, SubmitButton } from "@/components/auth/auth-fields";

// `selection` was validated on the server (see page.tsx); /checkout validates and prices it again.
export function LoginForm({ confirmed = false, selection = null }: { confirmed?: boolean; selection?: PlanSelection | null }) {
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
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    if (error) {
      setLoading(false);
      // wrong credentials get the friendly fixed message; anything else (network, rate limit...) is explained
      setError(/invalid login|invalid_credentials|credentials/i.test(`${error.message} ${(error as { code?: string }).code ?? ""}`) ? "البريد الإلكتروني أو كلمة المرور غير صحيحة." : translateAuthError(error.message, (error as { code?: string }).code));
      return;
    }
    router.push(selection ? checkoutPath(selection) : "/dashboard");
    router.refresh();
  }

  return (
    <AuthShell>
      <div className="mb-8">
        <h1 className="text-2xl font-semibold tracking-tight text-charcoal">أهلًا بعودتك</h1>
        <p className="mt-1.5 text-sm text-charcoal/50">سجّل الدخول لمتابعة إدارة أعمالك</p>
      </div>

      {confirmed && <div className="mb-5"><AuthAlert tone="success">تم تأكيد بريدك الإلكتروني. سجّل الدخول وسيتم إعداد شركتك تلقائيًا.</AuthAlert></div>}

      <form onSubmit={handleSubmit} className="space-y-5" noValidate={false}>
        <AuthField label="البريد الإلكتروني" htmlFor="login-email">
          <AuthInput id="login-email" icon={Mail} type="email" required dir="ltr" autoComplete="email" autoFocus inputMode="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="name@company.com" invalid={!!error} />
        </AuthField>

        <AuthField
          label="كلمة المرور"
          htmlFor="login-password"
          aside={<Link href={`/forgot-password${email ? `?email=${encodeURIComponent(email.trim())}` : ""}`} className="text-xs font-medium text-sage hover:underline">نسيت كلمة المرور؟</Link>}
        >
          <PasswordInput id="login-password" icon={Lock} required autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} placeholder="••••••••" invalid={!!error} />
        </AuthField>

        {error && <AuthAlert>{error}</AuthAlert>}

        <SubmitButton loading={loading} loadingText="جارٍ الدخول...">
          دخول <ArrowLeft size={17} className="transition-transform group-hover:-translate-x-0.5" />
        </SubmitButton>
      </form>

      <div className="my-7 flex items-center gap-3 text-xs text-charcoal/30"><span className="h-px flex-1 bg-borderSoft" />جديد على كيان؟<span className="h-px flex-1 bg-borderSoft" /></div>

      <Link href={signupPath(selection)} className="flex w-full items-center justify-center rounded-xl border border-borderSoft bg-white px-4 py-3 text-[0.9rem] font-medium text-charcoal transition-all hover:border-sage hover:bg-sageSoft/40">
        إنشاء حساب شركة جديد
      </Link>
    </AuthShell>
  );
}
