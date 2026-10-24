import { getSupabase, getMembership, NO_ORG_ID, isRestrictedRep } from "@/lib/org-context";
import { PageHeader } from "@/components/ui/page-header";
import { SearchBox } from "@/components/ui/search-box";
import { DateRangeFilter } from "@/components/ui/date-range-filter";
import { Pagination } from "@/components/ui/pagination";
import { SalesTabs } from "@/components/sales/sales-tabs";
import { FocusedInvoiceBanner } from "@/components/ui/focused-invoice-banner";
import { containsPattern, invoiceParam } from "@/lib/doc-search";
import { SalesForm } from "./sales-form";
import { SalesTable } from "./sales-table";

const PAGE_SIZE = 20;

export type ProductOption = { id: string; name: string; unit: string; selling_price: number; wholesale_price: number | null; distributor_price: number | null };
export type CustomerOption = { id: string; name: string; price_tier: string; sales_rep_id: string | null };
export type InvoicePayment = {
  id: string;
  amount: number;
  collection_date: string;
  payment_method: string | null;
  reference: string | null;
  notes: string | null;
};

export type SalesInvoiceRow = {
  dispatch_status?: string | null;
  dispatched_at?: string | null;
  id: string;
  invoice_number: string | null;
  invoice_date: string;
  total: number;
  amount_paid: number;
  payment_status: "unpaid" | "partial" | "paid";
  subtotal: number;
  discount_total: number;
  line_discount_total: number;
  invoice_discount: number;
  cash_discount: number;
  tier_discount: number;
  bonus_units: number;
  payment_method: string | null;
  tax_total: number;
  cogs_total: number; // filled in only for members with view_financial
  profit_total: number;
  commission_amount: number;
  commission_basis_snapshot: string | null;
  // filled in below from customer_collections / sales_returns (same sources the reports use)
  payments: InvoicePayment[];
  returns_total: number;
  cash_refunded: number;
  remaining: number;
  customers: { name: string } | null;
  warehouses: { name: string } | null;
  sales_representatives: { name: string } | null;
  sales_invoice_items: {
    id: string;
    quantity: number;
    bonus_quantity: number;
    is_bonus: boolean;
    net_total: number;
    effective_unit_price: number;
    unit_price: number;
    line_total: number;
    unit_cost: number;
    cost_total: number;
    profit: number;
    products: { name: string } | null;
  }[];
};

export default async function SalesPage(
  props: { searchParams: Promise<{ q?: string; inv?: string; from?: string; to?: string; page?: string }> }
) {
  const searchParams = await props.searchParams;
  const supabase = (await getSupabase());
  const page = Math.max(1, Number(searchParams.page) || 1);
  const q = searchParams.q?.trim() ?? "";
  const inv = invoiceParam(searchParams.inv);   // opened from a notification / search result: ONE invoice, by id
  const from = searchParams.from || undefined;
  const to = searchParams.to || undefined;

  const membership = await getMembership();
  const orgId = membership?.organization_id ?? NO_ORG_ID;

  let invoicesQuery = supabase
    .from("sales_invoices")
    .select(
      "id, invoice_number, invoice_date, total, amount_paid, payment_status, dispatch_status, dispatched_at, subtotal, discount_total, line_discount_total, invoice_discount, cash_discount, tier_discount, bonus_units, payment_method, tax_total, commission_amount, commission_basis_snapshot, customers(name), warehouses(name), sales_representatives(name), sales_invoice_items(id, quantity, bonus_quantity, is_bonus, net_total, effective_unit_price, unit_price, line_total, products(name))",
      { count: "exact" }
    )
    .eq("organization_id", orgId)
    .order("created_at", { ascending: false })
    .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
  if (inv) invoicesQuery = invoicesQuery.eq("id", inv);
  else if (q) invoicesQuery = invoicesQuery.ilike("invoice_number", containsPattern(q));
  if (from) invoicesQuery = invoicesQuery.gte("invoice_date", from);
  if (to) invoicesQuery = invoicesQuery.lte("invoice_date", to);

  const [{ data: customers }, { data: warehouses }, { data: products }, { data: salePrices }, { data: representatives }, { data: invoices, count }, { data: canViewFinancial }] = await Promise.all([
    supabase.from("customers").select("id, name, price_tier, sales_rep_id").eq("organization_id", orgId).order("name"),
    supabase.from("warehouses").select("id, name").eq("organization_id", orgId).order("name"),
    supabase.from("products").select("id, name, unit").eq("organization_id", orgId).order("name"),
    supabase.from("product_sale_prices").select("product_id, selling_price, wholesale_price, distributor_price").eq("organization_id", orgId),
    supabase.from("sales_representatives").select("id, name").eq("organization_id", orgId).eq("is_active", true).order("name"),
    invoicesQuery,
    membership
      ? supabase.rpc("has_permission", { target_org: membership.organization_id, perm_key: "view_financial" })
      : Promise.resolve({ data: false }),
  ]);

  // may this user assign an invoice to a rep other than themselves? (permission sales.assign_any_rep)
  const canAssignAnyRep = membership
    ? !!(await supabase.rpc("has_permission", { target_org: membership.organization_id, perm_key: "sales.assign_any_rep" })).data
    : false;
  const { data: ownRepData } = membership
    ? await supabase.rpc("own_rep_id", { p_org: membership.organization_id })
    : { data: null };
  const ownRepId = (ownRepData as string | null) ?? null;

  // what this user may do on an invoice (set by Owner/Admin in Settings → حدود الخصم)
  const { data: limitsData } = membership
    ? await supabase.rpc("my_sales_limits", { org_id: membership.organization_id })
    : { data: null };
  const limits = (limitsData ?? null) as { unlimited: boolean; max_discount_pct: number | null; can_give_manual_bonus: boolean } | null;

  const priceByProduct = new Map((salePrices ?? []).map((pr) => [pr.product_id, pr]));
  const productOptions: ProductOption[] = (products ?? []).map((p) => {
    const pr = priceByProduct.get(p.id);
    return {
      id: p.id,
      name: p.name,
      unit: p.unit,
      selling_price: pr?.selling_price ?? 0,
      wholesale_price: pr?.wholesale_price ?? null,
      distributor_price: pr?.distributor_price ?? null,
    };
  });

  const rows = (invoices as unknown as SalesInvoiceRow[]) ?? [];

  // Members without view_financial never get cost/profit rows back; give every row and item a
  // numeric default first so the table can always format them (never `undefined`).
  for (const r of rows) {
    r.cogs_total = 0;
    r.profit_total = 0;
    r.commission_amount = Number(r.commission_amount ?? 0);
    for (const it of r.sales_invoice_items ?? []) {
      it.unit_cost = 0;
      it.cost_total = 0;
      it.profit = 0;
    }
  }

  // Payment history per invoice. Every payment is its own customer_collections row
  // (created with the invoice or later), so nothing is ever overwritten. Same RLS as
  // everything else: a restricted rep only gets rows for their own customers.
  const invoiceIds = rows.map((r) => r.id);
  const [{ data: collections }, { data: returnRows }] = invoiceIds.length
    ? await Promise.all([
        supabase
          .from("customer_collections")
          .select("id, sales_invoice_id, amount, collection_date, payment_method, reference, notes")
          .eq("organization_id", orgId)
          .in("sales_invoice_id", invoiceIds)
          .order("collection_date", { ascending: true })
          .order("created_at", { ascending: true }),
        supabase.from("sales_returns").select("sales_invoice_id, total, cash_refunded").eq("organization_id", orgId).in("sales_invoice_id", invoiceIds),
      ])
    : [{ data: [] }, { data: [] }];
  const paymentsByInvoice = new Map<string, InvoicePayment[]>();
  for (const c of collections ?? []) {
    const list = paymentsByInvoice.get(c.sales_invoice_id as string) ?? [];
    list.push({ id: c.id, amount: Number(c.amount), collection_date: c.collection_date, payment_method: c.payment_method, reference: c.reference, notes: c.notes });
    paymentsByInvoice.set(c.sales_invoice_id as string, list);
  }
  const returnsByInvoice = new Map<string, { total: number; cash: number }>();
  for (const r of returnRows ?? []) {
    const cur = returnsByInvoice.get(r.sales_invoice_id as string) ?? { total: 0, cash: 0 };
    cur.total += Number(r.total);
    cur.cash += Number(r.cash_refunded);
    returnsByInvoice.set(r.sales_invoice_id as string, cur);
  }
  for (const r of rows) {
    const ret = returnsByInvoice.get(r.id) ?? { total: 0, cash: 0 };
    r.payments = paymentsByInvoice.get(r.id) ?? [];
    r.returns_total = ret.total;
    r.cash_refunded = ret.cash;
    // identical to sales_invoice_remaining() in the database: total − paid − credit notes + cash refunds
    r.remaining = Math.max(0, Math.round((Number(r.total) - Number(r.amount_paid) - ret.total + ret.cash) * 100) / 100);
  }

  // the owner collects through treasury.manage; a sales rep through collections.record (his own customers only —
  // the database enforces that, a rep only receives his own customers' invoices here anyway)
  const canCollect = membership
    ? (await Promise.all(
        ["treasury.manage", "collections.record"].map((perm_key) => supabase.rpc("has_permission", { target_org: membership.organization_id, perm_key }))
      )).some((r) => !!r.data)
    : false;

  // Cost & profit live in tables only members with view_financial can read
  // (reps and other members get nothing back), so they are fetched separately.
  if (canViewFinancial && rows.length > 0) {
    const itemIds = rows.flatMap((r) => r.sales_invoice_items.map((it) => it.id));
    const [{ data: invFin }, { data: itemFin }] = await Promise.all([
      supabase.from("sales_invoice_financials").select("sales_invoice_id, cogs_total, profit_total").in("sales_invoice_id", rows.map((r) => r.id)),
      supabase.from("sales_item_financials").select("sales_invoice_item_id, unit_cost, cost_total, profit").in("sales_invoice_item_id", itemIds),
    ]);
    const invMap = new Map((invFin ?? []).map((f) => [f.sales_invoice_id, f]));
    const itemMap = new Map((itemFin ?? []).map((f) => [f.sales_invoice_item_id, f]));
    for (const r of rows) {
      r.cogs_total = Number(invMap.get(r.id)?.cogs_total ?? 0);
      r.profit_total = Number(invMap.get(r.id)?.profit_total ?? 0);
      for (const it of r.sales_invoice_items) {
        const f = itemMap.get(it.id);
        it.unit_cost = Number(f?.unit_cost ?? 0);
        it.cost_total = Number(f?.cost_total ?? 0);
        it.profit = Number(f?.profit ?? 0);
      }
    }
  }

  return (
    <div>
      <PageHeader title="المبيعات" />
      <SalesTabs />

      <SalesForm canAssignAnyRep={canAssignAnyRep} ownRepId={ownRepId} limits={limits} customers={customers ?? []} warehouses={warehouses ?? []} products={productOptions} representatives={representatives ?? []} restrictedRep={await isRestrictedRep()} />

      <div className="mb-4 mt-9 flex flex-wrap items-center justify-between gap-3">
        <span className="text-xs font-medium text-charcoal/40">فواتير البيع</span>
        <div className="flex flex-wrap items-center gap-2">
          <SearchBox placeholder="بحث برقم الفاتورة..." />
          <DateRangeFilter from={from} to={to} />
        </div>
      </div>
      {inv && <FocusedInvoiceBanner clearHref="/dashboard/sales" found={rows.length > 0} />}
      <SalesTable invoices={rows} canViewFinancial={!!canViewFinancial} canCollect={canCollect} />
      <Pagination page={page} pageSize={PAGE_SIZE} totalCount={count ?? 0} />
    </div>
  );
}
