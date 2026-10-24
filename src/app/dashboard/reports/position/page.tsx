import { getReportContext } from "@/lib/report-context";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { ActionForm, SubmitButton } from "@/components/ui/action-form";
import { ModernSelect } from "@/components/ui/select";
import { NoFinancialAccess } from "@/components/reports/no-financial-access";
import { addOtherBalance } from "./actions";
import { OtherBalancesList } from "./other-balances-list";

function money(n: number) {
  return n.toLocaleString("ar-EG", { minimumFractionDigits: 2 });
}

type Position = {
  inventory_value: number;
  receivables: number;
  cash: number;
  other_assets: number;
  payables: number;
  other_liabilities: number;
  net_position: number;
  general_capital: number;
  negative_stock_items: number;
  other_items: { id: string; kind: "asset" | "liability"; name: string; amount: number; notes: string | null }[];
};

export default async function FinancialPositionReportPage() {
  const { supabase, orgId, canViewFinancial } = await getReportContext();
  if (!orgId) return null;
  if (!canViewFinancial) return <NoFinancialAccess />;

  const { data } = await supabase.rpc("report_financial_position", { org_id: orgId });
  const p = data as Position | null;
  if (!p) return null;

  return (
    <div>
      <p className="mb-6 max-w-2xl text-xs leading-6 text-charcoal/45">
        هذا تقرير إداري يعبّر عن مركز العمل الحالي، وليس بالضرورة نفس تعريف حقوق الملكية المحاسبية الرسمية. راجع المحاسب
        لاعتماد التعريف النهائي.
      </p>

      <div className="mb-7 grid grid-cols-1 gap-5 lg:grid-cols-2">
        <Card className="p-5 sm:p-6">
          <p className="mb-4 text-xs font-medium text-charcoal/40">رأس المال العام</p>
          <Row label="قيمة المخزون" value={p.inventory_value} sign="+" />
          <Row label="مديونية السوق / العملاء" value={p.receivables} sign="+" />
          <Row label="الأرصدة النقدية" value={p.cash} sign="+" />
          <Row label="مديونية الموردين" value={p.payables} sign="-" />
          <Row label="التزامات أخرى" value={p.other_liabilities} sign="-" />
          <div className="mt-3 flex items-center justify-between border-t border-borderSoft pt-3 text-sm font-semibold text-charcoal">
            <span>رأس المال العام</span>
            <span dir="ltr">{money(p.general_capital)} ج.م</span>
          </div>
        </Card>

        <Card className="p-5 sm:p-6">
          <p className="mb-4 text-xs font-medium text-charcoal/40">صافي المركز المالي</p>
          <Row label="قيمة المخزون" value={p.inventory_value} sign="+" />
          <Row label="مديونية السوق / العملاء" value={p.receivables} sign="+" />
          <Row label="الأرصدة النقدية" value={p.cash} sign="+" />
          <Row label="أصول أخرى" value={p.other_assets} sign="+" />
          <Row label="مديونية الموردين" value={p.payables} sign="-" />
          <Row label="التزامات أخرى" value={p.other_liabilities} sign="-" />
          <div className="mt-3 flex items-center justify-between border-t border-borderSoft pt-3 text-sm font-semibold text-charcoal">
            <span>صافي المركز المالي</span>
            <span dir="ltr">{money(p.net_position)} ج.م</span>
          </div>
        </Card>
      </div>

      {p.negative_stock_items > 0 && (
        <div className="mb-7 rounded-xl border border-rose/20 bg-rose/5 px-4 py-3 text-xs text-rose">
          تنبيه: يوجد {p.negative_stock_items} منتج برصيد مخزون سالب — راجع حركات المخزون.
        </div>
      )}

      <Card className="p-5 sm:p-6">
        <p className="mb-4 text-xs font-medium text-charcoal/40">أصول والتزامات أخرى</p>
        <ActionForm action={addOtherBalance} successText="تمت الإضافة بنجاح" className="mb-5 grid grid-cols-1 gap-3 sm:grid-cols-4 sm:items-end">
          <Field label="النوع">
            <ModernSelect name="kind" allowClear={false} defaultValue="liability" options={[{ value: "asset", label: "أصل" }, { value: "liability", label: "التزام" }]} />
          </Field>
          <Field label="الاسم">
            <Input name="name" required placeholder="مثال: قرض بنكي" />
          </Field>
          <Field label="المبلغ">
            <Input name="amount" type="number" step="0.01" min="0" dir="ltr" required defaultValue={0} />
          </Field>
          <SubmitButton pendingText="جارٍ الإضافة...">إضافة</SubmitButton>
        </ActionForm>
        <OtherBalancesList items={p.other_items} />
      </Card>
    </div>
  );
}

function Row({ label, value, sign }: { label: string; value: number; sign: "+" | "-" }) {
  return (
    <div className="flex items-center justify-between py-1.5 text-sm text-charcoal/60">
      <span>{label}</span>
      <span dir="ltr">
        {sign} {money(value)}
      </span>
    </div>
  );
}
