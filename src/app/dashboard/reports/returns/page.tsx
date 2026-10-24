import Link from "next/link";
import { getReportContext } from "@/lib/report-context";
import { isRestrictedRep } from "@/lib/org-context";
import { ExportButtons } from "@/components/ui/export-buttons";
import { SalesReportFilters } from "@/components/reports/sales-report-filters";
import { Stat, SimpleTable } from "../party-analysis";
import { loadFilterOptions, money, parseFilters, qty, withParams, type SalesSearchParams } from "@/lib/sales-report";

type Row = {
  group_id: string; group_label: string; returns: number; lines: number; customers: number;
  units: number; resalable_units: number; damaged_units: number; value: number; share_pct: number;
};
const GROUPS = [
  { value: "reason", label: "حسب السبب" },
  { value: "product", label: "حسب الصنف" },
  { value: "customer", label: "حسب العميل" },
];

export default async function ReturnsReportPage(props: { searchParams: Promise<SalesSearchParams & { group?: string; reason?: string }> }) {
  const sp = await props.searchParams;
  const f = parseFilters(sp);
  const group = GROUPS.some((g) => g.value === sp.group) ? (sp.group as string) : "reason";
  const reason = ["damaged", "expired", "slow_moving", "other", "unclassified"].includes(sp.reason ?? "") ? (sp.reason as string) : null;
  const { supabase, orgId, canExport } = await getReportContext();
  if (!orgId) return null;

  const restricted = await isRestrictedRep();
  const options = await loadFilterOptions(supabase, orgId);
  const { data, error } = await supabase.rpc("report_returns_by_reason", {
    org_id: orgId, p_from: f.from, p_to: f.to, p_group: group, p_reason: reason, p_warehouse: f.warehouse, p_rep: f.rep, p_limit: 1000, p_offset: 0,
  });
  if (error) return <p className="text-sm text-rose">{error.message}</p>;
  const rows = ((data as Row[]) ?? []).map((r) => ({ ...r, returns: Number(r.returns), customers: Number(r.customers), units: Number(r.units), resalable_units: Number(r.resalable_units), damaged_units: Number(r.damaged_units), value: Number(r.value), share_pct: Number(r.share_pct) }));
  const t = rows.reduce((a, r) => ({ v: a.v + r.value, u: a.u + r.units, n: a.n + r.returns }), { v: 0, u: 0, n: 0 });

  return (
    <div>
      <SalesReportFilters from={f.from} to={f.to} all={sp.all === "1" && !sp.from && !sp.to} warehouse={f.warehouse} rep={f.rep} channel={null} warehouses={options.warehouses} reps={options.reps} showRep={!restricted} showChannel={false} />
      <div className="no-print mb-5 flex flex-wrap items-center gap-2">
        {GROUPS.map((g) => (
          <Link key={g.value} href={withParams(sp, { group: g.value })} scroll={false} className={`rounded-lg px-3 py-2 text-sm font-medium ${group === g.value ? "bg-sageSoft text-sage" : "text-charcoal/50 hover:bg-paper"}`}>
            {g.label}
          </Link>
        ))}
        {reason && <Link href={withParams(sp, { reason: "" })} scroll={false} className="text-xs text-sage hover:underline">إلغاء فلتر السبب</Link>}
        <Link href="/dashboard/sales/returns" className="mr-auto text-xs text-sage hover:underline">قائمة المرتجعات</Link>
      </div>

      <div className="mb-4">
        {canExport && (
          <ExportButtons
            filename={`المرتجعات-${group}-${f.from ?? "الكل"}-${f.to ?? "الآن"}`}
            headers={["البند", "عدد المرتجعات", "الوحدات", "صالحة لإعادة البيع", "تالفة", "القيمة", "النسبة %"]}
            rows={rows.map((r) => [r.group_label, r.returns, r.units, r.resalable_units, r.damaged_units, r.value, r.share_pct])}
          />
        )}
      </div>

      <div className="mb-6 grid grid-cols-2 gap-3 lg:grid-cols-3">
        <Stat label="قيمة المرتجعات" value={`${money(t.v)} ج.م`} tone="rose" />
        <Stat label="الوحدات المرتجعة" value={qty(t.u)} />
        <Stat label="عدد المرتجعات" value={t.n} />
      </div>

      <SimpleTable
        empty="لا توجد مرتجعات في هذه الفترة"
        head={[group === "reason" ? "السبب" : group === "product" ? "الصنف" : "العميل", "المرتجعات", "الوحدات", "صالحة لإعادة البيع", "تالفة", "القيمة", "النسبة"]}
        rows={rows.map((r) => [
          group === "reason" && r.group_id !== "unclassified" ? <Link key="l" href={withParams(sp, { reason: r.group_id, group: "product" })} scroll={false} className="text-sage hover:underline">{r.group_label}</Link> : r.group_label,
          <span dir="ltr" key="n">{r.returns}</span>,
          <span dir="ltr" key="u" className="font-medium">{qty(r.units)}</span>,
          <span dir="ltr" key="ru">{qty(r.resalable_units)}</span>,
          <span dir="ltr" key="du" className={r.damaged_units > 0 ? "text-rose" : ""}>{qty(r.damaged_units)}</span>,
          <span dir="ltr" key="v" className="font-medium">{money(r.value)} ج.م</span>,
          <span dir="ltr" key="s">{r.share_pct.toLocaleString("ar-EG", { maximumFractionDigits: 1 })}٪</span>,
        ])}
      />
      <p className="mt-4 text-xs text-charcoal/45">
        الفترة بتاريخ المرتجع. القيمة = إيراد المرتجع قبل الضريبة، وهي نفس بند «المرتجعات» في الأرباح والخسائر. «السبب» يُسجَّل في كل سطر مرتجع، و«الحالة» (صالح/تالف) منفصلة عنه وتحدد دخول البضاعة المخزن.
        <span className="font-medium text-charcoal/70"> «غير مصنّف»</span> مرتجعات سُجِّلت قبل إضافة السبب، ولا يُخمَّن لها سبب.
        المرتجعات من العملاء فقط؛ مرتجعات الموردين لا تحمل سببًا في النظام.
      </p>
    </div>
  );
}
