"use client";

import { useState, useTransition } from "react";
import { Plus, Trash2, ArrowLeftRight } from "lucide-react";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ModernSelect } from "@/components/ui/select";
import { createStockTransfer, type TransferLineInput } from "./actions";

type Line = TransferLineInput & { key: number };

let lineKey = 0;
function emptyLine(): Line {
  return { key: lineKey++, product_id: "", quantity: 1 };
}

export function StockTransferForm({ products, warehouses }: { products: { id: string; name: string }[]; warehouses: { id: string; name: string }[] }) {
  const [fromWarehouseId, setFromWarehouseId] = useState(warehouses[0]?.id ?? "");
  const [toWarehouseId, setToWarehouseId] = useState(warehouses[1]?.id ?? "");
  const [transferDate, setTransferDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [notes, setNotes] = useState("");
  const [lines, setLines] = useState<Line[]>([emptyLine()]);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState(false);
  const [pending, startTransition] = useTransition();

  function updateLine(key: number, patch: Partial<Line>) {
    setLines((current) => current.map((l) => (l.key === key ? { ...l, ...patch } : l)));
  }

  function submit() {
    setError(null);
    setSuccess(false);
    startTransition(async () => {
      const result = await createStockTransfer({
        from_warehouse_id: fromWarehouseId,
        to_warehouse_id: toWarehouseId,
        transfer_date: transferDate,
        items: lines.map(({ product_id, quantity }) => ({ product_id, quantity })),
        notes,
      });
      if (result.error) {
        setError(result.error);
        return;
      }
      setLines([emptyLine()]);
      setNotes("");
      setSuccess(true);
    });
  }

  return (
    <Card className="mb-7 p-5 sm:p-6">
      <p className="mb-4 flex items-center gap-2 text-xs font-medium text-charcoal/40">
        <ArrowLeftRight size={13} strokeWidth={2} />
        نقل مخزون بين المخازن
      </p>

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <Field label="من مخزن">
          <ModernSelect value={fromWarehouseId} onChange={setFromWarehouseId} allowClear={false} options={warehouses.map((w) => ({ value: w.id, label: w.name }))} />
        </Field>
        <Field label="إلى مخزن">
          <ModernSelect value={toWarehouseId} onChange={setToWarehouseId} allowClear={false} options={warehouses.map((w) => ({ value: w.id, label: w.name }))} />
        </Field>
        <Field label="تاريخ النقل">
          <Input type="date" dir="ltr" value={transferDate} onChange={(e) => setTransferDate(e.target.value)} />
        </Field>
      </div>

      <div className="mt-4 space-y-3">
        {lines.map((line) => (
          <div key={line.key} className="grid grid-cols-1 gap-3 sm:grid-cols-[1fr_auto_auto] sm:items-end">
            <Field label="المنتج">
              <ModernSelect value={line.product_id} onChange={(id) => updateLine(line.key, { product_id: id })} allowClear={false} placeholder="اختر منتجًا" options={products.map((p) => ({ value: p.id, label: p.name }))} />
            </Field>
            <Field label="الكمية">
              <Input type="number" min="0" step="0.001" dir="ltr" value={line.quantity} onChange={(e) => updateLine(line.key, { quantity: Number(e.target.value) })} className="w-32" />
            </Field>
            <button
              type="button"
              onClick={() => setLines((current) => (current.length > 1 ? current.filter((l) => l.key !== line.key) : current))}
              className="mb-0.5 flex h-10 w-10 items-center justify-center rounded-lg text-charcoal/30 hover:bg-paper hover:text-rose"
            >
              <Trash2 size={15} strokeWidth={1.8} />
            </button>
          </div>
        ))}
      </div>

      <button type="button" onClick={() => setLines((current) => [...current, emptyLine()])} className="mt-3 flex items-center gap-1.5 text-xs font-medium text-sage">
        <Plus size={14} strokeWidth={2.2} />
        إضافة صنف
      </button>

      <div className="mt-4">
        <Field label="ملاحظات (اختياري)">
          <Input value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="سبب النقل" />
        </Field>
      </div>

      <div className="mt-4 flex items-center gap-3">
        <Button type="button" disabled={pending} onClick={submit}>
          {pending ? "جارٍ الحفظ..." : "تنفيذ النقل"}
        </Button>
        {error && <span className="text-xs text-rose">{error}</span>}
        {success && <span className="text-xs text-sage">تم تنفيذ النقل بنجاح</span>}
      </div>
    </Card>
  );
}
