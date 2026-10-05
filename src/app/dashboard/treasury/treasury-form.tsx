"use client";

import { useState, useTransition } from "react";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ModernSelect } from "@/components/ui/select";
import { recordTreasuryMovement } from "./actions";

export function TreasuryForm() {
  const [direction, setDirection] = useState<"in" | "out">("in");
  const [amount, setAmount] = useState(0);
  const [date, setDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [description, setDescription] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function submit() {
    setError(null);
    startTransition(async () => {
      const result = await recordTreasuryMovement({ direction, amount, movement_date: date, description });
      if (result.error) {
        setError(result.error);
        return;
      }
      setAmount(0);
      setDescription("");
    });
  }

  return (
    <Card className="p-5 sm:p-6">
      <div className="mb-1 text-xs font-medium text-charcoal/45">تسجيل حركة أخرى (دخل أو مصروف غير مرتبط بفاتورة)</div>
      <div className="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-4">
        <Field label="النوع">
          <ModernSelect
            value={direction}
            onChange={(v) => setDirection(v as "in" | "out")}
            allowClear={false}
            options={[
              { value: "in", label: "دخل" },
              { value: "out", label: "مصروف" },
            ]}
          />
        </Field>
        <Field label="المبلغ">
          <Input type="number" step="0.01" min="0" dir="ltr" value={amount} onChange={(e) => setAmount(Number(e.target.value))} />
        </Field>
        <Field label="التاريخ">
          <Input type="date" dir="ltr" value={date} onChange={(e) => setDate(e.target.value)} />
        </Field>
        <Field label="الوصف">
          <Input value={description} onChange={(e) => setDescription(e.target.value)} placeholder="اختياري" />
        </Field>
      </div>
      <div className="mt-5 flex items-center justify-end gap-3">
        {error && <span className="text-xs text-rose">{error}</span>}
        <Button type="button" disabled={pending} onClick={submit}>
          {pending ? "جارٍ الحفظ..." : "تسجيل الحركة"}
        </Button>
      </div>
    </Card>
  );
}
