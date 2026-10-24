"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { ArrowLeft, ArrowRight, Boxes, MailCheck, BriefcaseBusiness, Building2, Check, Handshake, Lock, Mail, Receipt, ShoppingBag, ShoppingCart, Tag, Truck, UserCheck, Users, Wallet, type LucideIcon } from "lucide-react";
import clsx from "clsx";
import { createClient } from "@/lib/supabase/client";
import { MODULES, DEFAULT_ENABLED_MODULES, type ModuleKey } from "@/lib/modules";
import { translateAuthError, isWeakPasswordError } from "@/lib/auth-errors";
import { isPasswordAcceptable } from "@/lib/password-strength";
import { AuthShell } from "@/components/auth/auth-shell";
import { AuthAlert, AuthField, AuthInput, PasswordInput, PasswordStrength, SubmitButton } from "@/components/auth/auth-fields";

const MODULE_ICONS: Record<string, LucideIcon> = { Users, Truck, ShoppingCart, ShoppingBag, Boxes, Receipt, Wallet, UserCheck, Handshake, Tag };
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

// Onboarding, per SRS §10: collect company basics, then let the owner pick
// modules via selectable cards (not a technical settings screen).
export default function SignupPage() {
  const router = useRouter();
  const supabase = createClient();

  const [step, setStep] = useState<1 | 2>(1);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [orgName, setOrgName] = useState("");
  const [businessType, setBusinessType] = useState("");
  const [selectedModules, setSelectedModules] = useState<Set<ModuleKey>>(new Set(DEFAULT_ENABLED_MODULES));
  const [touched, setTouched] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Set when the server (Supabase Auth) rejects the password even though it passed our own check.
  // Shown on step 1, right under the password box, so the person can fix it where it lives.
  const [passwordError, setPasswordError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [confirmSent, setConfirmSent] = useState(false);
  const [resendMsg, setResendMsg] = useState<string | null>(null);

  const emailOk = EMAIL_RE.test(email.trim());
  const passOk = isPasswordAcceptable(password);
  const step1Ok = orgName.trim().length > 0 && emailOk && passOk;

  function toggleModule(key: ModuleKey) {
    setSelectedModules((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  }

  function handleNext(e: React.FormEvent) {
    e.preventDefault();
    setTouched(true);
    if (!step1Ok) return;
    setError(null);
    setPasswordError(null);
    setStep(2);
  }

  async function handleCreateAccount(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError(null);

    // The company details travel with the account (user metadata) so that, when the project requires
    // email confirmation, the company can still be created automatically at the first login.
    const { data: signUpData, error: signUpError } = await supabase.auth.signUp({
      email: email.trim(),
      password,
      options: {
        emailRedirectTo: `${window.location.origin}/auth/callback`,
        data: { pending_org: { name: orgName.trim(), business_type: businessType, modules: Array.from(selectedModules) } },
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
        setStep(1);
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
      module_keys: Array.from(selectedModules),
    });

    setLoading(false);
    if (rpcError) {
      setError(translateAuthError(rpcError.message, rpcError.code));
      return;
    }

    router.push("/dashboard");
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
          <Link href="/login" className="mt-6 flex w-full items-center justify-center rounded-xl bg-charcoal px-4 py-3 text-[0.9rem] font-medium text-ivory transition-colors hover:bg-sage">الذهاب لتسجيل الدخول</Link>
          <button type="button" onClick={resend} className="mt-3 cursor-pointer text-sm text-sage hover:underline">لم تصلك الرسالة؟ أعد الإرسال</button>
        </div>
      </AuthShell>
    );
  }

  return (
    <AuthShell>
      <Stepper step={step} />

      <div className="mb-7 mt-6">
        <h1 className="text-2xl font-semibold tracking-tight text-charcoal">{step === 1 ? "أنشئ حساب شركتك" : "اختر ما تحتاجه"}</h1>
        <p className="mt-1.5 text-sm text-charcoal/50">{step === 1 ? "دقيقة واحدة وتبدأ العمل — بدون بطاقة ائتمان" : "يمكنك تعديل هذا لاحقًا من الإعدادات"}</p>
      </div>

      {step === 1 && (
        <form onSubmit={handleNext} className="space-y-5" noValidate>
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

          <SubmitButton type="submit" disabled={touched && !step1Ok}>
            التالي: اختيار الوحدات <ArrowLeft size={17} className="transition-transform group-hover:-translate-x-0.5" />
          </SubmitButton>
        </form>
      )}

      {step === 2 && (
        <form onSubmit={handleCreateAccount}>
          <div className="mb-6 grid grid-cols-2 gap-2.5">
            {MODULES.filter((m) => !("core" in m && m.core)).map((m) => {
              const active = selectedModules.has(m.key);
              const Icon = MODULE_ICONS[m.icon] ?? Boxes;
              return (
                <button
                  type="button"
                  key={m.key}
                  onClick={() => toggleModule(m.key)}
                  aria-pressed={active}
                  className={clsx("relative flex cursor-pointer items-center gap-2.5 rounded-xl border px-3 py-3 text-start text-sm transition-all duration-200", active ? "border-sage bg-sageSoft/60 font-medium text-charcoal shadow-sm" : "border-borderSoft bg-white text-charcoal/60 hover:border-charcoal/25")}
                >
                  <Icon size={17} strokeWidth={1.7} className={active ? "text-sage" : "text-charcoal/35"} />
                  <span className="flex-1">{m.label}</span>
                  <span className={clsx("flex h-4 w-4 items-center justify-center rounded-full border transition-colors", active ? "border-sage bg-sage text-ivory" : "border-borderSoft text-transparent")}><Check size={10} strokeWidth={3} /></span>
                </button>
              );
            })}
          </div>

          {error && <div className="mb-4"><AuthAlert>{error}</AuthAlert></div>}

          <div className="flex gap-2.5">
            <button type="button" onClick={() => setStep(1)} className="flex flex-1 cursor-pointer items-center justify-center gap-1.5 rounded-xl border border-borderSoft bg-white px-4 py-3 text-[0.9rem] font-medium text-charcoal transition-all hover:border-sage hover:bg-sageSoft/40">
              <ArrowRight size={16} /> رجوع
            </button>
            <SubmitButton loading={loading} loadingText="جارٍ الإنشاء..." className="flex-[1.4]">إنشاء الحساب</SubmitButton>
          </div>
        </form>
      )}

      <p className="mt-7 text-center text-sm text-charcoal/50">
        لديك حساب بالفعل؟{" "}
        <Link href="/login" className="font-medium text-sage hover:underline">تسجيل الدخول</Link>
      </p>
    </AuthShell>
  );
}

function Stepper({ step }: { step: 1 | 2 }) {
  const items = ["بيانات الحساب", "الوحدات"];
  return (
    <ol className="flex items-center gap-3" aria-label="خطوات إنشاء الحساب">
      {items.map((label, i) => {
        const n = i + 1;
        const done = step > n;
        const active = step === n;
        return (
          <li key={label} className="flex flex-1 items-center gap-3 last:flex-none" aria-current={active ? "step" : undefined}>
            <span className={clsx("flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-xs font-semibold transition-colors", done || active ? "bg-sage text-ivory" : "bg-borderSoft text-charcoal/40")}>{done ? <Check size={14} strokeWidth={3} /> : n}</span>
            <span className={clsx("whitespace-nowrap text-xs font-medium", active || done ? "text-charcoal" : "text-charcoal/35")}>{label}</span>
            {i < items.length - 1 && <span className={clsx("h-px flex-1 transition-colors", done ? "bg-sage" : "bg-borderSoft")} />}
          </li>
        );
      })}
    </ol>
  );
}
