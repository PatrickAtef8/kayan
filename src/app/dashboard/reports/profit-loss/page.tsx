import { Money } from "@/components/ui/money";
import Link from "next/link";
import { getReportContext } from "@/lib/report-context";
import { NoFinancialAccess } from "@/components/reports/no-financial-access";
import { PeriodFilter } from "@/components/reports/period-filter";
import { ExportButtons } from "@/components/ui/export-buttons";
import { Card } from "@/components/ui/card";
import { Stat, SimpleTable } from "../party-analysis";
import { money } from "@/lib/party-reports";
import { formatMoney } from "@/lib/money";
import { parseFilters, withParams, type SalesSearchParams } from "@/lib/sales-report";

type Row = {
  period_start: string | null; is_total: boolean;
  gross_sales: number; discounts: number; returns_value: number; net_sales: number;
  cogs: number; gross_profit: number; operating_expenses: number; commissions: number; net_profit: number;
};
type Exp = { group_id: string; group_label: string; expense_count: number; total: number; in_profit_loss: number };

const monthLabel = (d: string) => new Date(d + "T00:00:00").toLocaleDateString("ar-EG", { month: "long", year: "numeric" });

export default async function ProfitLossPage(props: { searchParams: Promise<SalesSearchParams & { monthly?: string }> }) {
  const sp = await props.searchParams;
  const f = parseFilters(sp);
  const monthly = sp.monthly === "1";
  const { supabase, orgId, canViewFinancial, canExport } = await getReportContext();
  if (!orgId) return null;
  if (!canViewFinancial) return <NoFinancialAccess />;

  const [{ data, error }, { data: exp }] = await Promise.all([
    supabase.rpc("report_profit_loss", { org_id: orgId, p_from: f.from, p_to: f.to, p_by_month: monthly }),
    supabase.rpc("report_expenses", { org_id: orgId, p_from: f.from, p_to: f.to, p_group: "category" }),
  ]);
  if (error) return <p className="text-sm text-rose">{error.message}</p>;
  const rows = ((data as Row[]) ?? []).map((r) => ({ ...r, gross_sales: Number(r.gross_sales), discounts: Number(r.discounts), returns_value: Number(r.returns_value), net_sales: Number(r.net_sales), cogs: Number(r.cogs), gross_profit: Number(r.gross_profit), operating_expenses: Number(r.operating_expenses), commissions: Number(r.commissions), net_profit: Number(r.net_profit) }));
  const total = rows.find((r) => r.is_total);
  const expenses = ((exp as Exp[]) ?? []).map((e) => ({ ...e, in_profit_loss: Number(e.in_profit_loss) })).filter((e) => e.in_profit_loss > 0).sort((a, b) => b.in_profit_loss - a.in_profit_loss);

  const lines: { label: string; key: keyof Row; strong?: boolean; minus?: boolean }[] = [
    { label: "إجمالي المبيعات", key: "gross_sales" },
    { label: "الخصومات", key: "discounts", minus: true },
    { label: "المرتجعات", key: "returns_value", minus: true },
    { label: "صافي المبيعات", key: "net_sales", strong: true },
    { label: "تكلفة البضاعة المباعة", key: "cogs", minus: true },
    { label: "مجمل الربح", key: "gross_profit", strong: true },
    { label: "المصروفات التشغيلية", key: "operating_expenses", minus: true },
    { label: "العمولات المستحقة", key: "commissions", minus: true },
    { label: "صافي الربح / (الخسارة)", key: "net_profit", strong: true },
  ];
  const cols = rows;
  const margin = total && total.net_sales > 0 ? (total.net_profit / total.net_sales) * 100 : 0;

  return (
    <div>
      <PeriodFilter from={f.from} to={f.to} all={sp.all === "1" && !sp.from && !sp.to} />
      <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
        {canExport ? (
          <ExportButtons
            filename={`الأرباح-والخسائر-${f.from ?? "الكل"}-${f.to ?? "الآن"}`}
            headers={["البند", ...cols.map((c) => (c.is_total ? "الإجمالي" : c.period_start ? monthLabel(c.period_start) : ""))]}
            rows={lines.map((l) => [l.label, ...cols.map((c) => Number(c[l.key] ?? 0))])}
          />
        ) : (
          <span />
        )}
        <Link href={withParams(sp, { monthly: monthly ? "" : "1" })} scroll={false} className="no-print rounded-lg bg-paper px-3 py-1.5 text-xs text-charcoal/60 hover:text-charcoal">
          {monthly ? "عرض الإجمالي فقط" : "عرض شهري"}
        </Link>
      </div>

      <div className="mb-6 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="صافي المبيعات" value={<Money value={total?.net_sales} />} />
        <Stat label="مجمل الربح" value={<Money value={total?.gross_profit} />} />
        <Stat label="صافي الربح / (الخسارة)" value={<Money value={total?.net_profit} />} tone={(total?.net_profit ?? 0) < 0 ? "rose" : "sage"} />
        <Stat label="هامش صافي الربح" value={<span dir="ltr" className={`num ${margin < 0 ? "!text-rose" : ""}`}>{formatMoney(margin, 1)}٪</span>} />
      </div>

      <SimpleTable
        empty="لا توجد بيانات"
        head={["البند", ...cols.map((c) => (c.is_total ? "الإجمالي" : c.period_start ? monthLabel(c.period_start) : ""))]}
        rows={lines.map((l) => [
          <span key="l" className={l.strong ? "font-semibold" : "pr-3 text-charcoal/75"}>{l.minus ? "− " : ""}{l.label}</span>,
          ...cols.map((c, i) => {
            const v = Number(c[l.key] ?? 0);
            return <Money key={i} value={v} suffix="" className={l.strong ? "font-semibold" : ""} />;
          }),
        ])}
      />

      {expenses.length > 0 && (
        <Card className="mt-8 p-5">
          <p className="mb-3 text-sm font-medium text-charcoal">تفصيل المصروفات التشغيلية (للفترة كلها)</p>
          <ul className="space-y-2">
            {expenses.map((e) => (
              <li key={e.group_id} className="flex items-center justify-between text-sm">
                <span className="text-charcoal/80">{e.group_label}</span>
                <span dir="ltr" className="font-medium"><Money value={e.in_profit_loss} /></span>
              </li>
            ))}
          </ul>
          <p className="mt-3 text-[0.6875rem] text-charcoal/40">للتفصيل بالنوع والشهر راجع تبويب «المصروفات».</p>
        </Card>
      )}

      <div className="mt-6 space-y-2 text-xs text-charcoal/50">
        <p>
          <span className="font-medium text-charcoal/70">أساس الحساب:</span> ربح محاسبي (استحقاق) من الفواتير والمرتجعات والمصروفات والعمولات المستحقة، كلٌّ بتاريخ مستنده. هذا التقرير لا يعكس رصيد الخزنة ولا التدفق النقدي؛
          التحصيل والسداد وصرف العمولات لا تغيّر الربح، ولها{" "}
          <Link href="/dashboard/reports/treasury" className="text-sage hover:underline">تقرير الخزنة</Link>.
        </p>
        <p>
          صافي المبيعات = المبيعات − الخصومات − المرتجعات. تكلفة البضاعة = تكلفة ما بيع − تكلفة المرتجع الصالح لإعادة البيع (بمتوسط التكلفة المعتمد؛ المرتجع التالف لا تُسترد تكلفته).
          العمولة تُخصم مرة واحدة عند استحقاقها (بعد شرط الهدف)، وما يُصرف منها لاحقًا نقدي فقط. المرتبات المسجَّلة كمصروف تدخل ضمن المصروفات التشغيلية بتاريخ تسجيلها (لا يوجد استحقاق مرتبات منفصل).
          الأرصدة الافتتاحية للعملاء والموردين ليست مبيعات ولا مصروفات ولا تدخل هنا.
        </p>
      </div>
    </div>
  );
}
