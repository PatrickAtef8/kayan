import Link from "next/link";
import { getSupabase, getMembership, NO_ORG_ID } from "@/lib/org-context";
import { PageHeader } from "@/components/ui/page-header";
import { SearchBox } from "@/components/ui/search-box";
import { Pagination } from "@/components/ui/pagination";
import { FocusedInvoiceBanner } from "@/components/ui/focused-invoice-banner";
import { invoiceParam } from "@/lib/doc-search";
import { OrderCard, type Order, type OrderEvent, type OrderLine } from "./order-card";

const PAGE_SIZE = 20;
const STATUSES = [
  { key: "open", label: "بانتظار التنفيذ" },
  { key: "done", label: "تم" },
  { key: "cancelled", label: "ملغاة" },
  { key: "all", label: "الكل" },
];

type Row = {
  id: string; invoice_number: string | null; invoice_date: string; customer_name?: string | null; supplier_name?: string | null;
  warehouse_name: string | null; status: string; completed_at: string | null; completed_by: string | null;
  lines: OrderLine[]; history: OrderEvent[]; total_count: number;
};

// Orders for the storekeeper: sales to dispatch and purchases to receive. Items and quantities only —
// the database function behind this page never returns a price, a total or any other financial field.
export default async function WarehouseOrdersPage(props: { searchParams: Promise<{ tab?: string; status?: string; q?: string; inv?: string; page?: string }> }) {
  const sp = await props.searchParams;
  const tab: "sales" | "purchase" = sp.tab === "purchase" ? "purchase" : "sales";
  const inv = invoiceParam(sp.inv);   // from a notification: this exact order, whatever its state now
  const status = STATUSES.some((s) => s.key === sp.status) ? (sp.status as string) : inv ? "all" : "open";
  const q = sp.q?.trim() ?? "";
  const page = Math.max(1, Number(sp.page) || 1);

  const supabase = await getSupabase();
  const membership = await getMembership();
  const orgId = membership?.organization_id ?? NO_ORG_ID;

  const [counts, list] = await Promise.all([
    supabase.rpc("warehouse_pending_counts", { org_id: orgId }),
    supabase.rpc(tab === "sales" ? "warehouse_sales_orders" : "warehouse_purchase_orders", {
      org_id: orgId, p_status: status, p_search: q ? q.replace(/[\\%_]/g, "") : null, p_invoice: inv, p_limit: PAGE_SIZE, p_offset: (page - 1) * PAGE_SIZE,
    }),
  ]);
  const pendingCounts = (counts.data as { sales: number; purchases: number } | null) ?? { sales: 0, purchases: 0 };
  const rows = ((list.data as Row[] | null) ?? []);
  const total = rows[0]?.total_count ?? 0;

  const orders: Order[] = rows.map((r) => ({
    id: r.id, invoice_number: r.invoice_number, invoice_date: r.invoice_date,
    party_name: tab === "sales" ? r.customer_name ?? null : r.supplier_name ?? null,
    warehouse_name: r.warehouse_name, status: r.status, completed_at: r.completed_at, completed_by: r.completed_by,
    lines: r.lines, history: r.history,
  }));

  const href = (over: Record<string, string>) => {
    const p = new URLSearchParams({ tab, status, ...(q ? { q } : {}), ...(inv ? { inv } : {}), ...over });
    return `/dashboard/warehouse-orders?${p.toString()}`;
  };

  return (
    <div>
      <PageHeader title="أوامر المخزن" />
      <div className="mb-5 flex flex-wrap gap-2">
        <Link href={href({ tab: "sales", page: "1" })} className={`rounded-lg px-3.5 py-2 text-sm font-medium ${tab === "sales" ? "bg-charcoal text-ivory" : "bg-paper text-charcoal/55 hover:text-charcoal"}`}>
          أوامر الصرف (المبيعات){pendingCounts.sales > 0 && <span className="mr-2 rounded-full bg-brass px-1.5 text-[0.6875rem] text-white">{pendingCounts.sales}</span>}
        </Link>
        <Link href={href({ tab: "purchase", page: "1" })} className={`rounded-lg px-3.5 py-2 text-sm font-medium ${tab === "purchase" ? "bg-charcoal text-ivory" : "bg-paper text-charcoal/55 hover:text-charcoal"}`}>
          أوامر الاستلام (المشتريات){pendingCounts.purchases > 0 && <span className="mr-2 rounded-full bg-brass px-1.5 text-[0.6875rem] text-white">{pendingCounts.purchases}</span>}
        </Link>
      </div>
      <div className="mb-4 flex flex-wrap items-center gap-2">
        {STATUSES.map((s) => (
          <Link key={s.key} href={href({ status: s.key, page: "1" })} className={`rounded-lg px-2.5 py-1.5 text-xs font-medium ${status === s.key ? "bg-sageSoft text-sage" : "text-charcoal/45 hover:bg-paper"}`}>{s.label}</Link>
        ))}
      </div>
      {inv && <FocusedInvoiceBanner clearHref={`/dashboard/warehouse-orders?tab=${tab}`} found={orders.length > 0} />}
      <div className="mb-5"><SearchBox placeholder="بحث برقم الفاتورة..." /></div>

      {list.error && <p className="mb-4 text-sm text-rose">{list.error.message}</p>}
      {orders.length === 0 && !list.error && (
        <p className="rounded-xl border border-borderSoft bg-white p-8 text-center text-sm text-charcoal/45">
          {status === "open" ? (tab === "sales" ? "لا توجد أوامر صرف في الانتظار" : "لا توجد أوامر استلام في الانتظار") : "لا توجد نتائج"}
        </p>
      )}
      {orders.map((o) => <OrderCard key={o.id} order={o} kind={tab} canConfirm />)}
      <Pagination page={page} pageSize={PAGE_SIZE} totalCount={total} />
    </div>
  );
}
