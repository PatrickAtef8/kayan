"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { translateAuthError } from "@/lib/auth-errors";
import { setPasswordFromLink } from "./actions";
import { parseAuthLink, explainLinkError } from "@/lib/auth-link";
import { AuthShell } from "@/components/auth/auth-shell";
import Link from "next/link";
import { Lock, MailWarning, PartyPopper } from "lucide-react";
import { AuthAlert, AuthField, PasswordInput, PasswordStrength, SubmitButton } from "@/components/auth/auth-fields";
import { MIN_PASSWORD_LENGTH, isPasswordAcceptable } from "@/lib/password-strength";

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
  const [linkError, setLinkError] = useState<string | null>(null);
  const [isInvite, setIsInvite] = useState(false);
  const [timedOut, setTimedOut] = useState(false);

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

    // An invitation (or recovery) link may carry the session in the #hash, or a token_hash, or an error. The
    // PKCE browser client ignores the hash form, so read it here and sign the person in directly.
    (async () => {
      const link = parseAuthLink(window.location.search, window.location.hash);
      if (link.kind === "error") {
        setLinkError(explainLinkError(link.code, link.message));
        return;
      }
      if (link.kind === "session") {
        const { error } = await supabase.auth.setSession({ access_token: link.accessToken, refresh_token: link.refreshToken });
        if (error) {
          setLinkError(translateAuthError(error.message, (error as { code?: string }).code));
          return;
        }
        setIsInvite(link.type === "invite");
        window.history.replaceState(null, "", window.location.pathname); // do not leave the tokens in the address bar
        setReady(true);
      } else if (link.kind === "token_hash") {
        const { error } = await supabase.auth.verifyOtp({ token_hash: link.tokenHash, type: link.type });
        if (error) {
          setLinkError(explainLinkError(null, error.message));
          return;
        }
        setIsInvite(link.type === "invite");
        window.history.replaceState(null, "", window.location.pathname);
        setReady(true);
      }
    })();

    const timer = setTimeout(() => setTimedOut(true), 6000);

    return () => {
      subscription.unsubscribe();
      clearTimeout(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);

    if (!isPasswordAcceptable(password)) {
      setError(`كلمة المرور قصيرة جدًا — يجب ألا تقل عن ${MIN_PASSWORD_LENGTH} أحرف.`);
      return;
    }
    if (password !== confirmPassword) {
      setError("كلمتا المرور غير متطابقتين.");
      return;
    }

    setLoading(true);
    try {
      const { data: sessionData } = await supabase.auth.getSession();
      const token = sessionData.session?.access_token;
      if (!token) {
        setError("انتهت الجلسة أو الرابط. اطلب من مدير الفريق إعادة إرسال الدعوة، أو اطلب رابطًا جديدًا.");
        return;
      }

      // Save the password on the server, then sign in with it so the browser holds a normal session.
      const res = await setPasswordFromLink(token, password);
      if (res.error) {
        setError(res.error);
        return;
      }
      const email = res.email ?? sessionData.session?.user.email;
      if (email) {
        const { error: signInError } = await supabase.auth.signInWithPassword({ email, password });
        if (signInError) {
          setError(translateAuthError(signInError.message, (signInError as { code?: string }).code, (signInError as { reasons?: string[] }).reasons));
          return;
        }
      }
    } catch (err) {
      setError(translateAuthError(err instanceof Error ? err.message : ""));
      return;
    } finally {
      setLoading(false);
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
        <div className="flex flex-col items-center text-center">
          <div className="mb-5 flex h-14 w-14 items-center justify-center rounded-2xl bg-sageSoft text-sage"><PartyPopper size={26} strokeWidth={1.6} /></div>
          <h1 className="text-2xl font-semibold tracking-tight text-charcoal">تم حفظ كلمة المرور</h1>
          <p className="mt-2 text-sm text-charcoal/50">جارٍ تحويلك...</p>
        </div>
      </AuthShell>
    );
  }

  if (!ready) {
    const failed = linkError !== null || timedOut;
    return (
      <AuthShell>
        <div className="flex flex-col items-center text-center">
          <div className="mb-5 flex h-14 w-14 items-center justify-center rounded-2xl bg-sageSoft text-sage">{failed ? <MailWarning size={26} strokeWidth={1.6} /> : <span className="h-6 w-6 animate-spin rounded-full border-2 border-current border-t-transparent" />}</div>
          <h1 className="text-2xl font-semibold tracking-tight text-charcoal">{failed ? "تعذّر فتح الرابط" : "جارٍ التحقق من الرابط..."}</h1>
          {failed ? (
            <>
              <p className="mt-3 text-sm leading-7 text-charcoal/55">{linkError ?? "لم نتمكن من التحقق من الرابط. قد يكون منتهي الصلاحية أو استُخدم من قبل."} إن كنت مدعوًّا للانضمام، اطلب من مدير الفريق إعادة إرسال الدعوة.</p>
              <Link href="/forgot-password" className="mt-6 flex w-full items-center justify-center rounded-xl bg-charcoal px-4 py-3 text-[0.9rem] font-medium text-ivory transition-colors hover:bg-sage">اطلب رابطًا جديدًا</Link>
            </>
          ) : (
            <p className="mt-2 text-sm text-charcoal/50">لحظات من فضلك...</p>
          )}
        </div>
      </AuthShell>
    );
  }

  return (
    <AuthShell>
      <div className="mb-7">
        <h1 className="text-2xl font-semibold tracking-tight text-charcoal">{isInvite ? "مرحبًا بك — أنشئ كلمة المرور" : "كلمة مرور جديدة"}</h1>
        <p className="mt-1.5 text-sm text-charcoal/50">{isInvite ? "اختر كلمة مرور لحسابك لتبدأ العمل" : "اختر كلمة مرور جديدة لحسابك"}</p>
      </div>

      <form onSubmit={handleSubmit} className="space-y-5">
        <AuthField label="كلمة المرور الجديدة" htmlFor="rp-pass">
          <PasswordInput id="rp-pass" icon={Lock} required autoFocus autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} placeholder="••••••••" />
          <PasswordStrength password={password} />
        </AuthField>
        <AuthField label="تأكيد كلمة المرور" htmlFor="rp-confirm">
          <PasswordInput id="rp-confirm" icon={Lock} required autoComplete="new-password" value={confirmPassword} onChange={(e) => setConfirmPassword(e.target.value)} placeholder="••••••••" invalid={confirmPassword.length > 0 && confirmPassword !== password} />
        </AuthField>

        {error && <AuthAlert>{error}</AuthAlert>}

        <SubmitButton loading={loading} loadingText="جارٍ الحفظ...">حفظ كلمة المرور</SubmitButton>
      </form>
    </AuthShell>
  );
}
