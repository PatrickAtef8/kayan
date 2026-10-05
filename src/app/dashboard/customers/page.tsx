import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ModernSelect } from "@/components/ui/select";
import { SearchBox } from "@/components/ui/search-box";
import { Pagination } from "@/components/ui/pagination";
import { createCustomer } from "./actions";
import { CustomersTable } from "./customers-table";
import { ImportCustomersButton } from "./import-customers-button";

const PAGE_SIZE = 20;

const PRICE_TIER_OPTIONS = [
  { value: "retail", label: "تجزئة" },
  { value: "wholesale", label: "جملة" },
  { value: "distributor", label: "موزع" },
];

type Customer = {
  id: string;
  name: string;
  phone: string | null;
  customer_type: string | null;
  price_tier: string;
  opening_balance: number;
  credit_status: string;
  sales_rep_id: string | null;
  sales_representatives: { name: string } | null;
};
export type CustomerBalance = { customer_id: string; total_sales: number; total_collected: number; balance: number };

export default async function CustomersPage({ searchParams }: { searchParams: { q?: string; page?: string } }) {
  const supabase = createClient();
  const page = Math.max(1, Number(searchParams.page) || 1);
  const q = searchParams.q?.trim() ?? "";

  let customersQuery = supabase
    .from("customers")
    .select("id, name, phone, customer_type, price_tier, opening_balance, credit_status, sales_rep_id, sales_representatives(name)", { count: "exact" })
    .order("created_at", { ascending: false })
    .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
  if (q) customersQuery = customersQuery.or(`name.ilike.%${q}%,phone.ilike.%${q}%`);

  const [{ data: customers, count }, { data: balances }, { data: reps }] = await Promise.all([
    customersQuery,
    supabase.from("customer_balances").select("customer_id, total_sales, total_collected, balance"),
    supabase.from("sales_representatives").select("id, name").eq("is_active", true).order("name"),
  ]);

  return (
    <div>
      <PageHeader title="العملاء" action={<ImportCustomersButton />} />

      <Card className="mb-7 p-5 sm:p-6">
        <form action={createCustomer} className="grid grid-cols-1 gap-4 sm:grid-cols-4 sm:items-end">
          <Field label="اسم العميل">
            <Input name="name" required placeholder="مثال: محل الأمل" />
          </Field>
          <Field label="رقم الهاتف">
            <Input name="phone" dir="ltr" placeholder="01000000000" />
          </Field>
          <Field label="نوع العميل">
            <Input name="customer_type" placeholder="تجزئة، جملة..." />
          </Field>
          <Field label="مستوى السعر">
            <ModernSelect name="price_tier" defaultValue="retail" allowClear={false} options={PRICE_TIER_OPTIONS} />
          </Field>
          <Field label="المندوب المسؤول">
            <ModernSelect name="sales_rep_id" placeholder="بدون مندوب" clearLabel="بدون مندوب" options={(reps ?? []).map((r) => ({ value: r.id, label: r.name }))} />
          </Field>
          <Field label="الرصيد الافتتاحي (اختياري)">
            <Input name="opening_balance" type="number" step="0.01" dir="ltr" defaultValue={0} placeholder="مبلغ مستحق من قبل" />
          </Field>
          <div className="col-span-4">
            <Button type="submit">إضافة عميل</Button>
          </div>
        </form>
      </Card>

      <div className="mb-4">
        <SearchBox placeholder="بحث بالاسم أو رقم الهاتف..." />
      </div>

      <CustomersTable customers={(customers as unknown as Customer[]) ?? []} balances={(balances as CustomerBalance[]) ?? []} reps={reps ?? []} />
      <Pagination page={page} pageSize={PAGE_SIZE} totalCount={count ?? 0} />
    </div>
  );
}
