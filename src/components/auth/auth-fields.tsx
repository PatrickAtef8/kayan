"use client";

import { forwardRef, useId, useState, type InputHTMLAttributes, type ReactNode } from "react";
import clsx from "clsx";
import { AlertCircle, Check, CheckCircle2, Eye, EyeOff, type LucideIcon } from "lucide-react";
import { Spinner } from "@/components/ui/spinner";
import { passwordChecks, passwordStrength } from "@/lib/password-strength";

// Shared building blocks for the sign-in / sign-up / reset screens.
// Layout is RTL: the leading icon sits on the right, the show/hide toggle on the left, and
// email / password text stays LTR (dir="ltr") so addresses and passwords read correctly.

export function AuthField({ label, htmlFor, hint, aside, children }: { label: string; htmlFor: string; hint?: ReactNode; aside?: ReactNode; children: ReactNode }) {
  return (
    <div>
      <div className="mb-1.5 flex items-center justify-between gap-3">
        <label htmlFor={htmlFor} className="text-sm font-medium text-charcoal/75">{label}</label>
        {aside}
      </div>
      {children}
      {hint ? <p className="mt-1.5 text-xs text-charcoal/45">{hint}</p> : null}
    </div>
  );
}

const inputBase =
  "w-full rounded-xl border border-borderSoft bg-white py-3 text-[0.9rem] text-charcoal shadow-[0_1px_0_rgba(28,28,26,0.02)] outline-none transition-all duration-200 placeholder:text-charcoal/30 hover:border-charcoal/25 focus:border-sage focus:ring-4 focus:ring-sage/10 disabled:opacity-60";

type AuthInputProps = InputHTMLAttributes<HTMLInputElement> & { icon?: LucideIcon; invalid?: boolean };

export const AuthInput = forwardRef<HTMLInputElement, AuthInputProps>(function AuthInput({ icon: Icon, invalid, className, dir, ...props }, ref) {
  return (
    <div className="relative">
      {Icon ? <Icon aria-hidden size={18} strokeWidth={1.7} className="pointer-events-none absolute right-3.5 top-1/2 -translate-y-1/2 text-charcoal/35" /> : null}
      <input ref={ref} dir={dir} aria-invalid={invalid || undefined} className={clsx(inputBase, Icon ? "pr-10" : "pr-3.5", "pl-3.5", dir === "ltr" && "text-left", invalid && "border-rose/60 focus:border-rose focus:ring-rose/10", className)} {...props} />
    </div>
  );
});

type PasswordInputProps = Omit<InputHTMLAttributes<HTMLInputElement>, "type" | "dir"> & { icon?: LucideIcon; invalid?: boolean };

// Password box with a show/hide toggle and a Caps Lock warning (the two things the old form was missing).
export const PasswordInput = forwardRef<HTMLInputElement, PasswordInputProps>(function PasswordInput({ icon: Icon, invalid, className, onKeyUp, onBlur, ...props }, ref) {
  const [visible, setVisible] = useState(false);
  const [caps, setCaps] = useState(false);
  return (
    <div>
      <div className="relative">
        {Icon ? <Icon aria-hidden size={18} strokeWidth={1.7} className="pointer-events-none absolute right-3.5 top-1/2 -translate-y-1/2 text-charcoal/35" /> : null}
        <input
          ref={ref}
          type={visible ? "text" : "password"}
          dir="ltr"
          aria-invalid={invalid || undefined}
          className={clsx(inputBase, Icon ? "pr-10" : "pr-3.5", "pl-11 text-left", invalid && "border-rose/60 focus:border-rose focus:ring-rose/10", className)}
          onKeyUp={(e) => { setCaps(e.getModifierState?.("CapsLock") ?? false); onKeyUp?.(e); }}
          onBlur={(e) => { setCaps(false); onBlur?.(e); }}
          {...props}
        />
        <button
          type="button"
          onClick={() => setVisible((v) => !v)}
          aria-label={visible ? "إخفاء كلمة المرور" : "إظهار كلمة المرور"}
          aria-pressed={visible}
          className="absolute left-1.5 top-1/2 flex h-8 w-8 -translate-y-1/2 cursor-pointer items-center justify-center rounded-lg text-charcoal/40 transition-colors hover:bg-paper hover:text-charcoal"
        >
          {visible ? <EyeOff size={18} strokeWidth={1.7} /> : <Eye size={18} strokeWidth={1.7} />}
        </button>
      </div>
      {caps ? <p className="mt-1.5 flex items-center gap-1.5 text-xs text-[#8a6420]" role="status"><AlertCircle size={13} /> زر Caps Lock مفعّل</p> : null}
    </div>
  );
});

export function AuthAlert({ children, tone = "error" }: { children: ReactNode; tone?: "error" | "success" }) {
  const Icon = tone === "error" ? AlertCircle : CheckCircle2;
  return (
    <div role={tone === "error" ? "alert" : "status"} className={clsx("flex items-start gap-2.5 rounded-xl border px-3.5 py-3 text-sm leading-6", tone === "error" ? "animate-auth-shake border-rose/25 bg-rose/[0.06] text-rose" : "border-sage/25 bg-sageSoft text-sage")}>
      <Icon size={17} strokeWidth={1.8} className="mt-1 shrink-0" />
      <div>{children}</div>
    </div>
  );
}

const BAR = ["bg-borderSoft", "bg-rose", "bg-[#B7893B]", "bg-[#4A6857]", "bg-sage"];
const TEXT = ["text-charcoal/40", "text-rose", "text-[#8a6420]", "text-brassLight", "text-sage"];

// Live strength meter + requirements, shown upfront (not only after a failure).
export function PasswordStrength({ password }: { password: string }) {
  const id = useId();
  const { score, label } = passwordStrength(password);
  const checks = passwordChecks(password);
  return (
    <div className="mt-3" aria-live="polite">
      <div className="flex items-center gap-3">
        <div className="flex flex-1 gap-1.5" aria-hidden>
          {[1, 2, 3, 4].map((i) => (
            <span key={i} className={clsx("h-1.5 flex-1 rounded-full transition-colors duration-300", i <= score ? BAR[score] : "bg-borderSoft")} />
          ))}
        </div>
        <span id={id} className={clsx("min-w-[3.2rem] text-start text-xs font-medium transition-colors", TEXT[score])}>{label || "—"}</span>
      </div>
      <ul className="mt-3 grid grid-cols-1 gap-1.5 sm:grid-cols-2">
        {checks.map((c) => (
          <li key={c.id} className={clsx("flex items-center gap-2 text-xs transition-colors", c.ok ? "text-sage" : "text-charcoal/45")}>
            <span className={clsx("flex h-4 w-4 shrink-0 items-center justify-center rounded-full border transition-colors", c.ok ? "border-sage bg-sage text-ivory" : "border-borderSoft bg-white text-transparent")}>
              <Check size={10} strokeWidth={3} />
            </span>
            <span>{c.label}{c.required ? "" : " (مُستحسن)"}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

// Primary submit button with an inline spinner.
export function SubmitButton({ loading, loadingText, children, disabled, className, type = "submit", onClick }: { loading?: boolean; loadingText?: string; children: ReactNode; disabled?: boolean; className?: string; type?: "submit" | "button"; onClick?: () => void }) {
  return (
    <button
      type={type}
      onClick={onClick}
      disabled={disabled || loading}
      className={clsx("group flex w-full cursor-pointer items-center justify-center gap-2 rounded-xl bg-charcoal px-4 py-3 text-[0.9rem] font-medium text-ivory shadow-[0_8px_20px_-8px_rgba(28,28,26,0.45)] transition-all duration-200 hover:bg-sage hover:shadow-[0_10px_24px_-8px_rgba(52,78,65,0.55)] focus-visible:outline-none focus-visible:ring-4 focus-visible:ring-sage/25 active:scale-[0.99] disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-50", className)}
    >
      {loading ? <><Spinner size={15} /> {loadingText ?? children}</> : children}
    </button>
  );
}
