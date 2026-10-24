import Link from "next/link";
import { getReportContext } from "@/lib/report-context";
import { Card } from "@/components/ui/card";
import { ExportButtons } from "@/components/ui/export-buttons";
import { Stat, SimpleTable } from "../../party-analysis";
import { cairoToday, dateText, isoOrNull, money } from "@/lib/party-reports";

type Row = {
  supplier_id: string; supplier_name: string; phone: string | null; payment_terms_days: number | null;
  balance: number; overdue: number; not_due: number; undated: number; advance: number;
  overdue_invoices: number; oldest_overdue_date: string | null; max_days_overdue: number | null; next_due_date: string | null;
  last_payment_date: string | null; last_payment_amount: number | null;
};

export default async function SupplierDuesPage(props: { searchParams: Promise<{ as_of?: string; all?: string }> }) {
  const sp = await props.searchParams;
  const asOf = isoOrNull(sp.as_of) ?? cairoToday();
  const showAll = sp.all === "1";
  const { supabase, orgId, canExport } = await getReportContext();
  if (!orgId) return null;

  const { data, error } = await supabase.rpc("report_supplier_dues", { org_id: orgId, p_as_of: asOf, p_all: showAll });
  if (error) return <p className="text-sm text-rose">{error.message}</p>;
  const rows = ((data as Row[]) ?? []).map((r) => ({
    ...r, balance: Number(r.balance), overdue: Number(r.overdue), not_due: Number(r.not_due), undated: Number(r.undated), advance: Number(r.advance),
  }));
  const t = rows.reduce((a, r) => ({ balance: a.balance + r.balance, overdue: a.overdue + r.overdue, notDue: a.notDue + r.not_due, undated: a.undated + r.undated, advance: a.advance + r.advance }), { balance: 0, overdue: 0, notDue: 0, undated: 0, advance: 0 });

  return (
    <div>
      <Card className="mb-5 p-4">
        <form className="flex flex-wrap items-end gap-3" action="/dashboard/reports/debts/supplier-dues">
          <label className="text-xs text-charcoal/50">
            كما في تاريخ
            <input type="date" name="as_of" defaultValue={asOf} dir="ltr" className="mt-1 block h-10 rounded-xl border border-borderSoft bg-white px-3 text-sm text-charcoal focus:border-sage focus:outline-none" />
          </label>
          <label className="flex items-center gap-2 pb-2 text-xs text-charcoal/60">
            <input type="checkbox" name="all" value="1" defaultChecked={showAll} /> إظهار الموردين برصيد صفري
          </label>
          <button className="h-10 rounded-xl bg-sage px-4 text-sm font-medium text-white">تطبيق</button>
        </form>
      </Card>

      {canExport && (
        <div className="mb-4">
          <ExportButtons
            filename={`استحقاقات-الموردين-${asOf}`}
            headers={["المورد", "مدة السداد (يوم)", "الرصيد", "متأخر", "لم يحن موعده", "بدون موعد", "دفعات مقدمة", "عدد الفواتير المتأخرة", "أقدم استحقاق متأخر", "أقصى تأخير (يوم)", "أقرب استحقاق قادم", "آخر دفعة", "مبلغ آخر دفعة"]}
            rows={rows.map((r) => [r.supplier_name, r.payment_terms_days ?? "", r.balance, r.overdue, r.not_due, r.undated, r.advance, r.overdue_invoices, r.oldest_overdue_date ?? "", r.max_days_overdue ?? "", r.next_due_date ?? "", r.last_payment_date ?? "", r.last_payment_amount ?? ""])}
          />
        </div>
      )}

      <div className="mb-6 grid grid-cols-2 gap-3 lg:grid-cols-5">
        <Stat label="إجمالي ما علينا" value={`${money(t.balance)} ج.م`} />
        <Stat label="متأخر السداد" value={`${money(t.overdue)} ج.م`} tone="rose" />
        <Stat label="لم يحن موعده" value={`${money(t.notDue)} ج.م`} />
        <Stat label="بدون موعد سداد" value={`${money(t.undated)} ج.م`} />
        <Stat label="دفعات مقدمة لموردين" value={`${money(t.advance)} ج.م`} tone="sage" />
      </div>

      <SimpleTable
        empty="لا توجد مستحقات للموردين"
        head={["المورد", "مدة السداد", "الرصيد", "متأخر", "أقدم تأخير", "لم يحن موعده", "أقرب استحقاق", "بدون موعد", "دفعة مقدمة", "آخر دفعة", ""]}
        rows={rows.map((r) => [
          <Link key="n" href={`/dashboard/reports/debts/statement/supplier/${r.supplier_id}`} className="text-sage hover:underline">{r.supplier_name}</Link>,
          <span dir="ltr" key="t">{r.payment_terms_days === null ? "—" : `${r.payment_terms_days} يوم`}</span>,
          <span dir="ltr" key="b" className="font-medium">{money(r.balance)}</span>,
          <span dir="ltr" key="o" className={r.overdue > 0 ? "font-semibold text-rose" : ""}>{r.overdue > 0 ? money(r.overdue) : "—"}</span>,
          r.overdue > 0 ? <span key="od" className="text-xs text-rose">{r.overdue_invoices} فاتورة — {r.max_days_overdue} يوم</span> : "—",
          <span dir="ltr" key="nd">{r.not_due > 0 ? money(r.not_due) : "—"}</span>,
          <span key="nx" className="text-xs">{dateText(r.next_due_date)}</span>,
          <span dir="ltr" key="u">{r.undated > 0 ? money(r.undated) : "—"}</span>,
          <span dir="ltr" key="a">{r.advance > 0 ? money(r.advance) : "—"}</span>,
          <span key="lp" className="text-xs">{r.last_payment_date ? `${money(r.last_payment_amount)} (${dateText(r.last_payment_date)})` : "—"}</span>,
          <Link key="s" href={`/dashboard/reports/debts/statement/supplier/${r.supplier_id}`} className="text-xs text-sage hover:underline">كشف حساب</Link>,
        ])}
      />
      <p className="mt-4 text-xs text-charcoal/45">
        الرصيد = متأخر + لم يحن موعده + بدون موعد − دفعات مقدمة، ويساوي رصيد المورد في صفحة المديونيات. الدفعات غير المربوطة بفاتورة تُسدَّد بها الأقدم أولًا (الرصيد الافتتاحي ثم الفواتير بالتاريخ).
        الفواتير والرصيد الافتتاحي بلا موعد سداد (ومنها كل ما سُجّل قبل إضافة المواعيد) تظهر في «بدون موعد» ولا تُحتسب متأخرة. موعد الفاتورة يُسجَّل وقت إنشائها من مدة سداد المورد أو يُحدَّد يدويًا ولا يتغير بتغيير المدة لاحقًا.
      </p>
    </div>
  );
}
