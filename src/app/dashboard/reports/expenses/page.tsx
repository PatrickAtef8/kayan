import { Money } from "@/components/ui/money";
import Link from "next/link";
import { getReportContext } from "@/lib/report-context";
import { NoFinancialAccess } from "@/components/reports/no-financial-access";
import { PeriodFilter } from "@/components/reports/period-filter";
import { ExportButtons } from "@/components/ui/export-buttons";
import { Stat, SimpleTable } from "../party-analysis";
import { money } from "@/lib/party-reports";
import { parseFilters, withParams, type SalesSearchParams } from "@/lib/sales-report";

type Row = { group_id: string; group_label: string; expense_count: number; total: number; in_profit_loss: number };

const TYPE_LABEL: Record<string, string> = { operating: "مصروفات تشغيلية", rep_expense: "مصروفات مناديب", salary: "مرتبات مناديب", commission_payout: "مدفوعات عمولات (نقدية فقط)" };
const GROUPS = [
  { value: "category", label: "حسب التصنيف" },
  { value: "type", label: "حسب النوع" },
  { value: "month", label: "حسب الشهر" },
];

export default async function ExpensesReportPage(props: { searchParams: Promise<SalesSearchParams & { group?: string }> }) {
  const sp = await props.searchParams;
  const f = parseFilters(sp);
  const group = GROUPS.some((g) => g.value === sp.group) ? (sp.group as string) : "category";
  const { supabase, orgId, canViewFinancial, canExport } = await getReportContext();
  if (!orgId) return null;
  if (!canViewFinancial) return <NoFinancialAccess />;

  const { data, error } = await supabase.rpc("report_expenses", { org_id: orgId, p_from: f.from, p_to: f.to, p_group: group });
  if (error) return <p className="text-sm text-rose">{error.message}</p>;
  const rows = ((data as Row[]) ?? []).map((r) => ({ ...r, expense_count: Number(r.expense_count), total: Number(r.total), in_profit_loss: Number(r.in_profit_loss), group_label: group === "type" ? (TYPE_LABEL[r.group_id] ?? r.group_label) : r.group_label }));
  const total = rows.reduce((a, r) => ({ n: a.n + r.expense_count, all: a.all + r.total, pl: a.pl + r.in_profit_loss }), { n: 0, all: 0, pl: 0 });
  const share = (v: number) => (total.all > 0 ? ((v / total.all) * 100).toLocaleString("ar-EG", { maximumFractionDigits: 1 }) + "٪" : "—");

  return (
    <div>
      <PeriodFilter from={f.from} to={f.to} all={sp.all === "1" && !sp.from && !sp.to} />
      <div className="no-print mb-5 flex flex-wrap gap-2">
        {GROUPS.map((g) => (
          <Link key={g.value} href={withParams(sp, { group: g.value })} scroll={false} className={`rounded-lg px-3 py-2 text-sm font-medium ${group === g.value ? "bg-sageSoft text-sage" : "text-charcoal/50 hover:bg-paper"}`}>
            {g.label}
          </Link>
        ))}
      </div>

      <div className="mb-4">
        {canExport && (
          <ExportButtons
            filename={`المصروفات-${group}-${f.from ?? "الكل"}-${f.to ?? "الآن"}`}
            headers={["البند", "عدد المصروفات", "الإجمالي", "النسبة", "داخل الأرباح والخسائر"]}
            rows={rows.map((r) => [r.group_label, r.expense_count, r.total, share(r.total), r.in_profit_loss])}
          />
        )}
      </div>

      <div className="mb-6 grid grid-cols-2 gap-3 lg:grid-cols-3">
        <Stat label="إجمالي ما صُرف" value={<Money value={total.all} />} />
        <Stat label="منها مصروفات تشغيلية (في الأرباح والخسائر)" value={<Money value={total.pl} />} />
        <Stat label="عدد المصروفات" value={total.n} />
      </div>

      <SimpleTable
        empty="لا توجد مصروفات في هذه الفترة"
        head={[group === "category" ? "التصنيف" : group === "type" ? "النوع" : "الشهر", "العدد", "الإجمالي", "النسبة", "داخل الأرباح والخسائر"]}
        rows={rows.map((r) => [
          r.group_label,
          <span dir="ltr" key="n">{r.expense_count}</span>,
          <Money value={r.total} suffix="" key="t" className="font-medium" />,
          <span dir="ltr" key="s">{share(r.total)}</span>,
          <span dir="ltr" key="p" className={r.in_profit_loss === 0 && r.total > 0 ? "text-charcoal/40" : ""}>{money(r.in_profit_loss)}</span>,
        ])}
      />
      <p className="mt-4 text-xs text-charcoal/45">
        كل المصروفات المسجَّلة، كلٌّ مرة واحدة، بتاريخ المصروف. «داخل الأرباح والخسائر» = ما يُخصم من الربح كمصروف تشغيلي (يشمل المرتبات ومصروفات المناديب).
        مدفوعات العمولات تظهر هنا لأنها خروج نقدي حقيقي، لكنها <span className="font-medium text-charcoal/70">لا تُخصم من الربح مرة ثانية</span> لأن العمولة خُصمت عند استحقاقها. «بدون تصنيف» مصروفات بلا تصنيف مختار (ومنها المرتبات والعمولات المرتبطة بمندوب).
      </p>
    </div>
  );
}
