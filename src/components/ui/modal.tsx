"use client";

import { X } from "lucide-react";

// Centered dialog on larger screens, a bottom sheet on phones. The body scrolls on its own, so a tall form or a long
// invoice never pushes the title or the close button off the screen.
export function Modal({
  open,
  onClose,
  title,
  children,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  children: React.ReactNode;
}) {
  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center sm:items-center sm:p-4" role="dialog" aria-modal="true" aria-label={title}>
      <div onClick={onClose} className="absolute inset-0 bg-charcoal/40" aria-hidden="true" />
      <div className="relative flex max-h-[92dvh] w-full max-w-md flex-col rounded-t-2xl border border-borderSoft bg-white p-4 pb-[max(1rem,env(safe-area-inset-bottom))] shadow-xl sm:max-h-[90dvh] sm:max-w-lg sm:rounded-card sm:p-6">
        <div className="mb-4 flex shrink-0 items-start justify-between gap-3 sm:mb-5">
          <h2 className="min-w-0 break-words text-base font-medium leading-7 text-ink">{title}</h2>
          <button onClick={onClose} aria-label="إغلاق" className="-m-1.5 flex h-9 w-9 shrink-0 cursor-pointer items-center justify-center rounded-lg text-ink/40 hover:bg-paper hover:text-ink">
            <X size={18} strokeWidth={2} />
          </button>
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain">{children}</div>
      </div>
    </div>
  );
}
