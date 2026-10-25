"use client";

import { AlertTriangle } from "lucide-react";
import { Button } from "./button";

// The one, shared "are you sure?" dialog for any destructive action in the
// app — delete a customer, a supplier, a product, a warehouse, and (in
// later phases) void an invoice or cancel an order. Reuse this rather than
// building a one-off confirm per entity.
export function ConfirmDialog({
  open,
  title,
  description,
  confirmLabel = "حذف",
  loading = false,
  error,
  onConfirm,
  onCancel,
}: {
  open: boolean;
  title: string;
  description: string;
  confirmLabel?: string;
  loading?: boolean;
  // Set after a failed onConfirm (e.g. the delete was rejected server-side)
  // so the person sees WHY, instead of the dialog just closing on a delete
  // that silently didn't happen.
  error?: string | null;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-3 sm:p-4">
      <div onClick={onCancel} className="absolute inset-0 bg-charcoal/40" aria-hidden="true" />
      <div className="relative max-h-[92dvh] w-full max-w-sm overflow-y-auto rounded-card border border-borderSoft bg-white p-5 text-center shadow-xl sm:p-6">
        <div className="mx-auto mb-4 flex h-11 w-11 items-center justify-center rounded-full bg-rose/10 text-rose">
          <AlertTriangle size={20} strokeWidth={2} />
        </div>
        <h2 className="mb-1.5 text-base font-medium text-ink">{title}</h2>
        <p className={error ? "mb-3 text-sm text-ink/55" : "mb-6 text-sm text-ink/55"}>{description}</p>
        {error && <p className="mb-4 rounded-lg bg-rose/10 px-3 py-2 text-xs text-rose">{error}</p>}
        <div className="flex gap-2">
          <Button variant="secondary" className="flex-1" onClick={onCancel} disabled={loading}>
            إلغاء
          </Button>
          <Button variant="danger" className="flex-1" onClick={onConfirm} disabled={loading}>
            {loading ? "جارٍ الحذف..." : confirmLabel}
          </Button>
        </div>
      </div>
    </div>
  );
}
