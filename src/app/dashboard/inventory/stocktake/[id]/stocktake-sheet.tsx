"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Card } from "@/components/ui/card";
import { DataTable } from "@/components/ui/data-table";
import { Field, Input } from "@/components/ui/input";
import { ModernSelect } from "@/components/ui/select";
import { Button } from "@/components/ui/button";
import { Modal } from "@/components/ui/modal";
import { addStocktakeFound, applyStocktake, cancelStocktake, reconcileStocktake, removeStocktakeFound, saveStocktakeCounts } from "../actions";

export type SheetLine = {
  line_id: string;
  product_id: string;
  product_name: string;
  sku: string | null;
  barcode: string | null;
  unit: string;
  batch_id: string | null;
  expiry_date: string | null;
  is_found: boolean;
  system_qty: number;
  current_qty: number;
  counted_qty: number | null;
  unit_cost: number | null; // null when the caller cannot see costs, or none is known
  stale: boolean;
};

export type SheetSummary = {
  status: "counting" | "applied" | "cancelled";
  notes: string | null;
  started_at: string;
  costs_visible: boolean;
  stale: boolean;
  stale_products: number;
  can_apply: boolean;
};

const NO_EXPIRY = "لا يوجد تاريخ صلاحية مسجل";
const num = (n: number) => Number(n).toLocaleString("ar-EG", { maximumFractionDigits: 3 });
const money = (n: number) => Number(n).toLocaleString("ar-EG", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const dateText = (d: string | null) => (d ? new Date(d + "T00:00:00").toLocaleDateString("ar-EG", { year: "numeric", month: "short", day: "numeric" }) : NO_EXPIRY);

function parse(v: string | undefined): number | null {
  if (v === undefined || v.trim() === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

type Filter = "all" | "variance" | "counted" | "uncounted" | "stale";

export function StocktakeSheet({ stocktakeId, summary, lines, products, canCount }: { stocktakeId: string; summary: SheetSummary; lines: SheetLine[]; products: { id: string; name: string }[]; canCount: boolean }) {
  const router = useRouter();
  const open = summary.status === "counting";
  const editable = open && canCount;

  // local, not-yet-saved counts; re-seeded whenever the server copy changes
  const serverSig = lines.map((l) => `${l.line_id}:${l.counted_qty ?? ""}:${l.system_qty}`).join("|");
  const [sig, setSig] = useState(serverSig);
  const [counts, setCounts] = useState<Record<string, string>>(() => Object.fromEntries(lines.map((l) => [l.line_id, l.counted_qty === null ? "" : String(l.counted_qty)])));
  if (sig !== serverSig) {
    setSig(serverSig);
    setCounts(Object.fromEntries(lines.map((l) => [l.line_id, l.counted_qty === null ? "" : String(l.counted_qty)])));
  }

  const [filter, setFilter] = useState<Filter>("all");
  const [search, setSearch] = useState("");
  const [message, setMessage] = useState<{ kind: "error" | "ok"; text: string } | null>(null);
  const [confirm, setConfirm] = useState<"apply" | "cancel" | null>(null);
  const [pending, startTransition] = useTransition();
  const [foundProduct, setFoundProduct] = useState("");
  const [foundExpiry, setFoundExpiry] = useState("");
  const [foundQty, setFoundQty] = useState("");

  const view = lines.map((l) => {
    const counted = editable ? parse(counts[l.line_id]) : l.counted_qty;
    const variance = counted === null ? null : counted - l.system_qty;
    const impact = variance !== null && l.unit_cost !== null ? variance * l.unit_cost : null;
    return { ...l, counted, variance, impact };
  });
  const dirty = editable ? view.filter((l) => l.counted !== lines.find((x) => x.line_id === l.line_id)?.counted_qty) : [];

  const sum = view.reduce(
    (a, l) => {
      if (l.counted === null) a.uncounted += 1;
      else a.counted += 1;
      if (l.variance !== null && l.variance < 0) {
        a.shortQty += -l.variance;
        a.shortVal += -(l.impact ?? 0);
      } else if (l.variance !== null && l.variance > 0) {
        a.surQty += l.variance;
        a.surVal += l.impact ?? 0;
      }
      if (l.variance !== null && l.variance !== 0) {
        a.changes += 1;
        if (l.unit_cost === null) a.noCost += 1;
      }
      return a;
    },
    { counted: 0, uncounted: 0, shortQty: 0, shortVal: 0, surQty: 0, surVal: 0, changes: 0, noCost: 0 },
  );

  const shown = view.filter((l) => {
    if (search && !`${l.product_name} ${l.barcode ?? ""} ${l.sku ?? ""}`.toLowerCase().includes(search.toLowerCase())) return false;
    if (filter === "variance") return l.variance !== null && l.variance !== 0;
    if (filter === "counted") return l.counted !== null;
    if (filter === "uncounted") return l.counted === null;
    if (filter === "stale") return l.stale;
    return true;
  });

  function run(fn: () => Promise<{ error: string | null }>, okText?: string) {
    setMessage(null);
    startTransition(async () => {
      const r = await fn();
      if (r.error) setMessage({ kind: "error", text: r.error });
      else {
        if (okText) setMessage({ kind: "ok", text: okText });
        router.refresh();
      }
    });
  }

  const payload = () => dirty.map((l) => ({ line_id: l.line_id, counted_qty: l.counted }));
  async function flush(): Promise<{ error: string | null }> {
    if (dirty.length === 0) return { error: null };
    return saveStocktakeCounts({ stocktake_id: stocktakeId, counts: payload() }) as Promise<{ error: string | null }>;
  }

  const hint = !open
    ? null
    : dirty.length > 0
      ? "احفظ الكميات أولًا"
      : summary.stale
        ? "تغيّر المخزون بعد بدء الجرد — نفّذ «مطابقة» وأعد جرد الأصناف المتأثرة"
        : !summary.can_apply
          ? summary.stale_products === 0 && sum.counted === 0
            ? "سجّل كمية فعلية لسطر واحد على الأقل"
            : "الاعتماد يحتاج صلاحية «اعتماد الجرد»"
          : null;

  const cards: { label: string; value: string; sub?: string; tone?: string }[] = [
    { label: "أسطر تم جردها", value: `${sum.counted} / ${view.length}`, sub: sum.uncounted ? `${sum.uncounted} لم تُجرد (لن تتغير)` : undefined },
    { label: "عجز", value: num(sum.shortQty), sub: summary.costs_visible ? `${money(sum.shortVal)} ج.م` : undefined, tone: "text-rose" },
    { label: "زيادة", value: num(sum.surQty), sub: summary.costs_visible ? `${money(sum.surVal)} ج.م` : undefined, tone: "text-sage" },
  ];
  if (summary.costs_visible) cards.push({ label: "الأثر المالي الصافي (تقدير)", value: `${money(sum.surVal - sum.shortVal)} ج.م`, sub: sum.noCost ? `${sum.noCost} سطر بدون تكلفة معروفة` : undefined, tone: sum.surVal - sum.shortVal < 0 ? "text-rose" : "text-charcoal" });

  return (
    <div>
      {!open && (
        <Card className="mb-5 p-4 text-sm text-charcoal/70">
          {summary.status === "applied" ? "تم اعتماد هذا الجرد وتطبيق فروقه على المخزون. الأرقام أدناه للاطلاع فقط." : "تم إلغاء هذا الجرد دون أي تغيير في المخزون."}
        </Card>
      )}
      {open && summary.stale && (
        <Card className="mb-5 flex flex-wrap items-center justify-between gap-3 border-amber-300 bg-amber-50 p-4">
          <p className="text-sm text-amber-800">
            تغيّر المخزون بعد بدء الجرد في {summary.stale_products} صنف (بيع/شراء/مرتجع/نقل…). لا يمكن الاعتماد قبل المطابقة، وسيُطلب إعادة جرد هذه الأصناف فقط.
          </p>
          {canCount && (
            <Button type="button" variant="secondary" disabled={pending} onClick={() => run(async () => { const f = await flush(); return f.error ? f : reconcileStocktake(stocktakeId); }, "تمت المطابقة — أعد جرد الأصناف المعلّمة")}>
              مطابقة
            </Button>
          )}
        </Card>
      )}
      {open && !summary.stale && (
        <p className="mb-4 text-xs text-charcoal/45">لن يتغير أي شيء في المخزون حتى تضغط «اعتماد الجرد». يمكنك الاستمرار في البيع والشراء أثناء الجرد، لكن أي حركة على صنف تُلزمك بمطابقته قبل الاعتماد.</p>
      )}

      <div className={`mb-6 grid grid-cols-2 gap-3 ${cards.length === 4 ? "lg:grid-cols-4" : "lg:grid-cols-3"}`}>
        {cards.map((c) => (
          <Card key={c.label} className="p-4">
            <p className="text-[0.6875rem] text-charcoal/45">{c.label}</p>
            <p className={`mt-1.5 text-xl font-semibold ${c.tone ?? "text-charcoal"}`} dir="ltr">{c.value}</p>
            {c.sub && <p className="mt-1 text-[0.6875rem] text-charcoal/40">{c.sub}</p>}
          </Card>
        ))}
      </div>

      {summary.costs_visible && (
        <p className="mb-4 text-xs text-charcoal/45">القيم المالية تقدير = الفرق × متوسط التكلفة الحالي للصنف. التسوية نفسها لا تغيّر متوسط التكلفة، وتُسجَّل بنفس هذه التكلفة.</p>
      )}
      <div className="no-print mb-3 flex flex-wrap items-center gap-2">
        <Input className="max-w-56" value={search} onChange={(e) => setSearch(e.target.value)} placeholder="بحث بالاسم أو الباركود" />
        {(["all", "counted", "uncounted", "variance", "stale"] as Filter[]).map((f) => (
          <button key={f} type="button" onClick={() => setFilter(f)} className={`rounded-lg px-2.5 py-1.5 text-xs font-medium ${filter === f ? "bg-charcoal text-ivory" : "bg-paper text-charcoal/50 hover:text-charcoal"}`}>
            {{ all: `الكل (${view.length})`, counted: `تم جردها (${sum.counted})`, uncounted: `لم تُجرد (${sum.uncounted})`, variance: `الفروق فقط (${sum.changes})`, stale: "تغيّرت" }[f]}
          </button>
        ))}
      </div>

      <DataTable
        rows={shown}
        getRowKey={(l) => l.line_id}
        emptyLabel="لا توجد أسطر مطابقة"
        rowClassName={(l) => (l.counted === null ? "bg-amber-50/60" : "")}
        columns={[
          {
            header: "المنتج",
            render: (l) => (
              <div>
                <span>{l.product_name}</span>
                {l.barcode && <span className="mr-2 text-[0.6875rem] text-charcoal/40" dir="ltr">{l.barcode}</span>}
                {l.is_found && <span className="mr-2 rounded-md bg-amber-100 px-1.5 py-0.5 text-[0.6875rem] text-amber-700">غير مسجل بالنظام</span>}
                {l.stale && open && <span className="mr-2 rounded-md bg-rose/10 px-1.5 py-0.5 text-[0.6875rem] text-rose">تغيّر</span>}
              </div>
            ),
          },
          { header: "الصلاحية", render: (l) => <span className={l.expiry_date ? "" : "text-charcoal/45"}>{dateText(l.expiry_date)}</span> },
          {
            header: "حالة الجرد",
            render: (l) => {
              const saved = lines.find((x) => x.line_id === l.line_id)?.counted_qty ?? null;
              if (l.counted === null) return <span className="rounded-md bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-700">لم يُجرد — لن يتغير</span>;
              if (editable && l.counted !== saved) return <span className="rounded-md bg-paper px-2 py-0.5 text-xs font-medium text-charcoal/60">غير محفوظ</span>;
              return <span className="rounded-md bg-sageSoft px-2 py-0.5 text-xs font-medium text-sage">تم الجرد</span>;
            },
          },
          { header: "رصيد النظام", render: (l) => <span dir="ltr">{num(l.system_qty)} {l.unit}</span> },
          {
            header: "الكمية الفعلية",
            render: (l) =>
              editable ? (
                <Input type="number" step="0.001" min="0" dir="ltr" className="w-28" value={counts[l.line_id] ?? ""} onChange={(e) => setCounts((c) => ({ ...c, [l.line_id]: e.target.value }))} />
              ) : (
                <span dir="ltr">{l.counted === null ? "—" : num(l.counted)}</span>
              ),
          },
          {
            header: "الفرق",
            render: (l) =>
              l.variance === null ? (
                <span className="text-charcoal/35">—</span>
              ) : (
                <span dir="ltr" className={l.variance < 0 ? "text-rose" : l.variance > 0 ? "text-sage" : ""}>{l.variance > 0 ? "+" : ""}{num(l.variance)}</span>
              ),
          },
          ...(summary.costs_visible
            ? [{ header: "الأثر المالي (تقدير)", render: (l: (typeof view)[number]) => (l.impact === null ? <span className="text-charcoal/35">{l.variance ? "تكلفة غير معروفة" : "—"}</span> : <span dir="ltr" className={l.impact < 0 ? "text-rose" : ""}>{money(l.impact)} ج.م</span>) }]
            : []),
          ...(editable
            ? [{ header: "", render: (l: (typeof view)[number]) => (l.is_found ? <button type="button" className="cursor-pointer text-xs text-rose hover:underline" onClick={() => run(async () => { const f = await flush(); return f.error ? f : removeStocktakeFound({ stocktake_id: stocktakeId, line_id: l.line_id }); })}>حذف</button> : null) }]
            : []),
        ]}
      />

      {editable && (
        <Card className="no-print mt-6">
          <p className="mb-3 text-sm font-medium text-charcoal">بضاعة موجودة فعليًا وغير مسجلة بالنظام</p>
          <p className="mb-3 text-xs text-charcoal/45">مثال: كمية بتاريخ صلاحية مختلف عن المسجّل، أو صنف لا رصيد له. تُضاف كدفعة جديدة عند الاعتماد.</p>
          <div className="grid gap-3 sm:grid-cols-[1.6fr_1fr_0.8fr_auto] sm:items-end">
            <Field label="المنتج">
              <ModernSelect value={foundProduct} onChange={setFoundProduct} placeholder="اختر المنتج" options={products.map((p) => ({ value: p.id, label: p.name }))} />
            </Field>
            <Field label="تاريخ الصلاحية (اختياري)">
              <Input type="date" dir="ltr" value={foundExpiry} onChange={(e) => setFoundExpiry(e.target.value)} />
            </Field>
            <Field label="الكمية">
              <Input type="number" step="0.001" min="0" dir="ltr" value={foundQty} onChange={(e) => setFoundQty(e.target.value)} />
            </Field>
            <Button
              type="button"
              variant="secondary"
              disabled={pending || !foundProduct || !(Number(foundQty) > 0)}
              onClick={() =>
                run(async () => {
                  const f = await flush();
                  if (f.error) return f;
                  const r = await addStocktakeFound({ stocktake_id: stocktakeId, product_id: foundProduct, expiry_date: foundExpiry, quantity: Number(foundQty) });
                  if (!r.error) {
                    setFoundProduct("");
                    setFoundExpiry("");
                    setFoundQty("");
                  }
                  return r;
                })
              }
            >
              إضافة
            </Button>
          </div>
        </Card>
      )}

      {message && <p className={`mt-4 text-sm ${message.kind === "error" ? "text-rose" : "text-sage"}`}>{message.text}</p>}

      {editable && (
        <div className="no-print mt-6 flex flex-wrap items-center gap-3">
          <Button type="button" variant="secondary" disabled={pending || dirty.length === 0} onClick={() => run(() => saveStocktakeCounts({ stocktake_id: stocktakeId, counts: payload() }) as Promise<{ error: string | null }>, "تم حفظ الكميات")}>
            حفظ الكميات {dirty.length > 0 && `(${dirty.length})`}
          </Button>
          <Button type="button" disabled={pending || hint !== null} onClick={() => setConfirm("apply")}>
            اعتماد الجرد
          </Button>
          <Button type="button" variant="ghost" disabled={pending} onClick={() => setConfirm("cancel")}>
            إلغاء الجرد
          </Button>
          {hint && <span className="text-xs text-charcoal/45">{hint}</span>}
        </div>
      )}

      <Modal open={confirm === "apply"} onClose={() => setConfirm(null)} title="اعتماد الجرد">
        <div className="space-y-3 text-sm text-charcoal/80">
          <p>سيتم تعديل المخزون فعليًا الآن، ولا يمكن التراجع (التصحيح بعدها يكون بجرد/تسوية جديدة).</p>
          <ul className="list-disc space-y-1 pr-5">
            <li>عدد التسويات: {sum.changes}</li>
            <li>أسطر تم جردها: {sum.counted} من {view.length}</li>
            <li>العجز: {num(sum.shortQty)}{summary.costs_visible ? ` (≈ ${money(sum.shortVal)} ج.م)` : ""} — يُخصم من الدفعة المحددة نفسها</li>
            <li>الزيادة: {num(sum.surQty)}{summary.costs_visible ? ` (≈ ${money(sum.surVal)} ج.م)` : ""}</li>
            {summary.costs_visible && <li>الأثر المالي الصافي (تقدير بمتوسط التكلفة الحالي): ≈ {money(sum.surVal - sum.shortVal)} ج.م</li>}
          </ul>
          {sum.uncounted > 0 && (
            <p className="rounded-lg bg-amber-50 p-3 text-amber-800">
              تنبيه: {sum.uncounted} سطر لم يُجرد، ولن يتغير رصيده (لن يُعتبر صفرًا). إن كان الجرد شاملًا فارجع وأكمل تسجيل الكميات.
            </p>
          )}
          <div className="flex justify-end gap-2 pt-2">
            <Button type="button" variant="ghost" onClick={() => setConfirm(null)}>رجوع</Button>
            <Button
              type="button"
              disabled={pending}
              onClick={() => {
                setConfirm(null);
                setMessage(null);
                startTransition(async () => {
                  const r = await applyStocktake(stocktakeId);
                  if (r.error) setMessage({ kind: "error", text: r.error });
                  else {
                    setMessage({ kind: "ok", text: `تم الاعتماد: ${r.applied} تسوية` });
                    router.refresh();
                  }
                });
              }}
            >
              {pending ? "جارٍ الاعتماد..." : "تأكيد الاعتماد"}
            </Button>
          </div>
        </div>
      </Modal>
      <Modal open={confirm === "cancel"} onClose={() => setConfirm(null)} title="إلغاء الجرد">
        <div className="space-y-3 text-sm text-charcoal/80">
          <p>سيُغلق الجرد دون أي تغيير في المخزون، وتضيع الكميات المسجلة.</p>
          <div className="flex justify-end gap-2 pt-2">
            <Button type="button" variant="ghost" onClick={() => setConfirm(null)}>رجوع</Button>
            <Button type="button" variant="danger" disabled={pending} onClick={() => { setConfirm(null); run(() => cancelStocktake(stocktakeId) as Promise<{ error: string | null }>); }}>
              إلغاء الجرد
            </Button>
          </div>
        </div>
      </Modal>
    </div>
  );
}
