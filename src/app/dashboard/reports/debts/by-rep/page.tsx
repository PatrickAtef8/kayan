import { Money } from "@/components/ui/money";
import Link from "next/link";
import { getReportContext } from "@/lib/report-context";
import { ExportButtons } from "@/components/ui/export-buttons";
import { Stat, SimpleTable } from "../../party-analysis";
import { money } from "@/lib/party-reports";

type Row = {
  group_id: string; group_label: string; is_total: boolean;
  customers: number; customers_with_debt: number;
  opening: number; sales: number; collected: number; returns_net: number;
  receivable: number; advances: number; net_balance: number;
};

export default async function ReceivablesByRepPage() {
  const { supabase, orgId, canExport } = await getReportContext();
  if (!orgId) return null;
  const { data, error } = await supabase.rpc("report_receivables_summary", { org_id: orgId });
  if (error) return <p className="text-sm text-rose">{error.message}</p>;
  const all = (data as Row[]) ?? [];
  const reps = all.filter((r) => !r.is_total);
  const total = all.find((r) => r.is_total);

  return (
    <div>
      <div className="mb-4 flex items-center justify-between">
        {canExport ? (
          <ExportButtons
            title="مديونيات العملاء حسب المندوب"
            kinds={["text", "int:sum", "int:sum", "money:sum", "money:sum", "money:sum", "money:sum", "money:sum", "money:sum", "money:sum"]}
            filename="مديونيات-العملاء-حسب-المندوب"
            headers={["المندوب", "العملاء", "عملاء عليهم مديونية", "رصيد افتتاحي", "المبيعات", "المحصّل", "المرتجعات (صافي)", "المستحق علينا للعملاء (دفعات مقدمة)", "المديونية (المستحق لنا)", "الصافي"]}
            rows={all.map((r) => [r.group_label, r.customers, r.customers_with_debt, r.opening, r.sales, r.collected, r.returns_net, r.advances, r.receivable, r.net_balance])}
          />
        ) : (
          <span />
        )}
      </div>

      <div className="mb-6 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat label="إجمالي المديونية (المستحق لنا)" value={<Money value={total?.receivable} />} tone="rose" />
        <Stat label="دفعات مقدمة من عملاء" value={<Money value={total?.advances} />} tone="sage" />
        <Stat label="الصافي" value={<Money value={total?.net_balance} />} />
        <Stat label="عملاء عليهم مديونية" value={`${total?.customers_with_debt ?? 0} من ${total?.customers ?? 0}`} />
      </div>

      <SimpleTable
        empty="لا توجد بيانات عملاء"
        head={["المندوب", "العملاء", "عليهم مديونية", "رصيد افتتاحي", "المبيعات", "المحصّل", "المرتجعات (صافي)", "المديونية", "دفعات مقدمة", "الصافي", ""]}
        rows={[...reps, ...(total ? [total] : [])].map((r) => [
          <span key="l" className={r.is_total ? "font-semibold" : ""}>{r.group_label}</span>,
          <span dir="ltr" key="c">{r.customers}</span>,
          <span dir="ltr" key="d">{r.customers_with_debt}</span>,
          <Money value={r.opening} suffix="" key="o" />,
          <Money value={r.sales} suffix="" key="s" />,
          <Money value={r.collected} suffix="" key="p" />,
          <Money value={r.returns_net} suffix="" key="rt" />,
          <Money value={r.receivable} suffix="" key="rc" className="font-semibold text-rose" />,
          <span dir="ltr" key="a">{r.advances > 0 ? money(r.advances) : "—"}</span>,
          <Money value={r.net_balance} suffix="" key="n" className="font-medium" />,
          !r.is_total && r.group_id !== "none" ? <Link key="k" href={`/dashboard/reports/debts?type=customer&rep=${r.group_id}`} className="text-xs text-sage hover:underline">العملاء</Link> : "",
        ])}
      />
      <p className="mt-4 text-xs text-charcoal/45">
        الصافي = رصيد افتتاحي + المبيعات − المحصّل − المرتجعات (بعد خصم المسترد نقدًا). «المديونية» مجموع أرصدة العملاء المدينين فقط، و«دفعات مقدمة» مجموع أرصدة من دفعوا أكثر من مستحقهم، فالصافي = المديونية − الدفعات المقدمة.
        يُنسب العميل للمندوب المسجَّل على بياناته (كما في صفحة المديونيات). يطابق إجمالي الشركة مجموع أرصدة العملاء.
      </p>
    </div>
  );
}
