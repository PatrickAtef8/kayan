import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { SearchBox } from "@/components/ui/search-box";
import { Pagination } from "@/components/ui/pagination";
import { createSupplier } from "./actions";
import { SuppliersTable } from "./suppliers-table";
import { ImportSuppliersButton } from "./import-suppliers-button";

const PAGE_SIZE = 20;

type Supplier = { id: string; name: string; phone: string | null; opening_balance: number };
export type SupplierBalance = { supplier_id: string; total_purchases: number; total_paid: number; balance: number };

export default async function SuppliersPage({ searchParams }: { searchParams: { q?: string; page?: string } }) {
  const supabase = createClient();
  const page = Math.max(1, Number(searchParams.page) || 1);
  const q = searchParams.q?.trim() ?? "";

  let suppliersQuery = supabase
    .from("suppliers")
    .select("id, name, phone, opening_balance", { count: "exact" })
    .order("created_at", { ascending: false })
    .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
  if (q) suppliersQuery = suppliersQuery.or(`name.ilike.%${q}%,phone.ilike.%${q}%`);

  const [{ data: suppliers, count }, { data: balances }] = await Promise.all([
    suppliersQuery,
    supabase.from("supplier_balances").select("supplier_id, total_purchases, total_paid, balance"),
  ]);

  return (
    <div>
      <PageHeader title="الموردين" action={<ImportSuppliersButton />} />

      <Card className="mb-7 p-5 sm:p-6">
        <form action={createSupplier} className="grid grid-cols-1 gap-4 sm:grid-cols-4 sm:items-end">
          <Field label="اسم المورد">
            <Input name="name" required placeholder="مثال: مصنع الفا" />
          </Field>
          <Field label="رقم الهاتف">
            <Input name="phone" dir="ltr" placeholder="01000000000" />
          </Field>
          <Field label="الرصيد الافتتاحي (اختياري)">
            <Input name="opening_balance" type="number" step="0.01" dir="ltr" defaultValue={0} placeholder="مبلغ مستحق للمورد من قبل" />
          </Field>
          <div className="self-end">
            <Button type="submit">إضافة مورد</Button>
          </div>
        </form>
      </Card>

      <div className="mb-4">
        <SearchBox placeholder="بحث بالاسم أو رقم الهاتف..." />
      </div>

      <SuppliersTable suppliers={(suppliers as Supplier[]) ?? []} balances={(balances as SupplierBalance[]) ?? []} />
      <Pagination page={page} pageSize={PAGE_SIZE} totalCount={count ?? 0} />
    </div>
  );
}
