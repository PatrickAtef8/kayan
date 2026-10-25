"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { ModernSelect } from "@/components/ui/select";
import { Button } from "@/components/ui/button";
import { startStocktake } from "./actions";

export function StartStocktakeForm({ warehouses }: { warehouses: { id: string; name: string }[] }) {
  const router = useRouter();
  const [warehouse, setWarehouse] = useState(warehouses.length === 1 ? warehouses[0].id : "");
  const [notes, setNotes] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function submit() {
    setError(null);
    startTransition(async () => {
      const result = await startStocktake({ warehouse_id: warehouse, notes });
      if (result.error || !result.id) {
        setError(result.error ?? "تعذّر بدء الجرد");
        return;
      }
      router.push(`/dashboard/inventory/stocktake/${result.id}`);
    });
  }

  return (
    <Card className="mb-7">
      <p className="mb-1 text-sm font-medium text-charcoal">بدء جرد جديد</p>
      <p className="mb-4 text-xs text-charcoal/45">يلتقط الجرد رصيد كل دفعة في المخزن الآن. لا يتغير المخزون إطلاقًا حتى تعتمد الجرد.</p>
      <div className="grid gap-3 sm:grid-cols-[1fr_1.5fr_auto] sm:items-end">
        <Field label="المخزن">
          <ModernSelect value={warehouse} onChange={setWarehouse} placeholder="اختر المخزن" options={warehouses.map((w) => ({ value: w.id, label: w.name }))} />
        </Field>
        <Field label="ملاحظات (اختياري)">
          <Input value={notes} maxLength={500} onChange={(e) => setNotes(e.target.value)} placeholder="مثال: جرد نهاية الشهر" />
        </Field>
        <Button type="button" disabled={pending || !warehouse} onClick={submit}>
          {pending ? "جارٍ البدء..." : "ابدأ الجرد"}
        </Button>
        {!warehouse && <span className="text-xs text-charcoal/45 sm:col-span-3">اختر المخزن أولًا</span>}
      </div>
      {error && <p className="mt-3 text-sm text-rose">{error}</p>}
    </Card>
  );
}
