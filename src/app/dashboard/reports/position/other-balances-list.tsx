"use client";

import { useState, useTransition } from "react";
import { X } from "lucide-react";
import { deactivateOtherBalance } from "./actions";
import { Spinner } from "@/components/ui/spinner";

type Item = { id: string; kind: "asset" | "liability"; name: string; amount: number; notes: string | null };

function money(n: number) {
  return n.toLocaleString("ar-EG", { minimumFractionDigits: 2 });
}

export function OtherBalancesList({ items }: { items: Item[] }) {
  const [pending, startTransition] = useTransition();
  const [removingId, setRemovingId] = useState<string | null>(null);

  if (items.length === 0) return <p className="text-xs text-charcoal/40">لا توجد بنود إضافية</p>;

  return (
    <div className="divide-y divide-borderSoft rounded-xl border border-borderSoft">
      {items.map((item) => (
        <div key={item.id} className="flex items-center justify-between px-3.5 py-2.5 text-sm">
          <div>
            <p className="text-charcoal">{item.name}</p>
            {item.notes && <p className="mt-0.5 text-[0.6875rem] text-charcoal/40">{item.notes}</p>}
          </div>
          <div className="flex items-center gap-2.5">
            <span dir="ltr" className={item.kind === "asset" ? "text-sage" : "text-rose"}>
              {money(item.amount)} ج.م
            </span>
            <button
              onClick={() => {
                setRemovingId(item.id);
                startTransition(async () => {
                  await deactivateOtherBalance(item.id);
                  setRemovingId(null);
                });
              }}
              disabled={pending && removingId === item.id}
              aria-label="إلغاء البند"
              className="rounded-lg p-1 text-charcoal/30 hover:bg-rose/10 hover:text-rose disabled:opacity-40"
            >
              {pending && removingId === item.id ? <Spinner size={13} /> : <X size={14} />}
            </button>
          </div>
        </div>
      ))}
    </div>
  );
}
