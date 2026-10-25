import { Money } from "@/components/ui/money";
import { getReportContext } from "@/lib/report-context";
import { BackLink, InvoiceList, PaymentsReturnsNotes, Section, Stat, money, type AnalysisInvoice } from "../../party-analysis";

export default async function SupplierAnalysisPage(props: { params: Promise<{ id: string }> }) {
  const params = await props.params;
  const { supabase, orgId } = await getReportContext();
  if (!orgId) return null;
  const { data, error } = await supabase.rpc("report_supplier_analysis", { org_id: orgId, p_supplier_id: params.id });
  if (error || !data) return <p className="text-sm text-rose">{error?.message ?? "تعذّر تحميل التحليل"}</p>;

  const s = data.supplier;
  const t = data.totals;
  return (
    <div>
      <BackLink href="/dashboard/reports/debts?type=supplier" label="مديونيات الموردين" />
      <div className="mb-5">
        <h2 className="text-xl font-semibold text-charcoal">{s.name}</h2>
        {s.phone && <p className="mt-1 text-sm text-charcoal/55" dir="ltr">{s.phone}</p>}
      </div>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Stat label="عدد فواتير الشراء" value={t.invoices} />
        <Stat label="إجمالي المشتريات (قبل الخصم)" value={<Money value={t.gross_purchases} suffix="" />} />
        <Stat label="صافي المشتريات" value={<Money value={t.net_purchases} suffix="" />} />
        <Stat label="إجمالي الخصومات" value={<Money value={t.discounts} suffix="" />} />
        <Stat label="إجمالي الـBonus (قطعة)" value={t.bonus_units} />
        <Stat label="المدفوع للمورد" value={<Money value={t.payments} suffix="" />} tone="sage" />
        <Stat label="مرتجعات للمورد" value={<Money value={t.returns} suffix="" />} />
        <Stat label="مديونية الشركة للمورد" value={<Money value={t.debt} />} tone={t.debt > 0 ? "rose" : undefined} />
      </div>
      <p className="mt-2 text-xs text-charcoal/45">
        المديونية = رصيد افتتاحي ({money(s.opening_balance)}) + قيمة الفواتير ({money(t.billed)}) − المدفوعات − المرتجعات. خصومات: أصناف {money(t.line_discounts)} · فاتورة {money(t.invoice_discounts)} · شرائح {money(t.tier_discounts)} · نقدي {money(t.cash_discounts)}.
      </p>
      <Section title={`فواتير الشراء (${data.invoices.length})`}>
        <InvoiceList invoices={data.invoices as AnalysisInvoice[]} kind="purchases" />
      </Section>
      <PaymentsReturnsNotes payments={data.payments} returns={data.returns} notes={data.notes} party={{ type: "supplier", id: s.id }} />
    </div>
  );
}
