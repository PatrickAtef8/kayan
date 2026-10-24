import { getSupabase, getMembership, NO_ORG_ID } from "@/lib/org-context";
import { PageHeader } from "@/components/ui/page-header";
import { Pagination } from "@/components/ui/pagination";
import { ExpensesTable } from "./expenses-table";
import { ExpenseForm } from "./expense-form";

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

export default async function ExpensesPage(props: { searchParams: Promise<{ page?: string }> }) {
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

      <ExpenseForm categories={categories ?? []} reps={reps ?? []} />

      <div className="mb-4 text-xs font-medium text-charcoal/40">سجل المصروفات المسجّلة</div>
      <ExpensesTable expenses={(expenses as unknown as ExpenseRow[]) ?? []} organizationId={membership?.organization_id ?? ""} />
      <Pagination page={page} pageSize={PAGE_SIZE} totalCount={count ?? 0} />
    </div>
  );
}
