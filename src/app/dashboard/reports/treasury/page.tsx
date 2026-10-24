import { Money } from "@/components/ui/money";
import { formatMoney } from "@/lib/money";
import { getReportContext } from "@/lib/report-context";
import { Card } from "@/components/ui/card";
import { DataTable } from "@/components/ui/data-table";
import { NoFinancialAccess } from "@/components/reports/no-financial-access";
import { PeriodSelect } from "@/components/reports/period-select";
import { ExportButtons } from "@/components/ui/export-buttons";
import { resolvePeriod } from "@/lib/report-period";
import Link from "next/link";

function money(n: number) {
  return formatMoney(n);
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

export default async function TreasuryReportPage(props: { searchParams: Promise<{ period?: string; m?: string; y?: string }> }) {
  const searchParams = await props.searchParams;
  const period = resolvePeriod(searchParams); // any month / year / all time
  const { from, to } = period;

  const { supabase, orgId, canViewFinancial, canExport } = await getReportContext();
  if (!orgId) return null;
  if (!canViewFinancial) return <NoFinancialAccess />;

  const [{ data: summary }, { data: movements }, { data: recon }] = await Promise.all([
    supabase.rpc("report_treasury_summary", { org_id: orgId, p_from: from, p_to: to }),
    supabase.rpc("report_treasury_movements", { org_id: orgId, p_from: from, p_to: to, p_limit: 100, p_offset: 0 }),
    supabase.rpc("report_cash_reconciliation", { org_id: orgId, p_from: from, p_to: to }),
  ]);

  const s = summary as { opening: number; total_in: number; total_out: number; closing: number; accounts: { id: string; name: string; balance: number }[]; sales_collections: number; recorded_expenses: number; collections_minus_expenses: number; expenses_by_type: { type: string; total: number }[]; by_category: { category: string; direction: "in" | "out"; total: number }[] } | null;
  const checks = ((recon as { check_key: string; check_label: string; treasury_amount: number; source_amount: number; difference: number }[]) ?? []).map((c) => ({ ...c, treasury_amount: Number(c.treasury_amount), source_amount: Number(c.source_amount), difference: Number(c.difference) }));
  const inCats = (s?.by_category ?? []).filter((c) => c.direction === "in");
  const outCats = (s?.by_category ?? []).filter((c) => c.direction === "out");
  const mismatched = checks.filter((c) => Math.abs(c.difference) > 0.005);
  const rows = (movements as MovementRow[]) ?? [];

  return (
    <div>
      <div className="mb-6 flex items-center justify-end">
        <PeriodSelect period={period} />
      </div>

      <div className="mb-7 grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Card className="p-4">
          <p className="text-[0.6875rem] text-charcoal/45">الرصيد الافتتاحي</p>
          <p className="mt-1.5 text-xl font-semibold text-charcoal"><Money value={s?.opening ?? 0} /></p>
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
          <p className="mt-1.5 text-xl font-semibold text-charcoal"><Money value={s?.closing ?? 0} /></p>
        </Card>
      </div>

      <Card className="mb-7 p-5">
        <p className="mb-3 text-xs font-medium text-charcoal/40">المقبوضات من المبيعات مقابل المصروفات المسجلة</p>
        <div className="grid grid-cols-1 gap-x-8 gap-y-2 text-sm sm:grid-cols-2">
          <div className="flex items-center justify-between"><span className="text-charcoal/60">مقبوضات المبيعات</span><span className="text-sage" dir="ltr">{money(s?.sales_collections ?? 0)} ج.م</span></div>
          {(s?.expenses_by_type ?? []).map((e) => (
            <div key={e.type} className="flex items-center justify-between"><span className="text-charcoal/60">− {EXPENSE_TYPE[e.type] ?? e.type}</span><span className="text-rose" dir="ltr">{money(e.total)} ج.م</span></div>
          ))}
          <div className="flex items-center justify-between border-t border-borderSoft pt-2 font-semibold sm:col-span-2"><span className="text-charcoal">المقبوضات بعد المصروفات</span><Money value={s?.collections_minus_expenses ?? 0} /></div>
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
      <div className="mb-7 grid grid-cols-1 gap-4 lg:grid-cols-2">
        <Card className="p-5">
          <p className="mb-3 text-sm font-medium text-charcoal">التحصيلات الإجمالية حسب المصدر</p>
          {inCats.length === 0 ? <p className="text-sm text-charcoal/40">لا توجد تحصيلات</p> : (
            <ul className="space-y-2">
              {inCats.map((c) => (
                <li key={c.category} className="flex items-center justify-between text-sm">
                  <span className="text-charcoal/80">{CATEGORY_LABEL[c.category] ?? c.category}</span>
                  <span dir="ltr" className="font-medium text-sage">{money(Number(c.total))} ج.م</span>
                </li>
              ))}
              <li className="flex items-center justify-between border-t border-borderSoft pt-2 text-sm font-semibold"><span>الإجمالي</span><span dir="ltr">{money(s?.total_in ?? 0)} ج.م</span></li>
            </ul>
          )}
        </Card>
        <Card className="p-5">
          <p className="mb-3 text-sm font-medium text-charcoal">المدفوعات الإجمالية حسب النوع</p>
          {outCats.length === 0 ? <p className="text-sm text-charcoal/40">لا توجد مدفوعات</p> : (
            <ul className="space-y-2">
              {outCats.map((c) => (
                <li key={c.category} className="flex items-center justify-between text-sm">
                  <span className="text-charcoal/80">{CATEGORY_LABEL[c.category] ?? c.category}</span>
                  <span dir="ltr" className="font-medium text-rose">{money(Number(c.total))} ج.م</span>
                </li>
              ))}
              <li className="flex items-center justify-between border-t border-borderSoft pt-2 text-sm font-semibold"><span>الإجمالي</span><span dir="ltr">{money(s?.total_out ?? 0)} ج.م</span></li>
            </ul>
          )}
        </Card>
      </div>
      <p className="-mt-3 mb-7 text-xs text-charcoal/45" dir="rtl">
        المتبقي (الرصيد الختامي) = الرصيد الافتتاحي + التحصيلات − المدفوعات. هذا رصيد نقدي وليس ربحًا: التحصيل والسداد وصرف العمولات لا تغيّر الربح، وللربح{" "}
        <Link href="/dashboard/reports/profit-loss" className="text-sage hover:underline">تقرير الأرباح والخسائر</Link>.
      </p>

      <Card className="mb-7 p-5">
        <p className="mb-1 text-sm font-medium text-charcoal">مطابقة الخزنة مع المستندات</p>
        <p className="mb-3 text-xs text-charcoal/45">كل تحصيل أو دفعة أو مصروف يُسجَّل في الخزنة بدوال النظام؛ هنا يُقارن إجمالي حركات الخزنة بإجمالي المستندات المنشئة لها في نفس الفترة.</p>
        <ul className="space-y-1.5">
          {checks.map((c) => (
            <li key={c.check_key} className="flex flex-wrap items-center justify-between gap-2 text-sm">
              <span className="text-charcoal/80">{c.check_label}</span>
              <span className="flex items-center gap-3">
                <span dir="ltr" className="text-xs text-charcoal/50">خزنة {formatMoney(c.treasury_amount)} / مستندات {formatMoney(c.source_amount)}</span>
                {Math.abs(c.difference) > 0.005
                  ? <span className="rounded-md bg-rose/10 px-2 py-0.5 text-xs font-medium text-rose">فرق {money(c.difference)}</span>
                  : <span className="rounded-md bg-sageSoft px-2 py-0.5 text-xs font-medium text-sage">مطابق</span>}
              </span>
            </li>
          ))}
        </ul>
        {mismatched.length > 0 && <p className="mt-3 text-xs text-rose">يوجد فرق: حركة خزنة بلا مستند مطابق أو العكس. الحركات اليدوية (إيراد/مصروف آخر) لا تدخل في هذه المقارنة.</p>}
      </Card>

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
