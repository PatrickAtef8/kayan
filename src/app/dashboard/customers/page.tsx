import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Field, Input } from "@/components/ui/input";
import { ActionForm, SubmitButton } from "@/components/ui/action-form";
import { ModernSelect } from "@/components/ui/select";
import { SearchBox } from "@/components/ui/search-box";
import { Pagination } from "@/components/ui/pagination";
import { createCustomer } from "./actions";
import { getMembership, getRoleKey, hasPermission, hasAnyPermission } from "@/lib/org-context";
import { getOpeningBalances } from "@/lib/opening-balance";
import { CustomersTable } from "./customers-table";

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
  price_tier: string;
  opening_balance: number;
  credit_status: string;
  sales_rep_id: string | null;
  sales_representatives: { name: string } | null;
};
export type CustomerBalance = { customer_id: string; total_sales: number; total_collected: number; balance: number };

export default async function CustomersPage(props: { searchParams: Promise<{ q?: string; page?: string }> }) {
  const searchParams = await props.searchParams;
  const supabase = await createClient();
  const membership = await getMembership();
  const page = Math.max(1, Number(searchParams.page) || 1);
  const q = searchParams.q?.trim() ?? "";

  let customersQuery = supabase
    .from("customers")
    .select("id, name, phone, price_tier, credit_status, sales_rep_id, sales_representatives(name)", { count: "exact" })
    .order("created_at", { ascending: false })
    .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
  if (q) customersQuery = customersQuery.or(`name.ilike.%${q}%,phone.ilike.%${q}%`);

  // Permission checks and the page's lists run in one batch (they used to be awaited one after the other).
  const [{ data: customers, count }, { data: reps }, canViewBalance, canCollect, canAssignRep, roleKey] = await Promise.all([
    customersQuery,
    supabase.from("sales_representatives").select("id, name, user_id").eq("is_active", true).order("name"),
    hasAnyPermission(["view_financial", "customers.view_balance"]),
    hasAnyPermission(["treasury.manage", "collections.record"]),
    hasPermission("sales.assign_any_rep"),
    getRoleKey(),
  ]);
  const isOwner = roleKey === "owner";   // only the owner creates customers and assigns them to reps

  // Balances and opening balances only for the (at most 20) customers on this page: the balance view aggregates
  // every invoice, collection and return, so asking it for the whole customer list on each page view was wasteful.
  const pageIds = (customers ?? []).map((c) => c.id as string);
  const [{ data: balances }, openingMap, teamRes] = await Promise.all([
    pageIds.length ? supabase.rpc("customer_balances_for", { p_ids: pageIds }) : Promise.resolve({ data: [] as CustomerBalance[] }),
    // opening balances come from their own protected table (0032); empty for roles that may not read it
    canViewBalance ? getOpeningBalances(supabase, "customer", pageIds) : Promise.resolve(new Map<string, number>()),
    isOwner && membership ? supabase.rpc("list_org_members", { org_id: membership.organization_id }) : Promise.resolve({ data: null }),
  ]);

  // Show each rep as "name — email" (the email of the login linked to the record) so two reps with similar
  // names can never be confused when assigning a customer. Only the owner can list the team; others get names only.
  const emailByUser = new Map<string, string>();
  for (const m of (teamRes.data as { user_id: string; email: string }[] | null) ?? []) emailByUser.set(m.user_id, m.email);
  const repOptions = (reps ?? []).map((r) => {
    const email = r.user_id ? emailByUser.get(r.user_id as string) : undefined;
    return { id: r.id as string, name: email ? `${r.name} — ${email}` : (r.name as string) };
  });

  const customersView = (customers ?? []).map((c) => ({ ...c, opening_balance: openingMap.get(c.id as string) ?? 0 }));

  return (
    <div>
      <PageHeader title="العملاء" />

      {isOwner && <Card className="mb-7 p-5 sm:p-6">
        <ActionForm action={createCustomer} successText="تمت إضافة العميل بنجاح" className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4 lg:items-end">
          <Field label="اسم العميل">
            <Input name="name" required placeholder="مثال: محل الأمل" />
          </Field>
          <Field label="رقم الهاتف">
            <Input name="phone" dir="ltr" placeholder="01000000000" />
          </Field>
          <Field label="نوع العميل">
            <ModernSelect name="price_tier" defaultValue="retail" allowClear={false} options={PRICE_TIER_OPTIONS} />
          </Field>
          {canAssignRep && (<Field label="المندوب المسؤول">
            <ModernSelect name="sales_rep_id" placeholder="بدون مندوب" clearLabel="بدون مندوب" options={repOptions.map((r) => ({ value: r.id, label: r.name }))} />
            {repOptions.length === 0 && <p className="mt-1.5 text-xs text-rose">لا يوجد مناديب بعد — أضف مندوبًا من صفحة المندوبين.</p>}
          </Field>)}
          {canViewBalance && (
            <Field label="الرصيد الافتتاحي (اختياري)">
              <Input name="opening_balance" type="number" step="0.01" dir="ltr" defaultValue={0} placeholder="مبلغ مستحق من قبل" />
            </Field>
          )}
          <div className="col-span-full [&>button]:w-full sm:[&>button]:w-auto">
            <SubmitButton pendingText="جارٍ إضافة العميل...">إضافة عميل</SubmitButton>
          </div>
        </ActionForm>
      </Card>}

      {isOwner && <p className="mb-3 text-xs text-charcoal/45">لتعيين عميل لمندوب: اضغط أيقونة التعديل ✎ بجوار العميل ثم اختر «المندوب المسؤول» واحفظ.</p>}

      <div className="mb-4">
        <SearchBox placeholder="بحث بالاسم أو رقم الهاتف..." />
      </div>

      <CustomersTable canAssignRep={canAssignRep && isOwner} canViewBalance={canViewBalance} canCollect={canCollect} customers={customersView as unknown as Customer[]} balances={(balances as CustomerBalance[]) ?? []} reps={repOptions} />
      <Pagination page={page} pageSize={PAGE_SIZE} totalCount={count ?? 0} />
    </div>
  );
}
