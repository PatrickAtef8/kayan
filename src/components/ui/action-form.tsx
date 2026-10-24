"use client";

import { createContext, useContext, useEffect, useRef, useState, useTransition, type ReactNode } from "react";
import { Check, TriangleAlert } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Spinner } from "@/components/ui/spinner";
import type { ActionResult } from "@/lib/action-result";

// A form for create/update server actions that ALWAYS tells the person what is happening:
//   while it runs → the button turns into «جارٍ …» with a spinner and can't be pressed twice;
//   when it works → a short ✓ confirmation (add forms) or the dialog closes (edit dialogs, via onSuccess);
//   when it fails → the reason in red, and everything they typed is kept (nothing is reset on error).
// It submits through onSubmit + a transition (not the native form action) precisely so the fields are NOT
// wiped on a failed save.

const PendingContext = createContext(false);

export function ActionForm({
  action,
  onSuccess,
  successText,
  resetOnSuccess = true,
  className,
  children,
}: {
  action: (formData: FormData) => Promise<ActionResult | void>;
  onSuccess?: () => void;
  successText?: string;
  resetOnSuccess?: boolean;
  className?: string;
  children: ReactNode;
}) {
  const [pending, startTransition] = useTransition();
  const [status, setStatus] = useState<{ kind: "ok" | "error"; text: string } | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); }, []);

  function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (pending) return;
    const form = e.currentTarget;
    const data = new FormData(form);
    if (timer.current) clearTimeout(timer.current);
    setStatus(null);
    startTransition(async () => {
      let result: ActionResult | void;
      try {
        result = await action(data);
      } catch {
        setStatus({ kind: "error", text: "تعذّر إتمام العملية. تحقّق من الاتصال وحاول مرة أخرى." });
        return;
      }
      if (result && result.error) {
        setStatus({ kind: "error", text: result.error });
        return;
      }
      if (resetOnSuccess) form.reset();
      if (successText) {
        setStatus({ kind: "ok", text: successText });
        timer.current = setTimeout(() => setStatus(null), 3500);
      }
      onSuccess?.();
    });
  }

  return (
    <PendingContext.Provider value={pending}>
      <form onSubmit={onSubmit} className={className} aria-busy={pending}>
        {children}
        <div aria-live="polite" className="col-span-full empty:hidden">
          {status && (
            <p className={`mt-3 flex items-start gap-1.5 text-xs ${status.kind === "ok" ? "text-sage" : "text-rose"}`} role={status.kind === "error" ? "alert" : "status"}>
              {status.kind === "ok" ? <Check size={14} className="mt-px shrink-0" /> : <TriangleAlert size={14} className="mt-px shrink-0" />}
              {status.text}
            </p>
          )}
        </div>
      </form>
    </PendingContext.Provider>
  );
}

// Submit button for <ActionForm>: shows the spinner + `pendingText` while the action runs.
export function SubmitButton({ pendingText = "جارٍ الحفظ...", children, className = "", variant = "primary" }: { pendingText?: string; children: ReactNode; className?: string; variant?: "primary" | "secondary" | "ghost" | "danger" }) {
  const pending = useContext(PendingContext);
  return (
    <Button type="submit" variant={variant} disabled={pending} aria-disabled={pending} className={`inline-flex items-center justify-center gap-2 ${className}`}>
      {pending && <Spinner size={14} />}
      {pending ? pendingText : children}
    </Button>
  );
}
