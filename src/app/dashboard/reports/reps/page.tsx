import Link from "next/link";
import { getReportContext } from "@/lib/report-context";
import { Stat, SimpleTable, money } from "../party-analysis";

type Row = {
  rep_id: string; rep_name: string; is_active: boolean; invoices: number; gross_sales: number; discounts: number; returns: number; net_sales: number;
  collected: number; customers_count: number; customers_debt: number; monthly_target: number; target_pct: number | null; min_target: number;
  min_target_met: boolean; potential_commission: number; earned_commission: number; commission_paid: number; commission_payable: number;
};

export default async function RepsReportPage({ searchParams }: { searchParams: { month?: string } }) {
  const { supabase, orgId } = await getReportContext();
  if (!orgId) return null;
  const month = /^\d{4}-\d{2}$/.test(searchParams.month ?? "") ? `${searchParams.month}-01` : new Date().toISOString().slice(0, 7) + "-01";
  const { data, error } = await supabase.rpc("report_rep_overview", { org_id: orgId, p_month: month });
  if (error) return <p className="text-sm text-rose">{error.message}</p>;
  const rows = (data as Row[]) ?? [];
  const sum = (f: (r: Row) => number) => rows.reduce((a, r) => a + f(r), 0);

  return (
    <div>
      <form className="mb-5 flex items-end gap-3" action="/dashboard/reports/reps">
        <label className="text-xs text-charcoal/50">
          الشهر
          <input type="month" name="month" defaultValue={month.slice(0, 7)} className="mt-1 block h-10 rounded-xl border border-borderSoft px-3 text-sm text-charcoal" dir="ltr" />
        </label>
        <button className="h-10 rounded-xl bg-sage px-4 text-sm font-medium text-white">عرض</button>
      </form>
      <div className="mb-5 grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Stat label="صافي المبيعات" value={money(sum((r) => r.net_sales))} />
        <Stat label="التحصيلات" value={money(sum((r) => r.collected))} tone="sage" />
        <Stat label="مديونيات العملاء" value={money(sum((r) => r.customers_debt))} tone="rose" />
        <Stat label="عمولات مستحقة هذا الشهر" value={money(sum((r) => r.earned_commission))} />
      </div>
      <SimpleTable
        empty="لا يوجد مناديب"
        head={["المندوب", "الفواتير", "إجمالي المبيعات", "المرتجعات", "صافي المبيعات", "التحصيل", "العملاء", "مديونياتهم", "Target", "% Target", "الحد الأدنى للعمولة", "العمولة المستحقة", "المتبقي للصرف"]}
        rows={rows.map((r) => [
          <Link key="n" href={`/dashboard/reports/reps/${r.rep_id}?month=${month.slice(0, 7)}`} className="text-sage hover:underline">{r.rep_name}</Link>,
          r.invoices, <span dir="ltr" key="g">{money(r.gross_sales)}</span>, <span dir="ltr" key="r">{money(r.returns)}</span>, <span dir="ltr" key="n2" className="font-medium">{money(r.net_sales)}</span>,
          <span dir="ltr" key="c">{money(r.collected)}</span>, r.customers_count, <span dir="ltr" key="d">{money(r.customers_debt)}</span>,
          <span dir="ltr" key="t">{r.monthly_target > 0 ? money(r.monthly_target) : "—"}</span>, r.target_pct != null ? `${r.target_pct}%` : "—",
          r.min_target > 0 ? <span key="m" className={r.min_target_met ? "text-moss" : "text-rose"}>{r.min_target_met ? "✓ تحقق" : "✗ لم يتحقق"} ({money(r.min_target)})</span> : "بدون حد",
          <span dir="ltr" key="e">{money(r.earned_commission)}</span>, <span dir="ltr" key="p">{money(r.commission_payable)}</span>,
        ])}
      />
      <p className="mt-2 text-xs text-charcoal/45">العمولة تُستحق فقط لو صافي مبيعات الشهر (بعد الخصومات والمرتجعات) وصل للحد الأدنى. «المتبقي للصرف» = كل العمولات المستحقة − ما تم صرفه.</p>
    </div>
  );
}
