"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { MailCheck, BriefcaseBusiness, Building2, Lock, Mail } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { translateAuthError, isWeakPasswordError } from "@/lib/auth-errors";
import { isPasswordAcceptable } from "@/lib/password-strength";
import { AuthShell } from "@/components/auth/auth-shell";
import { checkoutPath, loginPath, type PlanSelection } from "@/lib/billing/selection";
import { AuthAlert, AuthField, AuthInput, PasswordInput, PasswordStrength, SubmitButton } from "@/components/auth/auth-fields";

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

// Onboarding: company basics only. The modules a company gets are decided by the PACKAGE it pays for (they are switched on when the
// payment is verified, migration 0066) — so sign-up no longer asks for them.
export type SelectionSummary = { packageName: string; optionLabel: string; dueToday: string };

// `selection` was validated on the SERVER (see page.tsx) against the live packages; `summary` is the server's own rendering of its
// price. The browser never decides what is bought: /checkout rebuilds the quote again.
export function SignupForm({ selection, summary }: { selection: PlanSelection | null; summary: SelectionSummary | null }) {
  const router = useRouter();
  const supabase = createClient();

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [orgName, setOrgName] = useState("");
  const [businessType, setBusinessType] = useState("");
  const [touched, setTouched] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Set when the server (Supabase Auth) rejects the password even though it passed our own check.
  // Shown right under the password box, so the person can fix it where it lives.
  const [passwordError, setPasswordError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [confirmSent, setConfirmSent] = useState(false);
  const [resendMsg, setResendMsg] = useState<string | null>(null);

  const emailOk = EMAIL_RE.test(email.trim());
  const passOk = isPasswordAcceptable(password);
  const formOk = orgName.trim().length > 0 && emailOk && passOk;

  async function handleCreateAccount(e: React.FormEvent) {
    e.preventDefault();
    setTouched(true);
    if (!formOk) return;
    setLoading(true);
    setError(null);
    setPasswordError(null);

    // The company details travel with the account (user metadata) so that, when the project requires
    // email confirmation, the company can still be created automatically at the first login.
    const { data: signUpData, error: signUpError } = await supabase.auth.signUp({
      email: email.trim(),
      password,
      options: {
        emailRedirectTo: `${window.location.origin}/auth/callback`,
        data: {
          pending_org: { name: orgName.trim(), business_type: businessType },
          // remembered with the account so that the choice survives the "confirm your email" round trip (re-validated when used)
          ...(selection ? { plan_selection: selection } : {}),
        },
      },
    });
    if (signUpError) {
      const code = (signUpError as { code?: string }).code;
      const reasons = (signUpError as { reasons?: string[] }).reasons;
      const friendly = translateAuthError(signUpError.message, code, reasons);
      setLoading(false);
      if (isWeakPasswordError(signUpError.message, code) || (reasons?.length ?? 0) > 0) {
        setPasswordError(friendly);
        setTouched(true);
        return;
      }
      setError(friendly);
      return;
    }
    if (!signUpData.session) {
      setLoading(false);
      // Supabase hides "already registered" by returning a user with NO identities; a brand-new account
      // that still needs email confirmation has one. (Both come back without a session.)
      if (signUpData.user && (signUpData.user.identities?.length ?? 0) === 0) {
        setError("هذا البريد الإلكتروني مسجّل بالفعل. جرّب تسجيل الدخول، أو استعد كلمة المرور إن نسيتها.");
      } else {
        setConfirmSent(true);
      }
      return;
    }

    const { error: rpcError } = await supabase.rpc("create_organization", {
      org_name: orgName,
      org_business_type: businessType,
      org_country: "EG",
      org_currency: "EGP",
      org_language: "ar",
      module_keys: [],   // the package they pay for decides the modules
    });

    setLoading(false);
    if (rpcError) {
      setError(translateAuthError(rpcError.message, rpcError.code));
      return;
    }

    // a package was chosen on /pricing: go straight to its order page instead of asking again
    router.push(selection ? checkoutPath(selection) : "/dashboard/billing");   // no package yet: choose and pay first
    router.refresh();
  }

  async function resend() {
    setResendMsg(null);
    const { error } = await supabase.auth.resend({ type: "signup", email: email.trim(), options: { emailRedirectTo: `${window.location.origin}/auth/callback` } });
    setResendMsg(error ? translateAuthError(error.message, (error as { code?: string }).code) : "تم إرسال الرابط مرة أخرى.");
  }

  if (confirmSent) {
    return (
      <AuthShell>
        <div className="flex flex-col items-center text-center">
          <div className="mb-5 flex h-14 w-14 items-center justify-center rounded-2xl bg-sageSoft text-sage"><MailCheck size={26} strokeWidth={1.6} /></div>
          <h1 className="text-2xl font-semibold tracking-tight text-charcoal">تم إنشاء حسابك — أكّد بريدك</h1>
          <p className="mt-3 text-sm leading-7 text-charcoal/55">
            أرسلنا رابط التأكيد إلى <span dir="ltr" className="font-medium text-charcoal">{email}</span>. افتح الرسالة واضغط الرابط (تفقّد الرسائل غير المرغوب فيها أيضًا)، ثم سجّل الدخول وسيتم إعداد شركة «{orgName}» تلقائيًا.
          </p>
          {resendMsg && <div className="mt-4 w-full"><AuthAlert tone="success">{resendMsg}</AuthAlert></div>}
          {selection && summary && <p className="mt-3 text-sm leading-7 text-charcoal/55">باقتك المختارة ({summary.packageName}) محفوظة، وسننقلك إلى صفحة الطلب بعد تسجيل الدخول.</p>}
          <Link href={loginPath(selection)} className="mt-6 flex w-full items-center justify-center rounded-xl bg-charcoal px-4 py-3 text-[0.9rem] font-medium text-ivory transition-colors hover:bg-sage">الذهاب لتسجيل الدخول</Link>
          <button type="button" onClick={resend} className="mt-3 cursor-pointer text-sm text-sage hover:underline">لم تصلك الرسالة؟ أعد الإرسال</button>
        </div>
      </AuthShell>
    );
  }

  return (
    <AuthShell>
      {selection && summary && (
        <div className="mt-6 rounded-xl border border-sage/30 bg-sageSoft/40 px-4 py-3 text-sm" role="status">
          <p className="text-xs text-charcoal/50">الباقة المختارة</p>
          <p className="mt-0.5 flex flex-wrap items-baseline justify-between gap-x-3 font-medium text-charcoal"><span>{summary.packageName} — {summary.optionLabel}</span><span className="num">{summary.dueToday}</span></p>
          <p className="mt-1 text-xs leading-5 text-charcoal/50">لن تحتاج إلى اختيارها مرة أخرى: بعد إنشاء الحساب ننقلك إلى صفحة الطلب لمراجعتها قبل الدفع.</p>
        </div>
      )}

      <div className="mb-7">
        <h1 className="text-2xl font-semibold tracking-tight text-charcoal">أنشئ حساب شركتك</h1>
        <p className="mt-1.5 text-sm text-charcoal/50">دقيقة واحدة — وتختار الباقة التي تحدد وحدات نظامك بعد إنشاء الحساب</p>
      </div>

      <form onSubmit={handleCreateAccount} className="space-y-5" noValidate>
        <AuthField label="اسم الشركة" htmlFor="su-org">
          <AuthInput id="su-org" icon={Building2} autoComplete="organization" autoFocus value={orgName} onChange={(e) => setOrgName(e.target.value)} placeholder="مثال: شركة النور للتجارة" invalid={touched && !orgName.trim()} />
        </AuthField>
        <AuthField label="نوع النشاط" htmlFor="su-type" hint="اختياري">
          <AuthInput id="su-type" icon={BriefcaseBusiness} value={businessType} onChange={(e) => setBusinessType(e.target.value)} placeholder="تجارة، توزيع، تجزئة..." />
        </AuthField>
        <AuthField label="البريد الإلكتروني" htmlFor="su-email" hint={touched && !emailOk ? <span className="text-rose">اكتب بريدًا إلكترونيًا صحيحًا</span> : undefined}>
          <AuthInput id="su-email" icon={Mail} type="email" dir="ltr" inputMode="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="name@company.com" invalid={touched && !emailOk} />
        </AuthField>
        <AuthField label="كلمة المرور" htmlFor="su-pass">
          <PasswordInput id="su-pass" icon={Lock} autoComplete="new-password" value={password} onChange={(e) => { setPassword(e.target.value); setPasswordError(null); }} placeholder="••••••••" invalid={(touched && !passOk) || !!passwordError} />
          <PasswordStrength password={password} />
          {passwordError && <div className="mt-3"><AuthAlert>{passwordError}</AuthAlert></div>}
        </AuthField>

        {error && <AuthAlert>{error}</AuthAlert>}

        <SubmitButton loading={loading} loadingText="جارٍ الإنشاء..." disabled={touched && !formOk}>إنشاء الحساب</SubmitButton>
      </form>

      <p className="mt-7 text-center text-sm text-charcoal/50">
        لديك حساب بالفعل؟{" "}
        <Link href={loginPath(selection)} className="font-medium text-sage hover:underline">تسجيل الدخول</Link>
      </p>
    </AuthShell>
  );
}

