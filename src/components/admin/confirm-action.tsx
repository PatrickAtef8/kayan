"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import type { AdminResult } from "@/app/admin/actions";

// A button that asks "are you sure?", runs a server action, shows why it failed if it did, and refreshes the page.
export function ConfirmAction({ label, title, description, confirmLabel, run, tone = "neutral", disabled, redirectTo, requireText }: {
  label: string; title: string; description: string; confirmLabel: string; run: (typed: string) => Promise<AdminResult>; tone?: "neutral" | "danger"; disabled?: boolean; redirectTo?: string;
  // when set, the person must type exactly this text before the confirm button works (the server re-checks it)
  requireText?: string;
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const [typed, setTyped] = useState("");
  return (
    <>
      <button type="button" disabled={disabled} onClick={() => { setError(null); setTyped(""); setOpen(true); }}
        className={`rounded-lg border px-3 py-1.5 text-xs font-medium transition-colors disabled:cursor-not-allowed disabled:opacity-40 ${tone === "danger" ? "border-rose/30 text-rose hover:bg-rose/5" : "border-borderSoft text-charcoal/75 hover:border-sage hover:text-charcoal"}`}>{label}</button>
      <ConfirmDialog open={open} title={title} description={description} confirmLabel={confirmLabel} loading={pending} error={error}
        confirmDisabled={requireText !== undefined && typed.normalize("NFC").trim() !== requireText.normalize("NFC").trim()}
        onCancel={() => setOpen(false)}
        onConfirm={() => start(async () => {
          let r: AdminResult;
          try { r = await run(typed); } catch { setError("تعذّر الاتصال بالخادم."); return; }
          if (r.error) { setError(r.error); return; }
          setOpen(false); if (redirectTo) router.push(redirectTo); else router.refresh();
        })}>
        {requireText !== undefined && (
          <label className="mb-4 block text-start text-xs text-ink/60">
            اكتب اسم الشركة للتأكيد: <b className="select-all text-ink">{requireText}</b>
            <input value={typed} onChange={(e) => setTyped(e.target.value)} autoComplete="off" spellCheck={false} aria-label="اسم الشركة للتأكيد"
              className="mt-1.5 w-full rounded-lg border border-borderSoft px-3 py-2 text-sm text-ink outline-none focus:border-rose focus:ring-2 focus:ring-rose/20" />
          </label>
        )}
      </ConfirmDialog>
    </>
  );
}
