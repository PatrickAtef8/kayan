"use client";

import { useState, useTransition } from "react";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ModernSelect } from "@/components/ui/select";
import { adjustStock } from "./actions";

export function StockAdjustmentForm({ products, warehouses }: { products: { id: string; name: string }[]; warehouses: { id: string; name: string }[] }) {
  const [productId, setProductId] = useState("");
  const [warehouseId, setWarehouseId] = useState(warehouses[0]?.id ?? "");
  const [quantityDelta, setQuantityDelta] = useState(0);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState(false);
  const [pending, startTransition] = useTransition();

  function submit() {
    setError(null);
    setSuccess(false);
    startTransition(async () => {
      const result = await adjustStock({ product_id: productId, warehouse_id: warehouseId, quantity_delta: quantityDelta, reason });
      if (result.error) {
        setError(result.error);
        return;
      }
      setProductId("");
      setQuantityDelta(0);
      setReason("");
      setSuccess(true);
    });
  }

  return (
    <Card className="mb-7 p-5 sm:p-6">
      <p className="mb-4 text-xs font-medium text-charcoal/40">تسوية مخزون يدوية</p>
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-4 sm:items-end">
        <Field label="المنتج">
          <ModernSelect value={productId} onChange={setProductId} allowClear={false} placeholder="اختر منتجًا" options={products.map((p) => ({ value: p.id, label: p.name }))} />
        </Field>
        <Field label="المخزن">
          <ModernSelect value={warehouseId} onChange={setWarehouseId} allowClear={false} placeholder="اختر مخزنًا" options={warehouses.map((w) => ({ value: w.id, label: w.name }))} />
        </Field>
        <Field label="كمية التسوية">
          <Input type="number" step="0.001" dir="ltr" value={quantityDelta} onChange={(e) => setQuantityDelta(Number(e.target.value))} placeholder="+10 أو -5" />
        </Field>
        <Field label="السبب">
          <Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="مثال: جرد فعلي" />
        </Field>
      </div>
      <div className="mt-4 flex items-center gap-3">
        <Button type="button" disabled={pending} onClick={submit}>
          {pending ? "جارٍ الحفظ..." : "تسجيل التسوية"}
        </Button>
        {error && <span className="text-xs text-rose">{error}</span>}
        {success && <span className="text-xs text-sage">تم تسجيل التسوية</span>}
      </div>
    </Card>
  );
}
