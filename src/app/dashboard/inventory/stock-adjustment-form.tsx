"use client";

import { useEffect, useState, useTransition } from "react";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ModernSelect } from "@/components/ui/select";
import { adjustStock, getStockBatches, type StockBatchInfo } from "./actions";

type Direction = "increase" | "decrease";

function localToday() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

// Manual stock adjustment.
//   زيادة  → creates a NEW batch of stock. This is the only time an expiry date is asked for,
//            because the date describes the goods being added (optional: blank = undated batch).
//   نقص    → no date: it is deducted from the existing batches, earliest expiry first (FEFO),
//            expired ones included — which is how expired stock is written off.
// The current batches of the chosen product/warehouse are shown so the effect is visible
// before saving.
export function StockAdjustmentForm({ products, warehouses }: { products: { id: string; name: string }[]; warehouses: { id: string; name: string }[] }) {
  const [productId, setProductId] = useState("");
  const [warehouseId, setWarehouseId] = useState(warehouses[0]?.id ?? "");
  const [direction, setDirection] = useState<Direction>("increase");
  const [quantity, setQuantity] = useState("");
  const [reason, setReason] = useState("");
  const [expiryDate, setExpiryDate] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState(false);
  const [pending, startTransition] = useTransition();

  // batches of the selected product + warehouse; `key` says which selection they belong to
  const [loaded, setLoaded] = useState<{ key: string; batches: StockBatchInfo[] } | null>(null);
  const [reloadTick, setReloadTick] = useState(0);
  const selectionKey = productId && warehouseId ? `${productId}|${warehouseId}|${reloadTick}` : "";
  useEffect(() => {
    if (!selectionKey) return;
    let cancelled = false;
    getStockBatches(productId, warehouseId).then((res) => {
      if (!cancelled) setLoaded({ key: selectionKey, batches: res.batches });
    });
    return () => {
      cancelled = true;
    };
  }, [selectionKey, productId, warehouseId]);
  const batches = loaded && loaded.key === selectionKey ? loaded.batches : null;
  const batchesLoading = !!selectionKey && batches === null;

  const today = localToday();
  const qty = Number(quantity);
  const increase = direction === "increase";
  const expiredDate = increase && expiryDate !== "" && expiryDate < today;

  function pickDirection(next: Direction) {
    setDirection(next);
    if (next === "decrease") setExpiryDate(""); // a decrease never carries a date
  }

  function submit() {
    setError(null);
    setSuccess(false);
    if (!(qty > 0)) {
      setError("أدخل الكمية (رقمًا أكبر من صفر)");
      return;
    }
    startTransition(async () => {
      const result = await adjustStock({ product_id: productId, warehouse_id: warehouseId, quantity_delta: increase ? qty : -qty, reason, expiry_date: increase ? expiryDate : "" });
      if (result.error) {
        setError(result.error);
        return;
      }
      setProductId("");
      setQuantity("");
      setReason("");
      setExpiryDate("");
      setReloadTick((t) => t + 1);
      setSuccess(true);
    });
  }

  const segment = (value: Direction, label: string) => (
    <button
      type="button"
      onClick={() => pickDirection(value)}
      className={`flex-1 rounded-lg px-3 py-2 text-sm font-medium transition-colors ${direction === value ? (value === "increase" ? "bg-sageSoft text-sage" : "bg-rose/10 text-rose") : "text-charcoal/50 hover:bg-paper"}`}
    >
      {label}
    </button>
  );

  return (
    <Card className="mb-7 p-5 sm:p-6">
      <p className="mb-4 text-xs font-medium text-charcoal/40">تسوية مخزون يدوية</p>
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4 sm:items-end">
        <Field label="المنتج">
          <ModernSelect value={productId} onChange={setProductId} allowClear={false} placeholder="اختر منتجًا" options={products.map((p) => ({ value: p.id, label: p.name }))} />
        </Field>
        <Field label="المخزن">
          <ModernSelect value={warehouseId} onChange={setWarehouseId} allowClear={false} placeholder="اختر مخزنًا" options={warehouses.map((w) => ({ value: w.id, label: w.name }))} />
        </Field>
        <Field label="نوع التسوية">
          <div className="flex gap-1 rounded-xl border border-borderSoft bg-white p-1">
            {segment("increase", "زيادة (+)")}
            {segment("decrease", "نقص (−)")}
          </div>
        </Field>
        <Field label="الكمية">
          <Input type="number" min="0" step="0.001" dir="ltr" value={quantity} onChange={(e) => setQuantity(e.target.value)} placeholder="مثال: 10" />
        </Field>
      </div>

      {increase ? (
        <div className="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-2 sm:items-start">
          <div>
            <Field label="تاريخ الصلاحية (اختياري)">
              <Input type="date" dir="ltr" value={expiryDate} onChange={(e) => setExpiryDate(e.target.value)} />
            </Field>
            <p className="mt-1.5 text-[0.6875rem] leading-relaxed text-charcoal/45">
              ينطبق على الكمية المضافة الآن فقط، وتُسجَّل كدفعة مستقلة بتاريخها. اتركه فارغًا لو المنتج بلا صلاحية — تُسجَّل الدفعة «بدون تاريخ».
            </p>
            {expiredDate && <p className="mt-1.5 text-[0.6875rem] text-amber-700">هذا التاريخ مضى بالفعل — الدفعة ستُعتبر منتهية ولن تُباع، وتظهر في تقرير الصلاحية للإعدام.</p>}
          </div>
          <Field label="السبب">
            <Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="مثال: جرد فعلي" />
          </Field>
        </div>
      ) : (
        <div className="mt-4 grid grid-cols-1 gap-4 sm:grid-cols-2 sm:items-start">
          <div className="rounded-xl bg-paper px-3.5 py-3 text-[0.6875rem] leading-relaxed text-charcoal/55">
            النقص لا يحتاج تاريخ صلاحية: يُخصم من الدفعات الموجودة بترتيب الأقرب انتهاءً أولًا (والدفعات بلا تاريخ أخيرًا)، وقد يشمل دفعة منتهية — وهذه هي طريقة تسوية الصلاحية المنتهية. لإعدام دفعة بعينها استخدم «إعدام» في التقارير ← المخزون ← الصلاحية.
          </div>
          <Field label="السبب">
            <Input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="مثال: جرد فعلي، تالف" />
          </Field>
        </div>
      )}

      {selectionKey && (
        <div className="mt-4 rounded-xl border border-borderSoft p-3">
          <p className="mb-2 text-xs font-medium text-charcoal/50">الدفعات الحالية لهذا المنتج في المخزن المختار</p>
          {batchesLoading ? (
            <p className="text-xs text-charcoal/40">جارٍ التحميل...</p>
          ) : batches && batches.length > 0 ? (
            <div className="space-y-1">
              {batches.map((b, i) => {
                const expired = b.expiry_date !== null && b.expiry_date < today;
                return (
                  <div key={i} className="flex items-center justify-between text-xs">
                    <span className="flex items-center gap-2 text-charcoal/70">
                      <span dir="ltr">{b.expiry_date ?? "بدون تاريخ"}</span>
                      {expired && <span className="rounded-full bg-rose/10 px-2 py-0.5 text-[0.625rem] text-rose">منتهية</span>}
                      {!decreaseTarget(direction, i) ? null : <span className="text-[0.625rem] text-charcoal/40">← أول ما يُخصم</span>}
                    </span>
                    <span dir="ltr" className="font-medium text-charcoal">{b.quantity}</span>
                  </div>
                );
              })}
            </div>
          ) : (
            <p className="text-xs text-charcoal/40">لا توجد دفعات — الرصيد الحالي صفر.</p>
          )}
        </div>
      )}

      <div className="mt-4 flex flex-wrap items-center gap-3">
        <Button type="button" disabled={pending || !productId || !warehouseId} onClick={submit}>
          {pending ? "جارٍ الحفظ..." : "تسجيل التسوية"}
        </Button>
        {error && <span className="text-xs text-rose">{error}</span>}
        {success && <span className="text-xs text-sage">تم تسجيل التسوية</span>}
      </div>
    </Card>
  );
}

// in "decrease" mode the first listed batch is the one deducted first
function decreaseTarget(direction: Direction, index: number) {
  return direction === "decrease" && index === 0;
}
