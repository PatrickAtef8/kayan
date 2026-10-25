"use client";

import { Money } from "@/components/ui/money";
import { formatMoney } from "@/lib/money";
import { useEffect, useRef, useState } from "react";
import { previewPricing, type PricingPreview, type PricingPreviewInput } from "@/app/dashboard/pricing-actions";

function money(n: number) {
  return formatMoney(n);
}

// Live totals straight from the database pricing engine (debounced).
export function usePricingPreview(input: PricingPreviewInput) {
  const [preview, setPreview] = useState<PricingPreview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [settledKey, setSettledKey] = useState<string | null>(null);
  const seq = useRef(0);
  const key = JSON.stringify(input);

  useEffect(() => {
    const id = ++seq.current;
    const timer = setTimeout(async () => {
      const result = await previewPricing(JSON.parse(key));
      if (id !== seq.current) return;
      setPreview(result.preview);
      setError(result.error);
      setSettledKey(key);
    }, 350);
    return () => clearTimeout(timer);
  }, [key]);

  // true while the engine has not yet answered for what is on screen right now
  return { preview, error, pending: settledKey !== key };
}

export function PricingSummary({
  preview,
  error,
  cashDiscountPctEntered,
  productName,
  taxLabel = "الضريبة",
}: {
  preview: PricingPreview | null;
  error: string | null;
  cashDiscountPctEntered: number;
  productName: (id: string) => string;
  taxLabel?: string;
}) {
  if (error) return <p className="text-xs text-rose">{error}</p>;
  if (!preview) return <p className="text-xs text-charcoal/40">أضف أصنافًا لعرض الإجمالي والخصومات والبونص.</p>;

  const bonus = new Map<string, number>();
  for (const b of preview.bonus) bonus.set(b.product, (bonus.get(b.product) ?? 0) + b.qty);

  const rows: [string, number][] = [
    ["إجمالي قبل الخصم", preview.gross],
    ["خصم الأصناف", -preview.line_discount],
    [`خصم على إجمالي الفاتورة (${preview.invoice_discount_pct}%)`, -preview.invoice_discount],
    [`خصم الشريحة (${preview.tier_discount_pct}%)`, -preview.tier_discount],
    [`خصم الدفع الفوري (${preview.cash_discount_pct}%)`, -preview.cash_discount],
  ];

  return (
    <div className="rounded-xl border border-borderSoft bg-paper/40 p-4 text-sm">
      <div className="space-y-1.5">
        {rows
          .filter(([, v]) => v !== 0 || false)
          .map(([label, v]) => (
            <div key={label} className="flex items-center justify-between text-charcoal/70">
              <span>{label}</span>
              <span dir="ltr">{v < 0 ? "− " : ""}<Money value={Math.abs(v)} /></span>
            </div>
          ))}
        {preview.tax > 0 && (
          <div className="flex items-center justify-between text-charcoal/70">
            <span>{taxLabel}</span>
            <span dir="ltr">+ <Money value={preview.tax} /></span>
          </div>
        )}
        {cashDiscountPctEntered > 0 && preview.cash_discount === 0 && (
          <p className="text-xs text-charcoal/45">خصم الدفع الفوري بيتطبق لما تسجل مبلغ مدفوع/محصّل دلوقتي (أي طريقة دفع).</p>
        )}
        {bonus.size > 0 && (
          <div className="rounded-lg bg-sageSoft/40 px-3 py-2 text-xs text-sage">
            <span className="font-medium">بونص (بدون مقابل): </span>
            {[...bonus.entries()].map(([id, qty], i) => (
              <span key={id}>
                {i > 0 ? "، " : ""}
                {qty} × {productName(id)}
              </span>
            ))}
          </div>
        )}
      </div>
      <div className="mt-3 flex items-center justify-between border-t border-borderSoft pt-3">
        <span className="text-charcoal/70">الإجمالي المطلوب</span>
        <span className="text-lg font-semibold text-charcoal" dir="ltr"><Money value={preview.total} /></span>
      </div>
    </div>
  );
}
