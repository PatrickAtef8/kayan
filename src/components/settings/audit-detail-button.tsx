"use client";

import { useState } from "react";
import { Modal } from "@/components/ui/modal";

export function AuditDetailButton({ before, after }: { before: unknown; after: unknown }) {
  const [open, setOpen] = useState(false);
  if (!before && !after) return <span className="text-charcoal/30">—</span>;

  return (
    <>
      <button onClick={() => setOpen(true)} className="text-xs font-medium text-sage hover:underline">
        عرض التفاصيل
      </button>
      <Modal open={open} onClose={() => setOpen(false)} title="تفاصيل العملية">
        <div className="max-h-[60vh] space-y-4 overflow-y-auto text-xs">
          {before ? (
            <div>
              <p className="mb-1.5 font-medium text-charcoal/50">قبل</p>
              <pre dir="ltr" className="whitespace-pre-wrap break-all rounded-lg bg-paper p-3 text-[0.6875rem] leading-5 text-charcoal/70">
                {JSON.stringify(before, null, 2)}
              </pre>
            </div>
          ) : null}
          {after ? (
            <div>
              <p className="mb-1.5 font-medium text-charcoal/50">بعد</p>
              <pre dir="ltr" className="whitespace-pre-wrap break-all rounded-lg bg-paper p-3 text-[0.6875rem] leading-5 text-charcoal/70">
                {JSON.stringify(after, null, 2)}
              </pre>
            </div>
          ) : null}
        </div>
      </Modal>
    </>
  );
}
