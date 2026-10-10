import Link from "next/link";
import { getReportContext } from "@/lib/report-context";
import { isRestrictedRep } from "@/lib/org-context";
import { BackLink, Section, SimpleTable, Stat, money } from "../../party-analysis";

const TYPE: Record<string, string> = { operating: "تشغيلي", rep_expense: "مصاريف مندوب", salary: "مرتب", commission_payout: "صرف عمولة" };

export default async function RepAnalysisPage(
  props: { params: Promise<{ id: string }>; searchParams: Promise<{ month?: string }> }
) {
  const searchParams = await props.searchParams;
  const params = await props.params;
  const { supabase, orgId } = await getReportContext();
  if (!orgId) return null;
  const month = /^\d{4}-\d{2}$/.test(searchParams.month ?? "") ? `${searchParams.month}-01` : new Date().toISOString().slice(0, 7) + "-01";
  const { data, error } = await supabase.rpc("report_rep_analysis", { org_id: orgId, p_rep_id: params.id, p_month: month });
  if (error || !data) return <p className="text-sm text-rose">{error?.message ?? "تعذّر تحميل التحليل"}</p>;

  const p = data.performance;
  const restricted = await isRestrictedRep();
  return (
    <div>
      {!restricted && <BackLink href="/dashboard/reports/reps" label="كل المناديب" />}
      <div className="mb-5 flex flex-wrap items-end justify-between gap-3">
        <h2 className="text-xl font-semibold text-charcoal">{data.rep.name}</h2>
        <form action={`/dashboard/reports/reps/${params.id}`} className="flex items-end gap-2">
          <input type="month" name="month" defaultValue={month.slice(0, 7)} className="h-10 rounded-xl border border-borderSoft px-3 text-sm" dir="ltr" />
          <button className="h-10 rounded-xl bg-sage px-4 text-sm font-medium text-white">عرض</button>
        </form>
      </div>

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Stat label="عدد الفواتير" value={p.invoices} />
        <Stat label="إجمالي المبيعات" value={money(p.gross_sales)} />
        <Stat label="المرتجعات" value={money(p.returns)} />
        <Stat label="صافي المبيعات" value={money(p.net_sales)} />
        <Stat label="التحصيلات" value={money(p.collected)} tone="sage" />
        <Stat label="العملاء المسؤول عنهم" value={data.customers.length} />
        <Stat label="مديونيات عملائه" value={`${money(data.customers_debt)} ج.م`} tone="rose" />
        <Stat label="Target الشهري" value={p.target > 0 ? `${money(p.target)} (${p.target_pct}%)` : "غير محدد"} />
      </div>

      <div className={`mt-4 rounded-2xl border px-5 py-4 text-sm ${p.min_target_met ? "border-moss/30 bg-moss/5 text-moss" : "border-rose/30 bg-rose/5 text-rose"}`}>
        {p.min_target > 0
          ? p.min_target_met
            ? `حقق الحد الأدنى المطلوب للعمولة (${money(p.min_target)} ج.م) — العمولة المستحقة هذا الشهر ${money(p.earned_commission)} ج.م`
            : `لم يحقق الحد الأدنى المطلوب للعمولة (${money(p.min_target)} ج.م) — المتبقي ${money(p.min_target - p.net_sales)} ج.م، العمولة المستحقة 0 (المحتملة ${money(p.potential_commission)})`
          : `لا يوجد حد أدنى للعمولة — العمولة المستحقة ${money(p.earned_commission)} ج.م`}
      </div>
      <p className="mt-2 text-xs text-charcoal/50">
        {restricted
          ? `العمولة المستحقة (كل الشهور): ${money(data.commission.earned)} ج.م`
          : `العمولة (كل الشهور): مستحقة ${money(data.commission.earned)} · مصروفة ${money(data.commission.paid)} · متبقية للصرف ${money(data.commission.payable)}`}
      </p>

      <Section title="العملاء ومديونياتهم">
        <SimpleTable empty="لا يوجد عملاء مرتبطون بهذا المندوب" head={["العميل", "المبيعات", "المدفوع", "المرتجعات", "المديونية"]}
          rows={data.customers.map((c: { id: string; name: string; total_sales: number; paid: number; returned: number; debt: number }) => [
            <Link key="n" href={`/dashboard/reports/customers/${c.id}`} className="text-sage hover:underline">{c.name}</Link>,
            <span dir="ltr" key="a">{money(c.total_sales)}</span>, <span dir="ltr" key="b">{money(c.paid)}</span>, <span dir="ltr" key="c">{money(c.returned)}</span>, <span dir="ltr" key="d" className="font-medium text-rose">{money(c.debt)}</span>,
          ])} />
      </Section>

      <Section title="فواتير الشهر">
        <SimpleTable empty="لا توجد فواتير في هذا الشهر" head={["التاريخ", "رقم الفاتورة", "العميل", "الإجمالي", "المدفوع", "خصومات", "Bonus"]}
          rows={data.invoices.map((i: { id: string; invoice_date: string; invoice_number: string | null; customer: string; total: number; amount_paid: number; discount_total: number; bonus_units: number }) => [
            <span dir="ltr" key="d">{i.invoice_date}</span>, i.invoice_number ?? "—", i.customer, <span dir="ltr" key="t">{money(i.total)}</span>, <span dir="ltr" key="p">{money(i.amount_paid)}</span>, money(i.discount_total), i.bonus_units || "—",
          ])} />
      </Section>

      <Section title="آخر 12 شهرًا">
        <SimpleTable empty="لا توجد بيانات" head={["الشهر", "الفواتير", "صافي المبيعات", "المرتجعات", "التحصيل", "الحد الأدنى", "العمولة المستحقة"]}
          rows={data.months.map((m: { month: string; invoices: number; net_sales: number; returns: number; collected: number; eligible: boolean; earned_commission: number }) => [
            <span dir="ltr" key="m">{String(m.month).slice(0, 7)}</span>, m.invoices, <span dir="ltr" key="n">{money(m.net_sales)}</span>, <span dir="ltr" key="r">{money(m.returns)}</span>, <span dir="ltr" key="c">{money(m.collected)}</span>,
            m.eligible ? "✓" : "✗", <span dir="ltr" key="e">{money(m.earned_commission)}</span>,
          ])} />
      </Section>

      {!restricted && (
      <Section title="مصاريف / مرتبات / صرف عمولة">
        <SimpleTable empty="لا توجد مصروفات مسجلة" head={["التاريخ", "النوع", "المبلغ", "الوصف"]}
          rows={data.expenses.map((e: { date: string; type: string; amount: number; description: string | null }) => [<span dir="ltr" key="d">{e.date}</span>, TYPE[e.type] ?? e.type, <span dir="ltr" key="a">{money(e.amount)}</span>, e.description ?? "—"])} />
      </Section>
      )}
    </div>
  );
}
