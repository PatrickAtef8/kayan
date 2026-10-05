"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { MODULES, DEFAULT_ENABLED_MODULES, type ModuleKey } from "@/lib/modules";
import { translateAuthError } from "@/lib/auth-errors";
import { AuthShell } from "@/components/auth/auth-shell";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";

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
  const [selectedModules, setSelectedModules] = useState<Set<ModuleKey>>(
    new Set(DEFAULT_ENABLED_MODULES)
  );
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  function toggleModule(key: ModuleKey) {
    setSelectedModules((prev) => {
      const next = new Set(prev);
      next.has(key) ? next.delete(key) : next.add(key);
      return next;
    });
  }

  async function handleCreateAccount(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError(null);

    const { data: signUpData, error: signUpError } = await supabase.auth.signUp({ email, password });
    if (signUpError) {
      setError(translateAuthError(signUpError.message));
      setLoading(false);
      return;
    }
    if (!signUpData.session) {
      setError("هذا البريد الإلكتروني مستخدم بالفعل، أو يحتاج إلى تأكيد. جرّب تسجيل الدخول بدلاً من ذلك.");
      setLoading(false);
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
      setError(translateAuthError(rpcError.message));
      return;
    }

    router.push("/dashboard");
    router.refresh();
  }

  return (
    <AuthShell>
      <div className="flex items-center gap-2 mb-1">
        <StepDot active={step === 1} done={step === 2} />
        <div className={`h-px flex-1 ${step === 2 ? "bg-sage" : "bg-borderSoft"}`} />
        <StepDot active={step === 2} done={false} />
      </div>
      <h1 className="text-2xl font-semibold text-ink mt-4 mb-1">
        {step === 1 ? "بيانات الشركة" : "اختر ما تحتاجه"}
      </h1>
      <p className="text-sm text-ink/50 mb-7">
        {step === 1 ? "خطوة 1 من 2" : "يمكنك تعديل هذا لاحقًا من الإعدادات"}
      </p>

      {step === 1 && (
        <div className="space-y-4">
          <Field label="اسم الشركة">
            <Input value={orgName} onChange={(e) => setOrgName(e.target.value)} placeholder="مثال: شركة النور للتجارة" />
          </Field>
          <Field label="نوع النشاط">
            <Input value={businessType} onChange={(e) => setBusinessType(e.target.value)} placeholder="تجارة، توزيع، تجزئة..." />
          </Field>
          <Field label="البريد الإلكتروني">
            <Input type="email" dir="ltr" value={email} onChange={(e) => setEmail(e.target.value)} />
          </Field>
          <Field label="كلمة المرور">
            <Input type="password" dir="ltr" value={password} onChange={(e) => setPassword(e.target.value)} />
          </Field>
          <Button
            type="button"
            disabled={!orgName || !email || !password}
            onClick={() => setStep(2)}
            className="w-full"
          >
            التالي: اختيار الوحدات
          </Button>
        </div>
      )}

      {step === 2 && (
        <form onSubmit={handleCreateAccount}>
          <div className="grid grid-cols-2 gap-2 mb-6">
            {MODULES.filter((m) => !("core" in m && m.core)).map((m) => {
              const active = selectedModules.has(m.key);
              return (
                <button
                  type="button"
                  key={m.key}
                  onClick={() => toggleModule(m.key)}
                  className={`cursor-pointer rounded-card border px-3 py-2.5 text-sm text-right transition-colors ${
                    active ? "border-brass bg-brass/10 text-ink font-medium" : "border-line text-ink/55 hover:border-ink/20"
                  }`}
                >
                  {m.label}
                </button>
              );
            })}
          </div>

          {error && <p className="text-sm text-rose mb-3">{error}</p>}

          <div className="flex gap-2">
            <Button type="button" variant="secondary" onClick={() => setStep(1)} className="flex-1">
              رجوع
            </Button>
            <Button type="submit" disabled={loading} className="flex-1">
              {loading ? "جارٍ الإنشاء..." : "إنشاء الحساب"}
            </Button>
          </div>
        </form>
      )}
    </AuthShell>
  );
}

function StepDot({ active, done }: { active: boolean; done: boolean }) {
  return (
    <div
      className={`h-6 w-6 rounded-full flex items-center justify-center text-xs font-medium shrink-0 ${
        active || done ? "bg-sage text-ivory" : "bg-borderSoft text-charcoal/40"
      }`}
    >
      {done ? "✓" : ""}
    </div>
  );
}
