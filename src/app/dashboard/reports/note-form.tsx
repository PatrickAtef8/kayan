"use client";

import { useState, useTransition } from "react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { addPartyNote } from "./note-actions";

export function NoteForm({ partyType, partyId, invoiceId, compact = false }: { partyType: "customer" | "supplier"; partyId: string; invoiceId?: string; compact?: boolean }) {
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  return (
    <div className="flex flex-wrap items-center gap-3">
      <div className={compact ? "min-w-[12rem] flex-1" : "min-w-[16rem] flex-1"}>
        <Input value={note} onChange={(e) => setNote(e.target.value)} placeholder={invoiceId ? "ملاحظة على هذه الفاتورة (مثال: العميل دفع 500 ج.م كاش)" : "مثال: العميل دفع 500 ج.م كاش اليوم"} />
      </div>
      <Button
        type="button"
        disabled={pending || !note.trim()}
        onClick={() =>
          startTransition(async () => {
            const r = await addPartyNote({ party_type: partyType, party_id: partyId, note, invoice_id: invoiceId });
            if (r.error) setError(r.error);
            else { setNote(""); setError(null); }
          })
        }
      >
        إضافة ملاحظة
      </Button>
      {error && <span className="text-xs text-rose">{error}</span>}
    </div>
  );
}
