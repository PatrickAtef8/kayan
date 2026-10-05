import { getReportContext } from "@/lib/report-context";
import { BackLink, InvoiceList, PaymentsReturnsNotes, Section, Stat, money, type AnalysisInvoice } from "../../party-analysis";

export default async function CustomerAnalysisPage({ params }: { params: { id: string } }) {
  const { supabase, orgId } = await getReportContext();
  if (!orgId) return null;
  const { data, error } = await supabase.rpc("report_customer_analysis", { org_id: orgId, p_customer_id: params.id });
  if (error || !data) return <p className="text-sm text-rose">{error?.message ?? "تعذّر تحميل التحليل"}</p>;

  const c = data.customer;
  const t = data.totals;
  return (
    <div>
      <BackLink href="/dashboard/reports/debts" label="تقرير المديونيات" />
      <div className="mb-5">
        <h2 className="text-xl font-semibold text-charcoal">{c.name}</h2>
        <p className="mt-1 text-sm text-charcoal/55">
          المندوب المسؤول: <span className="font-medium text-charcoal">{c.rep_name ?? "غير محدد"}</span>
          {c.phone && <span className="mr-4" dir="ltr">{c.phone}</span>}
        </p>
      </div>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Stat label="عدد الفواتير" value={t.invoices} />
        <Stat label="إجمالي المبيعات (قبل الخصم)" value={money(t.gross_sales)} />
        <Stat label="صافي المبيعات" value={money(t.net_sales)} />
        <Stat label="إجمالي الخصومات" value={money(t.discounts)} />
        <Stat label="إجمالي الـBonus (قطعة)" value={t.bonus_units} />
        <Stat label="إجمالي المدفوعات" value={money(t.payments)} tone="sage" />
        <Stat label="إجمالي المرتجعات" value={money(t.returns)} />
        <Stat label="المديونية الحالية" value={`${money(t.debt)} ج.م`} tone={t.debt > 0 ? "rose" : undefined} />
      </div>
      <p className="mt-2 text-xs text-charcoal/45">
        المديونية = رصيد افتتاحي ({money(c.opening_balance)}) + قيمة الفواتير ({money(t.billed)}) − المدفوعات − المرتجعات. خصومات: أصناف {money(t.line_discounts)} · فاتورة {money(t.invoice_discounts)} · شرائح {money(t.tier_discounts)} · نقدي {money(t.cash_discounts)}.
      </p>
      <Section title={`الفواتير (${data.invoices.length})`}>
        <InvoiceList invoices={data.invoices as AnalysisInvoice[]} kind="sales" notes={data.notes} partyId={c.id} />
      </Section>
      <PaymentsReturnsNotes payments={data.payments} returns={data.returns} notes={data.notes} party={{ type: "customer", id: c.id }} />
    </div>
  );
}
