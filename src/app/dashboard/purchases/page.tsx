import { createClient } from "@/lib/supabase/server";
import { getMembership } from "@/lib/org-context";
import { canViewCost, getProductCosts } from "@/lib/costs";
import { PageHeader } from "@/components/ui/page-header";
import { SearchBox } from "@/components/ui/search-box";
import { DateRangeFilter } from "@/components/ui/date-range-filter";
import { Pagination } from "@/components/ui/pagination";
import { PurchasesTabs } from "@/components/purchases/purchases-tabs";
import { PurchaseForm } from "./purchase-form";
import { PurchasesTable } from "./purchases-table";

const PAGE_SIZE = 20;

export type ProductOption = { id: string; name: string; unit: string; cost: number };
export type PurchaseInvoiceRow = {
  id: string;
  invoice_number: string | null;
  invoice_date: string;
  total: number;
  amount_paid: number;
  payment_status: "unpaid" | "partial" | "paid";
  subtotal: number;
  line_discount_total: number;
  invoice_discount: number;
  tier_discount: number;
  cash_discount: number;
  bonus_units: number;
  payment_method: string | null;
  suppliers: { name: string } | null;
  warehouses: { name: string } | null;
  purchase_invoice_items: { quantity: number; bonus_quantity: number; is_bonus: boolean; unit_cost: number; net_total: number; effective_unit_cost: number; line_total: number; products: { name: string } | null }[];
};

export default async function PurchasesPage(
  props: { searchParams: Promise<{ q?: string; from?: string; to?: string; page?: string }> }
) {
  const searchParams = await props.searchParams;
  const supabase = await createClient();
  const page = Math.max(1, Number(searchParams.page) || 1);
  const q = searchParams.q?.trim() ?? "";
  const from = searchParams.from || undefined;
  const to = searchParams.to || undefined;

  let invoicesQuery = supabase
    .from("purchase_invoices")
    .select(
      "id, invoice_number, invoice_date, total, amount_paid, payment_status, subtotal, line_discount_total, invoice_discount, tier_discount, cash_discount, bonus_units, payment_method, suppliers(name), warehouses(name), purchase_invoice_items(quantity, bonus_quantity, is_bonus, unit_cost, net_total, effective_unit_cost, line_total, products(name))",
      { count: "exact" }
    )
    .order("created_at", { ascending: false })
    .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
  if (q) invoicesQuery = invoicesQuery.ilike("invoice_number", `%${q}%`);
  if (from) invoicesQuery = invoicesQuery.gte("invoice_date", from);
  if (to) invoicesQuery = invoicesQuery.lte("invoice_date", to);

  const [{ data: suppliers }, { data: warehouses }, { data: products }, { data: invoices, count }] = await Promise.all([
    supabase.from("suppliers").select("id, name").order("name"),
    supabase.from("warehouses").select("id, name").order("name"),
    supabase.from("products").select("id, name, unit").order("name"),
    invoicesQuery,
  ]);

  // the default unit cost comes from the protected cost table; roles that may not read it simply start from 0
  const membership = await getMembership();
  const viewCost = membership ? await canViewCost(supabase, membership.organization_id) : false;
  const costMap = viewCost ? await getProductCosts(supabase, (products ?? []).map((p) => p.id as string)) : new Map<string, number>();
  const productOptions: ProductOption[] = (products ?? []).map((p) => ({
    id: p.id,
    name: p.name,
    unit: p.unit,
    cost: costMap.get(p.id as string) ?? 0,
  }));

  return (
    <div>
      <PageHeader title="المشتريات" />
      <PurchasesTabs />

      <PurchaseForm suppliers={suppliers ?? []} warehouses={warehouses ?? []} products={productOptions} />

      <div className="mb-4 mt-9 flex flex-wrap items-center justify-between gap-3">
        <span className="text-xs font-medium text-charcoal/40">فواتير الشراء</span>
        <div className="flex flex-wrap items-center gap-2">
          <SearchBox placeholder="بحث برقم الفاتورة..." />
          <DateRangeFilter from={from} to={to} />
        </div>
      </div>
      <PurchasesTable invoices={(invoices as unknown as PurchaseInvoiceRow[]) ?? []} />
      <Pagination page={page} pageSize={PAGE_SIZE} totalCount={count ?? 0} />
    </div>
  );
}
