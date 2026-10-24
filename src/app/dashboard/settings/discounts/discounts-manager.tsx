"use client";

import { useState, useTransition } from "react";
import { Trash2, Power } from "lucide-react";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Spinner } from "@/components/ui/spinner";
import { ModernSelect } from "@/components/ui/select";
import { DataTable } from "@/components/ui/data-table";
import { addTier, deleteTier, toggleTier } from "./actions";
import type { Tier } from "./page";

const money = (n: number) => n.toLocaleString("ar-EG", { minimumFractionDigits: 2 });
const SIDE_OPTIONS = [
  { value: "sales", label: "المبيعات" },
  { value: "purchases", label: "المشتريات" },
];
const SIDE_LABEL: Record<string, string> = { sales: "المبيعات", purchases: "المشتريات" };

export function DiscountsManager({ tiers }: { tiers: Tier[] }) {
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  const [tierSide, setTierSide] = useState<"sales" | "purchases">("sales");
  const [minAmount, setMinAmount] = useState(0);
  const [tierPct, setTierPct] = useState(0);

  const run = (fn: () => Promise<{ error: string | null }>, after?: () => void) => {
    setError(null);
    startTransition(async () => {
      const r = await fn();
      if (r.error) setError(r.error);
      else after?.();
    });
  };

  return (
    <div className="space-y-9">
      {error && <p className="text-sm text-rose">{error}</p>}

      <section>
        <h2 className="mb-1 text-base font-semibold text-charcoal">الخصم حسب الشرائح (Tiered Discount)</h2>
        <p className="mb-2 text-xs text-charcoal/50">
          لو قيمة الفاتورة (بعد خصم الأصناف) وصلت للحد الأدنى للشريحة، يتطبق خصمها كنسبة مئوية من قيمة الفاتورة. بتتطبق أعلى شريحة تم الوصول لها فقط (الشرائح لا تتراكم).
        </p>
        <p className="mb-4 text-xs text-charcoal/50">
          كل الخصومات بالنسبة المئوية. أما الـبونص فبقى يدوي بالكامل: بتدخل أصنافه وكمياته بنفسك داخل الفاتورة، ومفيش قواعد بونص تلقائية.
        </p>
        <Card className="mb-4 p-5">
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-4 sm:items-end">
            <Field label="يطبَّق على">
              <ModernSelect value={tierSide} onChange={(v) => setTierSide(v as "sales" | "purchases")} allowClear={false} options={SIDE_OPTIONS} />
            </Field>
            <Field label="الحد الأدنى للفاتورة (ج.م)">
              <Input type="number" min="0" step="0.01" dir="ltr" value={minAmount} onChange={(e) => setMinAmount(Number(e.target.value))} />
            </Field>
            <Field label="نسبة الخصم (%)">
              <Input type="number" min="0" max="100" step="0.01" dir="ltr" value={tierPct} onChange={(e) => setTierPct(Number(e.target.value))} />
            </Field>
            <Button type="button" disabled={pending} onClick={() => run(() => addTier({ applies_to: tierSide, min_amount: minAmount, discount_pct: tierPct }), () => { setMinAmount(0); setTierPct(0); })} className="inline-flex items-center gap-2">
              {pending && <Spinner size={14} />}
              {pending ? "جارٍ إضافة الشريحة..." : "إضافة شريحة"}
            </Button>
          </div>
        </Card>
        <DataTable<Tier>
          rows={tiers}
          getRowKey={(t) => t.id}
          emptyLabel="لا توجد شرائح — أضف أول شريحة أعلاه"
          columns={[
            { header: "النوع", render: (t) => SIDE_LABEL[t.applies_to] },
            { header: "لو الفاتورة ≥", render: (t) => <span dir="ltr">{money(t.min_amount)} ج.م</span> },
            { header: "الخصم", render: (t) => <span dir="ltr">{t.discount_pct}%</span> },
            { header: "الحالة", render: (t) => (t.is_active ? "مفعّلة" : <span className="text-charcoal/40">موقوفة</span>) },
            {
              header: "",
              render: (t) => (
                <div className="flex justify-end gap-1">
                  <button disabled={pending} onClick={() => run(() => toggleTier(t.id, !t.is_active))} className="rounded-card p-1.5 text-ink/40 hover:bg-paper hover:text-ink" aria-label="تفعيل/إيقاف"><Power size={15} /></button>
                  <button disabled={pending} onClick={() => run(() => deleteTier(t.id))} className="rounded-card p-1.5 text-ink/40 hover:bg-rose/10 hover:text-rose" aria-label="حذف"><Trash2 size={15} /></button>
                </div>
              ),
            },
          ]}
        />
      </section>
    </div>
  );
}
