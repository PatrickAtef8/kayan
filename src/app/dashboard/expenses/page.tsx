import { getSupabase, getMembership, NO_ORG_ID } from "@/lib/org-context";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ModernSelect } from "@/components/ui/select";
import { createExpense } from "./actions";
import { Pagination } from "@/components/ui/pagination";
import { ExpensesTable } from "./expenses-table";
import { EXPENSE_TYPE_LABELS } from "./expense-types";

const PAGE_SIZE = 20;

export type ExpenseRow = {
  id: string;
  amount: number;
  expense_date: string;
  payment_method: string | null;
  description: string | null;
  expense_categories: { name: string } | null;
  expense_type: string;
  sales_representatives: { name: string } | null;
};

export default async function ExpensesPage(props: { searchParams: Promise<{ page?: string; error?: string }> }) {
  const searchParams = await props.searchParams;
  const supabase = (await getSupabase());
  const page = Math.max(1, Number(searchParams.page) || 1);
  const membership = await getMembership();
  const orgId = membership?.organization_id ?? NO_ORG_ID;

  const [{ data: categories }, { data: reps }, { data: expenses, count }] = await Promise.all([
    supabase.from("expense_categories").select("id, name").eq("organization_id", orgId).order("name"),
    supabase.from("sales_representatives").select("id, name").eq("organization_id", orgId).eq("is_active", true).order("name"),
    supabase
      .from("expenses")
      .select("id, amount, expense_date, payment_method, description, expense_type, expense_categories(name), sales_representatives(name)", { count: "exact" })
      .eq("organization_id", orgId)
      .order("created_at", { ascending: false })
      .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1),
  ]);

  return (
    <div>
      <PageHeader title="المصروفات" />

      {searchParams.error && <p className="mb-4 rounded-xl bg-rose/10 px-4 py-3 text-sm text-rose">{searchParams.error}</p>}
      <Card className="mb-7 p-5 sm:p-6">
        <form action={createExpense} className="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <Field label="التصنيف">
            <ModernSelect name="category_id" placeholder="اختر تصنيفًا" options={(categories ?? []).map((c) => ({ value: c.id, label: c.name }))} />
          </Field>
          <Field label="أو تصنيف جديد">
            <Input name="new_category" placeholder="اكتب اسم تصنيف جديد" />
          </Field>
          <Field label="المبلغ">
            <Input name="amount" type="number" step="0.01" min="0" dir="ltr" required defaultValue={0} />
          </Field>

          <Field label="التاريخ">
            <Input name="expense_date" type="date" dir="ltr" defaultValue={new Date().toISOString().slice(0, 10)} />
          </Field>
          <Field label="طريقة الدفع">
            <Input name="payment_method" placeholder="نقدًا، تحويل بنكي..." defaultValue="نقدًا" />
          </Field>
          <Field label="الوصف">
            <Input name="description" placeholder="اختياري" />
          </Field>

          <Field label="نوع المصروف">
            <ModernSelect name="expense_type" allowClear={false} defaultValue="operating" options={Object.entries(EXPENSE_TYPE_LABELS).map(([value, label]) => ({ value, label }))} />
          </Field>
          <Field label="المندوب (لمصاريف المندوب / المرتب / صرف العمولة)">
            <ModernSelect name="sales_rep_id" placeholder="بدون مندوب" clearLabel="بدون مندوب" options={(reps ?? []).map((r) => ({ value: r.id, label: r.name }))} />
          </Field>
          <p className="self-end pb-3 text-xs text-charcoal/45">المرتب ومصاريف المندوب بتخصم من الخزنة ومن الربح. صرف العمولة بيخصم من الخزنة فقط لأن العمولة اتخصمت من الربح لما استُحقت.</p>

          <div className="sm:col-span-3">
            <Button type="submit">تسجيل المصروف</Button>
          </div>
        </form>
      </Card>

      <div className="mb-4 text-xs font-medium text-charcoal/40">سجل المصروفات</div>
      <ExpensesTable expenses={(expenses as unknown as ExpenseRow[]) ?? []} organizationId={membership?.organization_id ?? ""} />
      <Pagination page={page} pageSize={PAGE_SIZE} totalCount={count ?? 0} />
    </div>
  );
}
