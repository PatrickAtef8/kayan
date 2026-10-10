import { getReportContext } from "@/lib/report-context";
import { Card } from "@/components/ui/card";
import { DataTable } from "@/components/ui/data-table";
import { NoFinancialAccess } from "@/components/reports/no-financial-access";
import { PeriodSelect } from "@/components/reports/period-select";
import { ExportButtons } from "@/components/ui/export-buttons";
import { periodRange, type ReportPeriod } from "@/lib/report-period";

function money(n: number) {
  return n.toLocaleString("ar-EG", { minimumFractionDigits: 2 });
}

type MovementRow = {
  id: string;
  movement_date: string;
  direction: "in" | "out";
  amount: number;
  category: string;
  account_name: string;
  description: string | null;
};

const EXPENSE_TYPE: Record<string, string> = { operating: "مصروفات تشغيلية", rep_expense: "مصاريف مناديب", salary: "مرتبات", commission_payout: "عمولات مصروفة" };

const CATEGORY_LABEL: Record<string, string> = {
  customer_collection: "تحصيل من عميل",
  sales_cash: "بيع نقدي",
  supplier_payment: "دفعة لمورد",
  expense: "مصروف",
  partner_withdrawal: "سحب شريك",
  other_income: "إيراد آخر",
  other_payment: "مصروف آخر",
  sales_return: "استرجاع نقدي (مرتجع بيع)",
  purchase_return: "استرجاع نقدي (مرتجع شراء)",
};

export default async function TreasuryReportPage(props: { searchParams: Promise<{ period?: string }> }) {
  const searchParams = await props.searchParams;
  const period = (searchParams.period === "year" || searchParams.period === "all" ? searchParams.period : "month") as ReportPeriod;
  const { from, to } = periodRange(period);

  const { supabase, orgId, canViewFinancial, canExport } = await getReportContext();
  if (!orgId) return null;
  if (!canViewFinancial) return <NoFinancialAccess />;

  const [{ data: summary }, { data: movements }] = await Promise.all([
    supabase.rpc("report_treasury_summary", { org_id: orgId, p_from: from, p_to: to }),
    supabase.rpc("report_treasury_movements", { org_id: orgId, p_from: from, p_to: to, p_limit: 100, p_offset: 0 }),
  ]);

  const s = summary as { opening: number; total_in: number; total_out: number; closing: number; accounts: { id: string; name: string; balance: number }[]; sales_collections: number; recorded_expenses: number; collections_minus_expenses: number; expenses_by_type: { type: string; total: number }[] } | null;
  const rows = (movements as MovementRow[]) ?? [];

  return (
    <div>
      <div className="mb-6 flex items-center justify-end">
        <PeriodSelect period={period} />
      </div>

      <div className="mb-7 grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Card className="p-4">
          <p className="text-[0.6875rem] text-charcoal/45">الرصيد الافتتاحي</p>
          <p className="mt-1.5 text-xl font-semibold text-charcoal" dir="ltr">{money(s?.opening ?? 0)} ج.م</p>
        </Card>
        <Card className="p-4">
          <p className="text-[0.6875rem] text-charcoal/45">إجمالي الوارد</p>
          <p className="mt-1.5 text-xl font-semibold text-sage" dir="ltr">{money(s?.total_in ?? 0)} ج.م</p>
        </Card>
        <Card className="p-4">
          <p className="text-[0.6875rem] text-charcoal/45">إجمالي المنصرف</p>
          <p className="mt-1.5 text-xl font-semibold text-rose" dir="ltr">{money(s?.total_out ?? 0)} ج.م</p>
        </Card>
        <Card className="p-4">
          <p className="text-[0.6875rem] text-charcoal/45">الرصيد الختامي</p>
          <p className="mt-1.5 text-xl font-semibold text-charcoal" dir="ltr">{money(s?.closing ?? 0)} ج.م</p>
        </Card>
      </div>

      <Card className="mb-7 p-5">
        <p className="mb-3 text-xs font-medium text-charcoal/40">المقبوضات من المبيعات مقابل المصروفات المسجلة</p>
        <div className="grid grid-cols-1 gap-x-8 gap-y-2 text-sm sm:grid-cols-2">
          <div className="flex items-center justify-between"><span className="text-charcoal/60">مقبوضات المبيعات</span><span className="text-sage" dir="ltr">{money(s?.sales_collections ?? 0)} ج.م</span></div>
          {(s?.expenses_by_type ?? []).map((e) => (
            <div key={e.type} className="flex items-center justify-between"><span className="text-charcoal/60">− {EXPENSE_TYPE[e.type] ?? e.type}</span><span className="text-rose" dir="ltr">{money(e.total)} ج.م</span></div>
          ))}
          <div className="flex items-center justify-between border-t border-borderSoft pt-2 font-semibold sm:col-span-2"><span className="text-charcoal">المقبوضات بعد المصروفات</span><span dir="ltr">{money(s?.collections_minus_expenses ?? 0)} ج.م</span></div>
        </div>
      </Card>

      <div className="mb-4 flex items-center justify-between">
        <span className="text-xs font-medium text-charcoal/40">حركات الخزنة</span>
        {canExport && (
          <ExportButtons
            filename={`حركات-الخزنة-${from ?? "الكل"}-${to ?? "الآن"}`}
            headers={["التاريخ", "الحساب", "التصنيف", "المبلغ", "الاتجاه", "الوصف"]}
            rows={rows.map((r) => [r.movement_date, r.account_name, CATEGORY_LABEL[r.category] ?? r.category, r.amount, r.direction === "in" ? "وارد" : "منصرف", r.description ?? ""])}
          />
        )}
      </div>
      <DataTable<MovementRow>
        rows={rows}
        getRowKey={(r) => r.id}
        emptyLabel="لا توجد حركات في هذه الفترة"
        columns={[
          { header: "التاريخ", render: (r) => <span dir="ltr">{r.movement_date}</span> },
          { header: "الحساب", render: (r) => r.account_name },
          { header: "التصنيف", render: (r) => CATEGORY_LABEL[r.category] ?? r.category },
          {
            header: "المبلغ",
            render: (r) => (
              <span dir="ltr" className={r.direction === "in" ? "text-sage" : "text-rose"}>
                {r.direction === "in" ? "+" : "−"} {money(r.amount)} ج.م
              </span>
            ),
          },
          { header: "الوصف", render: (r) => r.description ?? "—" },
        ]}
      />
    </div>
  );
}
