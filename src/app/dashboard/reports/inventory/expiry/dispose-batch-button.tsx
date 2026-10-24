"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Modal } from "@/components/ui/modal";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { disposeBatch } from "../../../inventory/actions";

// "إعدام" on one batch row: removes quantity from exactly that batch (never from another one).
export function DisposeBatchButton({
  batchId,
  productName,
  quantity,
  unit,
  expiryLabel,
  defaultReason,
}: {
  batchId: string;
  productName: string;
  quantity: number;
  unit: string;
  expiryLabel: string;
  defaultReason: string;
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [qty, setQty] = useState(String(quantity));
  const [reason, setReason] = useState(defaultReason);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function submit() {
    setError(null);
    startTransition(async () => {
      const result = await disposeBatch({ batch_id: batchId, quantity: Number(qty), reason });
      if (result.error) {
        setError(result.error);
        return;
      }
      setOpen(false);
      router.refresh();
    });
  }

  return (
    <>
      <button type="button" onClick={() => { setQty(String(quantity)); setReason(defaultReason); setError(null); setOpen(true); }} className="cursor-pointer rounded-lg px-2 py-1 text-xs text-rose hover:bg-rose/10">
        إعدام
      </button>
      <Modal open={open} onClose={() => setOpen(false)} title="إعدام كمية من دفعة">
        <div className="space-y-4">
          <p className="text-sm text-charcoal/70">
            {productName} — {expiryLabel} — المتاح في الدفعة: <span dir="ltr">{quantity} {unit}</span>
          </p>
          <Field label="الكمية المراد إعدامها">
            <Input type="number" step="0.001" min="0" max={quantity} dir="ltr" value={qty} onChange={(e) => setQty(e.target.value)} />
          </Field>
          <Field label="السبب">
            <Input value={reason} onChange={(e) => setReason(e.target.value)} />
          </Field>
          <p className="text-xs text-charcoal/45">يُخصم من هذه الدفعة فقط ولا يمس أي دفعة أخرى، ويُسجَّل كحركة تسوية بالسالب.</p>
          {error && <p className="text-sm text-rose">{error}</p>}
          <div className="flex justify-end gap-2">
            <Button type="button" variant="ghost" onClick={() => setOpen(false)}>إلغاء</Button>
            <Button type="button" variant="danger" disabled={pending} onClick={submit}>{pending ? "جارٍ الإعدام..." : "تأكيد الإعدام"}</Button>
          </div>
        </div>
      </Modal>
    </>
  );
}
