import { getReportContext } from "@/lib/report-context";
import { NoFinancialAccess } from "@/components/reports/no-financial-access";
import { Card } from "@/components/ui/card";
import { ExportButtons } from "@/components/ui/export-buttons";
import { Stat, SimpleTable, Section } from "../party-analysis";
import { dateText, money } from "@/lib/party-reports";
import { PeriodSelect } from "@/components/reports/period-select";
import { resolvePeriod } from "@/lib/report-period";

type Pay = {
  rep_id: string; rep_name: string; is_active: boolean;
  fixed_salary: number; transportation_allowance: number; commission_basis: string; commission_rate: number;
  invoices: number; net_sales: number; commission_eligible: boolean;
  sales_commission: number; collection_commission: number; earned_commission: number;
  salary_paid: number; commission_paid: number; rep_expenses_paid: number;
  collections_count: number; collected_amount: number; first_collection_date: string | null; last_collection_date: string | null;
  commission_payable: number;
};
type Col = { collection_id: string; collection_date: string; rep_name: string; customer_name: string; amount: number; payment_method: string | null; reference: string | null; invoice_number: string | null; counts_for_commission: boolean | null };

const BASIS: Record<string, string> = { sales_value: "قيمة المبيعات", net_sales: "صافي المبيعات", gross_profit: "مجمل الربح", collected_amount: "المبلغ المحصّل" };
const shiftMonth = (ym: string, delta: number) => {
  const [y, m] = ym.split("-").map(Number);
  const d = new Date(Date.UTC(y, m - 1 + delta, 1));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
};

export default async function PayrollReportPage(props: { searchParams: Promise<{ period?: string; m?: string; month?: string }> }) {
  const sp = await props.searchParams;
  // payroll is monthly: always a single month (the old ?month= link still works)
  const sel = resolvePeriod({ period: "month", m: sp.m ?? sp.month });
  const month = sel.month as string;
  const start = `${month}-01`;
  const end = `${shiftMonth(month, 1)}-01`;
  const lastDay = new Date(new Date(end + "T00:00:00Z").getTime() - 86400000).toISOString().slice(0, 10);

  const { supabase, orgId, canViewFinancial, canExport } = await getReportContext();
  if (!orgId) return null;
  if (!canViewFinancial) return <NoFinancialAccess />;

  const [{ data, error }, { data: cols }] = await Promise.all([
    supabase.rpc("report_rep_payroll", { org_id: orgId, p_month: start }),
    supabase.rpc("report_rep_collections", { org_id: orgId, p_from: start, p_to: lastDay, p_limit: 500, p_offset: 0 }),
  ]);
  if (error) return <p className="text-sm text-rose">{error.message}</p>;
  const rows = ((data as Pay[]) ?? []).map((r) => ({
    ...r, fixed_salary: Number(r.fixed_salary), transportation_allowance: Number(r.transportation_allowance), sales_commission: Number(r.sales_commission), collection_commission: Number(r.collection_commission),
    earned_commission: Number(r.earned_commission), salary_paid: Number(r.salary_paid), commission_paid: Number(r.commission_paid), rep_expenses_paid: Number(r.rep_expenses_paid),
    collections_count: Number(r.collections_count), collected_amount: Number(r.collected_amount), commission_payable: Number(r.commission_payable), commission_rate: Number(r.commission_rate),
  }));
  const collections = ((cols as Col[]) ?? []).map((c) => ({ ...c, amount: Number(c.amount) }));
  const t = rows.reduce(
    (a, r) => ({ base: a.base + r.fixed_salary + r.transportation_allowance, earned: a.earned + r.earned_commission, paid: a.paid + r.salary_paid + r.commission_paid, collected: a.collected + r.collected_amount }),
    { base: 0, earned: 0, paid: 0, collected: 0 },
  );
  const monthName = new Date(start + "T00:00:00").toLocaleDateString("ar-EG", { month: "long", year: "numeric" });

  return (
    <div>
      <div className="no-print mb-5">
        <PeriodSelect period={sel} monthOnly />
      </div>

      <div className="mb-3 flex items-center justify-between">
        <p className="text-sm font-medium text-charcoal">مرتبات وعمولات المناديب — {monthName}</p>
        {canExport && (
          <ExportButtons
            filename={`مرتبات-المناديب-${month}`}
            headers={["المندوب", "الأساسي", "بدل الانتقال", "عمولة البيع", "عمولة التحصيل", "إجمالي العمولة المستحقة", "راتب مدفوع", "عمولات مدفوعة", "مصروفات مندوب", "مستحق عمولات (تراكمي)", "عدد التحصيلات", "المبلغ المحصّل", "أول تحصيل", "آخر تحصيل"]}
            rows={rows.map((r) => [r.rep_name, r.fixed_salary, r.transportation_allowance, r.sales_commission, r.collection_commission, r.earned_commission, r.salary_paid, r.commission_paid, r.rep_expenses_paid, r.commission_payable, r.collections_count, r.collected_amount, r.first_collection_date ?? "", r.last_collection_date ?? ""])}
          />
        )}
      </div>

      <div className="mb-6 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="الأساسي + بدل الانتقال (الشروط الحالية)" value={`${money(t.base)} ج.م`} />
        <Stat label="عمولات مستحقة عن الشهر" value={`${money(t.earned)} ج.م`} />
        <Stat label="مدفوع فعليًا (رواتب + عمولات)" value={`${money(t.paid)} ج.م`} />
        <Stat label="محصّل بواسطة المناديب" value={`${money(t.collected)} ج.م`} tone="sage" />
      </div>

      <Section title="المستحقات">
        <SimpleTable
          empty="لا يوجد مناديب"
          head={["المندوب", "الأساسي", "بدل الانتقال", "أساس العمولة", "عمولة البيع", "عمولة التحصيل", "إجمالي العمولة", "الهدف"]}
          rows={rows.map((r) => [
            r.rep_name,
            <span dir="ltr" key="f">{money(r.fixed_salary)}</span>,
            <span dir="ltr" key="t">{money(r.transportation_allowance)}</span>,
            <span key="b" className="text-xs">{BASIS[r.commission_basis] ?? r.commission_basis} × {r.commission_rate}٪</span>,
            <span dir="ltr" key="s">{r.sales_commission > 0 ? money(r.sales_commission) : "—"}</span>,
            <span dir="ltr" key="c">{r.collection_commission > 0 ? money(r.collection_commission) : "—"}</span>,
            <span dir="ltr" key="e" className="font-medium">{money(r.earned_commission)}</span>,
            r.commission_eligible ? <span key="g" className="rounded-md bg-sageSoft px-2 py-0.5 text-xs text-sage">محقق</span> : <span key="g" className="rounded-md bg-rose/10 px-2 py-0.5 text-xs text-rose">لم يتحقق — لا عمولة</span>,
          ])}
        />
      </Section>

      <Section title="المدفوع فعليًا في الشهر">
        <SimpleTable
          empty="لا توجد بيانات"
          head={["المندوب", "راتب مدفوع", "عمولات مدفوعة", "مصروفات مندوب (تعويض)", "مستحق عمولات (تراكمي)"]}
          rows={rows.map((r) => [
            r.rep_name,
            <span dir="ltr" key="a">{r.salary_paid > 0 ? money(r.salary_paid) : "—"}</span>,
            <span dir="ltr" key="b">{r.commission_paid > 0 ? money(r.commission_paid) : "—"}</span>,
            <span dir="ltr" key="c">{r.rep_expenses_paid > 0 ? money(r.rep_expenses_paid) : "—"}</span>,
            <span dir="ltr" key="d" className={`font-medium ${r.commission_payable > 0 ? "text-rose" : ""}`}>{money(r.commission_payable)}</span>,
          ])}
        />
      </Section>

      <Section title="التحصيلات ومواعيدها">
        <SimpleTable
          empty="لا توجد تحصيلات"
          head={["المندوب", "عدد التحصيلات", "المبلغ المحصّل", "أول تحصيل", "آخر تحصيل"]}
          rows={rows.map((r) => [r.rep_name, <span dir="ltr" key="n">{r.collections_count}</span>, <span dir="ltr" key="a">{money(r.collected_amount)}</span>, dateText(r.first_collection_date), dateText(r.last_collection_date)])}
        />
        {collections.length > 0 && (
          <Card className="mt-4 p-0">
            <SimpleTable
              empty=""
              head={["تاريخ التحصيل", "المندوب", "العميل", "المبلغ", "الطريقة", "الفاتورة", "تدخل في عمولة التحصيل"]}
              rows={collections.map((c) => [
                dateText(c.collection_date),
                c.rep_name,
                c.customer_name,
                <span dir="ltr" key="a" className="font-medium">{money(c.amount)}</span>,
                c.payment_method ?? "—",
                c.invoice_number ? <span dir="ltr" key="i">{c.invoice_number}</span> : <span key="i" className="text-charcoal/50">على الحساب</span>,
                c.counts_for_commission ? <span key="k" className="text-sage">نعم</span> : <span key="k" className="text-charcoal/40">لا</span>,
              ])}
            />
          </Card>
        )}
      </Section>

      <div className="mt-6 space-y-2 text-xs text-charcoal/50">
        <p>
          <span className="font-medium text-charcoal/70">العمولة:</span> تُحسب بنظام المندوب المسجَّل على كل فاتورة وقت إنشائها. «عمولة التحصيل» للفواتير التي أساس عمولتها «المبلغ المحصّل»، و«عمولة البيع» لباقي الأسس. تُنسب العمولة لشهر الفاتورة، وكل تحصيل لاحق مربوط بالفاتورة يرفعها. التحصيل «على الحساب» غير المربوط بفاتورة لا يدخل في عمولة التحصيل. تُطبَّق شروط الهدف الشهري؛ ما لم يتحقق هدفه لا يستحق عمولة.
        </p>
        <p>
          <span className="font-medium text-charcoal/70">الراتب الأساسي وبدل الانتقال</span> هما شروط المندوب الحالية (لا يوجد سجل تاريخي لتغيّرهما)، أما «راتب مدفوع» فهو ما سُجِّل فعلًا كمصروف مرتب. ما يُدفع من العمولة يخرج نقدًا فقط، ولا يخصم من الربح مرة ثانية.
        </p>
        <p>
          <span className="font-medium text-charcoal/70">العاملون غير المناديب:</span> النظام لا يحتفظ بسجل عاملين، فلا تظهر مرتباتهم هنا؛ إن سُجِّلت كمصروف تشغيلي فهي في تبويب «المصروفات».
          <span className="font-medium text-charcoal/70"> مواعيد التحصيل</span> هنا هي تواريخ التحصيل الفعلية، إذ لا توجد تواريخ استحقاق لفواتير العملاء لعرض جدول مستقبلي.
        </p>
      </div>
    </div>
  );
}
