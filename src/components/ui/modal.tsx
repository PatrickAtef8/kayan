"use client";

import { X } from "lucide-react";

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
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div onClick={onClose} className="absolute inset-0 bg-charcoal/40" aria-hidden="true" />
      <div className="relative w-full max-w-md rounded-card border border-borderSoft bg-white p-6 shadow-xl">
        <div className="mb-5 flex items-center justify-between">
          <h2 className="text-base font-medium text-ink">{title}</h2>
          <button onClick={onClose} className="cursor-pointer text-ink/40 hover:text-ink">
            <X size={18} strokeWidth={2} />
          </button>
        </div>
        {children}
      </div>
    </div>
  );
}
