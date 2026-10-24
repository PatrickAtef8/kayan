import Link from "next/link";
import { getSupabase, getMembership, getRoleKey, NO_ORG_ID } from "@/lib/org-context";
import { PageHeader } from "@/components/ui/page-header";
import { Pagination } from "@/components/ui/pagination";
import { ReportRow, type ShortageReport, type LinkedInvoice } from "./report-row";

const PAGE_SIZE = 30;
const FILTERS = [
  { key: "open", label: "المفتوحة" },
  { key: "new", label: "جديد" },
  { key: "in_progress", label: "جاري التجهيز" },
  { key: "resolved", label: "تم توفير الصنف" },
  { key: "all", label: "كل السجل" },
];

// Owner: every shortage report, with the controls to move its status.  Rep: only his own reports and their status.
// Who sees what is decided inside the database function, not here.
export default async function ShortagesPage(props: { searchParams: Promise<{ status?: string; page?: string }> }) {
  const sp = await props.searchParams;
  const status = FILTERS.some((f) => f.key === sp.status) ? (sp.status as string) : "open";
  const page = Math.max(1, Number(sp.page) || 1);
  const supabase = await getSupabase();
  const membership = await getMembership();
  const orgId = membership?.organization_id ?? NO_ORG_ID;
  const role = await getRoleKey();

  const { data, error } = await supabase.rpc("list_stock_shortage_reports", {
    org_id: orgId,
    p_status: status === "all" ? null : status,
    p_limit: PAGE_SIZE + 1,
    p_offset: (page - 1) * PAGE_SIZE,
  });
  const all = (data as ShortageReport[] | null) ?? [];
  const rows = all.slice(0, PAGE_SIZE);
  const hasMore = all.length > PAGE_SIZE;
  const isOwner = role === "owner";

  // purchase invoices already created for these reports (Owner only) — shown under each report
  const linksByReport = new Map<string, LinkedInvoice[]>();
  if (isOwner && rows.length > 0) {
    const { data: links } = await supabase.rpc("list_shortage_report_links", { org_id: orgId, p_report_ids: rows.map((r) => r.id) });
    for (const l of (links as (LinkedInvoice & { report_id: string })[] | null) ?? []) {
      const list = linksByReport.get(l.report_id) ?? [];
      list.push(l);
      linksByReport.set(l.report_id, list);
    }
  }

  return (
    <div>
      <PageHeader title={isOwner ? "بلاغات نقص المخزون" : "بلاغاتي عن نقص المخزون"} />
      <div className="mb-5 flex flex-wrap items-center gap-2">
        {FILTERS.map((f) => (
          <Link key={f.key} href={`/dashboard/shortages?status=${f.key}`} className={`rounded-lg px-2.5 py-1.5 text-xs font-medium ${status === f.key ? "bg-sageSoft text-sage" : "text-charcoal/45 hover:bg-paper"}`}>{f.label}</Link>
        ))}
      </div>
      {error && <p className="mb-4 text-sm text-rose">{error.message}</p>}
      {rows.length === 0 && !error && (
        <p className="rounded-xl border border-borderSoft bg-white p-8 text-center text-sm text-charcoal/45">{status === "open" ? "لا توجد بلاغات مفتوحة" : "لا توجد بلاغات"}</p>
      )}
      <div className="space-y-3">{rows.map((r) => <ReportRow key={r.id} report={r} canManage={isOwner} links={linksByReport.get(r.id) ?? []} />)}</div>
      <Pagination page={page} pageSize={PAGE_SIZE} totalCount={hasMore ? page * PAGE_SIZE + 1 : (page - 1) * PAGE_SIZE + rows.length} />
    </div>
  );
}
