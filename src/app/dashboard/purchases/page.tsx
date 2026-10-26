import { createClient } from "@/lib/supabase/server";
import { FocusedInvoiceBanner } from "@/components/ui/focused-invoice-banner";
import { containsPattern, invoiceParam } from "@/lib/doc-search";
import { getMembership } from "@/lib/org-context";
import { canViewCost, getProductCosts } from "@/lib/costs";
import { PageHeader } from "@/components/ui/page-header";
import { SearchBox } from "@/components/ui/search-box";
import { DateRangeFilter } from "@/components/ui/date-range-filter";
import { Pagination } from "@/components/ui/pagination";
import { PurchasesTabs } from "@/components/purchases/purchases-tabs";
import { PurchaseForm, type ShortagePrefill } from "./purchase-form";
import { PurchasesTable } from "./purchases-table";
import { ExportButtons } from "@/components/ui/export-buttons";
import { rangeText } from "@/lib/export/model";
import { exportPurchaseInvoiceList } from "../invoice-export-actions";

const PAGE_SIZE = 20;

export type ProductOption = { id: string; name: string; unit: string; cost: number };
export type InvoicePayment = {
  id: string;
  amount: number;
  payment_date: string;
  payment_method: string | null;
  reference: string | null;
  notes: string | null;
};

export type PurchaseInvoiceRow = {
  receipt_status?: string | null;
  received_at?: string | null;
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
  // filled in below from supplier_payments / purchase_returns (same sources the reports use)
  payments: InvoicePayment[];
  returns_total: number;
  cash_refunded: number;
  remaining: number;
  suppliers: { name: string } | null;
  warehouses: { name: string } | null;
  purchase_invoice_items: { quantity: number; bonus_quantity: number; is_bonus: boolean; unit_cost: number; net_total: number; effective_unit_cost: number; line_total: number; products: { name: string } | null }[];
};

export default async function PurchasesPage(
  props: { searchParams: Promise<{ q?: string; inv?: string; from?: string; to?: string; page?: string; shortage?: string; product?: string; warehouse?: string; qty?: string }> }
) {
  const searchParams = await props.searchParams;
  const supabase = await createClient();
  const page = Math.max(1, Number(searchParams.page) || 1);
  const q = searchParams.q?.trim() ?? "";
  const inv = invoiceParam(searchParams.inv);   // opened from a notification / search result: ONE invoice, by id
  const from = searchParams.from || undefined;
  const to = searchParams.to || undefined;

  let invoicesQuery = supabase
    .from("purchase_invoices")
    .select(
      "id, invoice_number, invoice_date, total, amount_paid, payment_status, receipt_status, received_at, subtotal, line_discount_total, invoice_discount, tier_discount, cash_discount, bonus_units, payment_method, suppliers(name), warehouses(name), purchase_invoice_items(quantity, bonus_quantity, is_bonus, unit_cost, net_total, effective_unit_cost, line_total, products(name))",
      { count: "exact" }
    )
    .order("created_at", { ascending: false })
    .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
  if (inv) invoicesQuery = invoicesQuery.eq("id", inv);
  else if (q) invoicesQuery = invoicesQuery.ilike("invoice_number", containsPattern(q));
  if (from) invoicesQuery = invoicesQuery.gte("invoice_date", from);
  if (to) invoicesQuery = invoicesQuery.lte("invoice_date", to);

  const [{ data: suppliers }, { data: warehouses }, { data: products }, { data: invoices, count }] = await Promise.all([
    supabase.from("suppliers").select("id, name, payment_terms_days").order("name"),
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

  // Opened from a stock-shortage report («إنشاء فاتورة مشتريات»): start the form with the missing product already
  // chosen. These are only defaults — the Owner still picks the supplier and enters the real quantity, and the database
  // re-validates the report when the invoice is linked to it.
  const isUuid = (v?: string) => !!v && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
  let prefill: ShortagePrefill | undefined;
  if (isUuid(searchParams.shortage) && isUuid(searchParams.product)) {
    const prod = productOptions.find((p) => p.id === searchParams.product);
    if (prod) {
      const qty = Math.round(Number(searchParams.qty) * 1000) / 1000;
      prefill = {
        reportId: searchParams.shortage as string,
        productId: prod.id,
        productName: prod.name,
        unit: prod.unit,
        warehouseId: (warehouses ?? []).some((w) => w.id === searchParams.warehouse) ? searchParams.warehouse : undefined,
        suggestedQty: Number.isFinite(qty) && qty > 0 ? qty : undefined,
      };
      // What is already on its way for this report (Owner only; the database refuses anyone else). It decides the suggested
      // quantity (only what is STILL missing) and whether a confirmation is needed before a second purchase.
      if (membership?.organization_id) {
        const { data: check } = await supabase.rpc("shortage_purchase_precheck", { org_id: membership.organization_id, p_report_id: searchParams.shortage });
        const c = check as { incoming?: number; remaining?: number; covered?: boolean; pending?: { invoice_number: string | null; open_units: number }[] } | null;
        if (c) {
          prefill.incoming = Number(c.incoming ?? 0);
          prefill.covered = !!c.covered;
          prefill.pending = c.pending ?? [];
          if (Number(c.remaining) > 0) prefill.suggestedQty = Number(c.remaining);
        }
      }
    }
  }

  // Payment history per invoice. Every payment is its own supplier_payments row (created with
  // the invoice or later), so nothing is ever overwritten. Same RLS as everything else.
  // Only members who handle money (treasury.manage) or may view financials get this detail.
  const orgId = membership?.organization_id ?? null;
  const [canPay, canViewFinancial] = orgId
    ? await Promise.all([
        supabase.rpc("has_permission", { target_org: orgId, perm_key: "treasury.manage" }).then((r) => !!r.data),
        supabase.rpc("has_permission", { target_org: orgId, perm_key: "view_financial" }).then((r) => !!r.data),
      ])
    : [false, false];
  const showPayments = canPay || canViewFinancial;
  const canExport = orgId ? !!(await supabase.rpc("has_permission", { target_org: orgId, perm_key: "reports.export" })).data : false;

  const rows = (invoices as unknown as PurchaseInvoiceRow[]) ?? [];
  const ids = rows.map((r) => r.id);
  const [{ data: payRows }, { data: returnRows }] =
    showPayments && ids.length && orgId
      ? await Promise.all([
          supabase
            .from("supplier_payments")
            .select("id, purchase_invoice_id, amount, payment_date, payment_method, reference, notes")
            .eq("organization_id", orgId)
            .in("purchase_invoice_id", ids)
            .order("payment_date", { ascending: true })
            .order("created_at", { ascending: true }),
          supabase.from("purchase_returns").select("purchase_invoice_id, total, cash_refunded").eq("organization_id", orgId).in("purchase_invoice_id", ids),
        ])
      : [{ data: [] }, { data: [] }];
  const payByInvoice = new Map<string, InvoicePayment[]>();
  for (const c of payRows ?? []) {
    const list = payByInvoice.get(c.purchase_invoice_id as string) ?? [];
    list.push({ id: c.id, amount: Number(c.amount), payment_date: c.payment_date, payment_method: c.payment_method, reference: c.reference, notes: c.notes });
    payByInvoice.set(c.purchase_invoice_id as string, list);
  }
  const returnsByInvoice = new Map<string, { total: number; cash: number }>();
  for (const r of returnRows ?? []) {
    const cur = returnsByInvoice.get(r.purchase_invoice_id as string) ?? { total: 0, cash: 0 };
    cur.total += Number(r.total);
    cur.cash += Number(r.cash_refunded);
    returnsByInvoice.set(r.purchase_invoice_id as string, cur);
  }
  for (const r of rows) {
    const ret = returnsByInvoice.get(r.id) ?? { total: 0, cash: 0 };
    r.payments = payByInvoice.get(r.id) ?? [];
    r.returns_total = ret.total;
    r.cash_refunded = ret.cash;
    // identical to purchase_invoice_remaining() in the database: total − paid − credit notes + cash refunds
    r.remaining = Math.max(0, Math.round((Number(r.total) - Number(r.amount_paid) - ret.total + ret.cash) * 100) / 100);
  }

  return (
    <div>
      <PageHeader title="المشتريات" />
      <PurchasesTabs />

      <PurchaseForm key={prefill?.reportId ?? "new"} suppliers={suppliers ?? []} warehouses={warehouses ?? []} products={productOptions} prefill={prefill} />

      <div className="mb-4 mt-9 flex flex-wrap items-center justify-between gap-3">
        <span className="text-xs font-medium text-charcoal/40">فواتير الشراء</span>
        <div className="flex flex-wrap items-center gap-2">
          <SearchBox placeholder="بحث برقم الفاتورة..." />
          <DateRangeFilter from={from} to={to} />
          {canExport && !inv && (
            <ExportButtons
              filename={`فواتير-المشتريات-${from ?? "الكل"}-${to ?? "الآن"}`}
              title="فواتير المشتريات"
              subtitle={`${rangeText(from, to)}${q ? ` — بحث: ${q}` : ""}`}
              headers={["التاريخ", "رقم الفاتورة", "المورد", "المخزن", "الإجمالي", "المدفوع", "المرتجعات", "المتبقي", "الحالة"]}
              kinds={["date", "code", "text", "text", "money:sum", "money:sum", "money:sum", "money:sum", "text"]}
              loadRows={exportPurchaseInvoiceList}
              loadFilters={{ q, from, to }}
            />
          )}
        </div>
      </div>
      {inv && <FocusedInvoiceBanner clearHref="/dashboard/purchases" found={rows.length > 0} />}
      <PurchasesTable invoices={rows} canPay={canPay} showPayments={showPayments} />
      <Pagination page={page} pageSize={PAGE_SIZE} totalCount={count ?? 0} />
    </div>
  );
}
