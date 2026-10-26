import { Money } from "@/components/ui/money";
import { formatMoney } from "@/lib/money";
import { getReportContext } from "@/lib/report-context";
import { Card } from "@/components/ui/card";
import { AlertTriangle, CheckCircle2 } from "lucide-react";
import { DataTable } from "@/components/ui/data-table";
import { NoFinancialAccess } from "@/components/reports/no-financial-access";
import { PeriodSelect } from "@/components/reports/period-select";
import { ExportButtons } from "@/components/ui/export-buttons";
import { resolvePeriod } from "@/lib/report-period";
import Link from "next/link";
import { rangeText } from "@/lib/export/model";

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
  const RECON_LABEL: Record<string, string> = {
    customer_receipts: "تحصيلات العملاء",
    supplier_payments: "مدفوعات الموردين",
    expenses: "المصروفات (تشمل المرتبات والعمولات المدفوعة)",
    partner_withdrawals: "مسحوبات الشركاء",
    customer_refunds: "مبالغ أُعيدت نقدًا للعملاء",
    supplier_refunds: "مبالغ استُردّت نقدًا من الموردين",
  };
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
          <p className="mt-1.5 text-xl font-semibold text-sage" dir="ltr"><Money value={s?.total_in ?? 0} /></p>
        </Card>
        <Card className="p-4">
          <p className="text-[0.6875rem] text-charcoal/45">إجمالي المنصرف</p>
          <p className="mt-1.5 text-xl font-semibold text-rose" dir="ltr"><Money value={s?.total_out ?? 0} /></p>
        </Card>
        <Card className="p-4">
          <p className="text-[0.6875rem] text-charcoal/45">الرصيد الختامي</p>
          <p className="mt-1.5 text-xl font-semibold text-charcoal"><Money value={s?.closing ?? 0} /></p>
        </Card>
      </div>

      <Card className="mb-7 p-5">
        <p className="mb-3 text-xs font-medium text-charcoal/40">المقبوضات من المبيعات مقابل المصروفات المسجلة</p>
        <div className="grid grid-cols-1 gap-x-8 gap-y-2 text-sm sm:grid-cols-2">
          <div className="flex items-center justify-between"><span className="text-charcoal/60">مقبوضات المبيعات</span><span className="text-sage" dir="ltr"><Money value={s?.sales_collections ?? 0} /></span></div>
          {(s?.expenses_by_type ?? []).map((e) => (
            <div key={e.type} className="flex items-center justify-between"><span className="text-charcoal/60">− {EXPENSE_TYPE[e.type] ?? e.type}</span><span className="text-rose" dir="ltr"><Money value={e.total} /></span></div>
          ))}
          <div className="flex items-center justify-between border-t border-borderSoft pt-2 font-semibold sm:col-span-2"><span className="text-charcoal">المقبوضات بعد المصروفات</span><Money value={s?.collections_minus_expenses ?? 0} /></div>
        </div>
      </Card>

      <div className="mb-4 flex items-center justify-between">
        <span className="text-xs font-medium text-charcoal/40">حركات الخزنة</span>
        {canExport && (
          <ExportButtons
            title="حركات الخزنة"
            subtitle={rangeText(from, to)}
            kinds={["date", "text", "text", "money", "text", "text"]}
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
                  <span dir="ltr" className="font-medium text-sage"><Money value={Number(c.total)} /></span>
                </li>
              ))}
              <li className="flex items-center justify-between border-t border-borderSoft pt-2 text-sm font-semibold"><span>الإجمالي</span><span dir="ltr"><Money value={s?.total_in ?? 0} /></span></li>
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
                  <span dir="ltr" className="font-medium text-rose"><Money value={Number(c.total)} /></span>
                </li>
              ))}
              <li className="flex items-center justify-between border-t border-borderSoft pt-2 text-sm font-semibold"><span>الإجمالي</span><span dir="ltr"><Money value={s?.total_out ?? 0} /></span></li>
            </ul>
          )}
        </Card>
      </div>
      <p className="-mt-3 mb-7 text-xs text-charcoal/45" dir="rtl">
        المتبقي (الرصيد الختامي) = الرصيد الافتتاحي + التحصيلات − المدفوعات. هذا رصيد نقدي وليس ربحًا: التحصيل والسداد وصرف العمولات لا تغيّر الربح، وللربح{" "}
        <Link href="/dashboard/reports/profit-loss" className="text-sage hover:underline">تقرير الأرباح والخسائر</Link>.
      </p>

      {/* Integrity check, written for a person who has never heard of it: it only needs attention when it turns red. */}
      <Card className={`mb-7 p-4 sm:p-5 ${mismatched.length > 0 ? "border-rose/30 bg-rose/5" : ""}`}>
        {mismatched.length === 0 ? (
          <div className="flex items-start gap-3">
            <CheckCircle2 size={20} strokeWidth={1.8} className="mt-0.5 shrink-0 text-sage" />
            <div className="min-w-0">
              <p className="text-sm font-medium text-charcoal">أرصدة الخزنة سليمة</p>
              <p className="mt-1 text-xs leading-6 text-charcoal/50">كل مبلغ دخل الخزنة أو خرج منها في هذه الفترة له عملية مسجلة في النظام (تحصيل، دفعة، مصروف…) بنفس القيمة، فلا يوجد مبلغ ظهر أو اختفى من الخزنة بدون سبب.</p>
            </div>
          </div>
        ) : (
          <div className="flex items-start gap-3">
            <AlertTriangle size={20} strokeWidth={1.8} className="mt-0.5 shrink-0 text-rose" />
            <div className="min-w-0">
              <p className="text-sm font-medium text-rose">يوجد فرق يحتاج مراجعة</p>
              <p className="mt-1 text-xs leading-6 text-charcoal/60">مبلغ في الخزنة لا يطابق العمليات المسجلة في النظام. هذا لا يحدث في الاستخدام العادي، وغالبًا يعني أن حركة أو رصيدًا تم تعديله خارج النظام. أرسل لنا هذه الصفحة لنراجعها معك.</p>
              <ul className="mt-3 space-y-2">
                {mismatched.map((c) => (
                  <li key={c.check_key} className="rounded-lg bg-white/70 px-3 py-2 text-xs text-charcoal/70">
                    <p className="mb-1 text-sm text-charcoal">{RECON_LABEL[c.check_key] ?? c.check_label}</p>
                    <p>
                      في الخزنة: <span dir="ltr" className="num">{formatMoney(c.treasury_amount)}</span> · في العمليات المسجلة: <span dir="ltr" className="num">{formatMoney(c.source_amount)}</span> · الفرق: <span dir="ltr" className="num font-medium text-rose">{formatMoney(c.difference)}</span>
                    </p>
                  </li>
                ))}
              </ul>
            </div>
          </div>
        )}
        <details className="group mt-3 border-t border-borderSoft/60 pt-3">
          <summary className="cursor-pointer list-none text-xs text-sage hover:underline">عرض التفاصيل</summary>
          <ul className="mt-3 space-y-2">
            {checks.map((c) => (
              <li key={c.check_key} className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1 text-xs text-charcoal/60">
                <span className="text-sm text-charcoal/80">{RECON_LABEL[c.check_key] ?? c.check_label}</span>
                <span>
                  في الخزنة <span dir="ltr" className="num">{formatMoney(c.treasury_amount)}</span> · في العمليات <span dir="ltr" className="num">{formatMoney(c.source_amount)}</span>
                </span>
              </li>
            ))}
          </ul>
          <p className="mt-3 text-[0.6875rem] leading-5 text-charcoal/40">المقارنة تخص العمليات التي يسجلها النظام نفسه. الحركات التي تضيفها يدويًا من «تسجيل حركة أخرى» لا تدخل فيها.</p>
        </details>
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
                {r.direction === "in" ? "+" : "−"} <Money value={r.amount} />
              </span>
            ),
          },
          { header: "الوصف", render: (r) => r.description ?? "—" },
        ]}
      />
    </div>
  );
}
