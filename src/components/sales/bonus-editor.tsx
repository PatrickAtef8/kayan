"use client";

import { Plus, Trash2 } from "lucide-react";
import { Field, Input } from "@/components/ui/input";
import { AsyncSearchSelect, type SearchOption } from "@/components/ui/async-search-select";

export type BonusRow = { key: number; product_id: string; quantity: number };

let bonusKey = 0;
export function emptyBonusRow(): BonusRow {
  return { key: bonusKey++, product_id: "", quantity: 1 };
}

// Bonus is never computed: the person lists exactly which items are given for free.
// A bonus of a product that is also a paid line lowers that line's effective price;
// any other product becomes its own zero-value line (stock and cost still move).
export function BonusEditor({
  search,
  known,
  rows,
  onChange,
}: {
  /** server-side product search (catalogues of any size) and the records found so far, by id */
  search: (query: string) => Promise<SearchOption[]>;
  known: Map<string, { id: string; name: string; unit?: string }>;
  rows: BonusRow[];
  onChange: (rows: BonusRow[]) => void;
}) {
  const update = (key: number, patch: Partial<BonusRow>) => onChange(rows.map((r) => (r.key === key ? { ...r, ...patch } : r)));
  return (
    <div className="mt-6 border-t border-borderSoft pt-5">
      <div className="mb-1 text-xs font-medium text-charcoal/45">بونص (أصناف مجانية)</div>
      <div className="space-y-2.5">
        {rows.map((row) => {
          const product = known.get(row.product_id);
          return (
            <div key={row.key} className="grid grid-cols-1 gap-2.5 rounded-xl border border-borderSoft bg-sageSoft/20 p-3 sm:grid-cols-[1.6fr_0.8fr_auto] sm:items-end">
              <Field label="الصنف">
                <AsyncSearchSelect value={row.product_id} selectedLabel={product?.name} onChange={(id) => update(row.key, { product_id: id })} search={search} placeholder="اختر صنف البونص" searchPlaceholder="ابحث باسم الصنف أو الكود..." />
              </Field>
              <Field label={`الكمية${product?.unit ? ` (${product.unit})` : ""}`}>
                <Input type="number" step="0.001" min="0" dir="ltr" value={row.quantity} onChange={(e) => update(row.key, { quantity: Number(e.target.value) })} />
              </Field>
              <button type="button" onClick={() => onChange(rows.filter((r) => r.key !== row.key))} className="flex h-11 w-11 items-center justify-center rounded-xl text-charcoal/35 hover:bg-rose/10 hover:text-rose" aria-label="حذف البونص">
                <Trash2 size={16} />
              </button>
            </div>
          );
        })}
      </div>
      <button type="button" onClick={() => onChange([...rows, emptyBonusRow()])} className="mt-3 flex items-center gap-1.5 rounded-lg px-2 py-1.5 text-xs text-sage hover:bg-sageSoft/30">
        <Plus size={15} /> إضافة بونص
      </button>
    </div>
  );
}
