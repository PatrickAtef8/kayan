"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import type { AdminResult } from "@/app/admin/actions";

// A button that asks "are you sure?", runs a server action, shows why it failed if it did, and refreshes the page.
export function ConfirmAction({ label, title, description, confirmLabel, run, tone = "neutral", disabled, redirectTo }: {
  label: string; title: string; description: string; confirmLabel: string; run: () => Promise<AdminResult>; tone?: "neutral" | "danger"; disabled?: boolean; redirectTo?: string;
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  return (
    <>
      <button type="button" disabled={disabled} onClick={() => { setError(null); setOpen(true); }}
        className={`rounded-lg border px-3 py-1.5 text-xs font-medium transition-colors disabled:cursor-not-allowed disabled:opacity-40 ${tone === "danger" ? "border-rose/30 text-rose hover:bg-rose/5" : "border-borderSoft text-charcoal/75 hover:border-sage hover:text-charcoal"}`}>{label}</button>
      <ConfirmDialog open={open} title={title} description={description} confirmLabel={confirmLabel} loading={pending} error={error}
        onCancel={() => setOpen(false)}
        onConfirm={() => start(async () => {
          let r: AdminResult;
          try { r = await run(); } catch { setError("تعذّر الاتصال بالخادم."); return; }
          if (r.error) { setError(r.error); return; }
          setOpen(false); if (redirectTo) router.push(redirectTo); else router.refresh();
        })} />
    </>
  );
}
