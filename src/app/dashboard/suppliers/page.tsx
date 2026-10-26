import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { ActionForm, SubmitButton } from "@/components/ui/action-form";
import { SearchBox } from "@/components/ui/search-box";
import { Pagination } from "@/components/ui/pagination";
import { createSupplier } from "./actions";
import { getMembership } from "@/lib/org-context";
import { getOpeningBalances } from "@/lib/opening-balance";
import { SuppliersTable } from "./suppliers-table";

const PAGE_SIZE = 20;

type Supplier = { id: string; name: string; phone: string | null; payment_terms_days: number | null; opening_balance: number };
export type SupplierBalance = { supplier_id: string; total_purchases: number; total_paid: number; balance: number };

export default async function SuppliersPage(props: { searchParams: Promise<{ q?: string; page?: string }> }) {
  const searchParams = await props.searchParams;
  const supabase = await createClient();
  const membership = await getMembership();
  let canViewBalance = false;
  if (membership) {
    const checks = await Promise.all(
      ["view_financial", "suppliers.view_balance"].map((perm_key) => supabase.rpc("has_permission", { target_org: membership.organization_id, perm_key }))
    );
    canViewBalance = checks.some((c) => !!c.data);
  }
  const page = Math.max(1, Number(searchParams.page) || 1);
  const q = searchParams.q?.trim() ?? "";

  let suppliersQuery = supabase
    .from("suppliers")
    .select("id, name, phone, payment_terms_days", { count: "exact" })
    .order("created_at", { ascending: false })
    .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
  if (q) suppliersQuery = suppliersQuery.or(`name.ilike.%${q}%,phone.ilike.%${q}%`);

  const [{ data: suppliers, count }, { data: balances }] = await Promise.all([
    suppliersQuery,
    supabase.from("supplier_balances").select("supplier_id, total_purchases, total_paid, balance"),
  ]);

  const openingMap = canViewBalance
    ? await getOpeningBalances(supabase, "supplier", (suppliers ?? []).map((s) => s.id as string))
    : new Map<string, number>();
  const suppliersView = (suppliers ?? []).map((s) => ({ ...s, opening_balance: openingMap.get(s.id as string) ?? 0 }));

  return (
    <div>
      <PageHeader title="الموردين" />

      <Card className="mb-7 p-5 sm:p-6">
        <ActionForm action={createSupplier} successText="تمت إضافة المورد بنجاح" className="grid grid-cols-1 gap-4 sm:grid-cols-5 sm:items-end">
          <Field label="اسم المورد">
            <Input name="name" required placeholder="مثال: مصنع الفا" />
          </Field>
          <Field label="رقم الهاتف">
            <Input name="phone" dir="ltr" placeholder="01000000000" />
          </Field>
          <Field label="مدة السداد (أيام)">
            <Input name="payment_terms_days" type="number" min="0" max="365" step="1" dir="ltr" placeholder="اختياري" />
          </Field>
          {canViewBalance && (
            <Field label="الرصيد الافتتاحي (اختياري)">
              <Input name="opening_balance" type="number" step="0.01" dir="ltr" defaultValue={0} placeholder="مبلغ مستحق للمورد من قبل" />
            </Field>
          )}
          <div className="self-end">
            <SubmitButton pendingText="جارٍ إضافة المورد...">إضافة مورد</SubmitButton>
          </div>
        </ActionForm>
      </Card>

      <div className="mb-4">
        <SearchBox placeholder="بحث بالاسم أو رقم الهاتف..." />
      </div>

      <SuppliersTable canViewBalance={canViewBalance} suppliers={suppliersView as unknown as Supplier[]} balances={(balances as SupplierBalance[]) ?? []} />
      <Pagination page={page} pageSize={PAGE_SIZE} totalCount={count ?? 0} />
    </div>
  );
}
