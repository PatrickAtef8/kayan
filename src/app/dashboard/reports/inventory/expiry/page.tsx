import Link from "next/link";
import { getReportContext } from "@/lib/report-context";
import { Card } from "@/components/ui/card";
import { DataTable } from "@/components/ui/data-table";
import { ExportButtons } from "@/components/ui/export-buttons";
import { Pagination } from "@/components/ui/pagination";
import { ParamSelect } from "@/components/reports/param-select";
import { DisposeBatchButton } from "./dispose-batch-button";

type ExpiryRow = {
  batch_id: string;
  product_id: string;
  product_name: string;
  sku: string | null;
  barcode: string | null;
  unit: string;
  warehouse_name: string;
  expiry_date: string | null;
  quantity: number;
  days_to_expiry: number | null;
  status: "expired" | "expiring" | "ok" | "no_expiry";
  total_count: number;
};

type Summary = Record<"expired" | "expiring" | "ok" | "no_expiry", { batches: number; quantity: number }>;

const PAGE_SIZE = 100;
const NO_EXPIRY_LABEL = "لا يوجد تاريخ صلاحية مسجل";
const DAY_OPTIONS = [30, 60, 90, 180];
const STATUS_LABEL: Record<string, string> = { expired: "منتهي", expiring: "قريب الانتهاء", ok: "سليم", no_expiry: NO_EXPIRY_LABEL };
const STATUS_STYLE: Record<string, string> = {
  expired: "bg-rose/10 text-rose",
  expiring: "bg-amber-100 text-amber-700",
  ok: "bg-sageSoft text-sage",
  no_expiry: "bg-paper text-charcoal/55",
};

const num = (n: number) => Number(n).toLocaleString("ar-EG", { maximumFractionDigits: 3 });
const dateText = (d: string | null) => (d ? new Date(d + "T00:00:00").toLocaleDateString("ar-EG", { year: "numeric", month: "short", day: "numeric" }) : NO_EXPIRY_LABEL);

export default async function ExpiryReportPage(props: { searchParams: Promise<{ status?: string; days?: string; warehouse?: string; page?: string }> }) {
  const sp = await props.searchParams;
  const status = ["expired", "expiring", "ok", "no_expiry"].includes(sp.status ?? "") ? (sp.status as string) : "";
  const days = DAY_OPTIONS.includes(Number(sp.days)) ? Number(sp.days) : 90;
  const warehouse = sp.warehouse || null;
  const page = Math.max(1, Number(sp.page) || 1);

  const { supabase, orgId, canExport } = await getReportContext();
  if (!orgId) return null;

  const { data: canAdjust } = await supabase.rpc("has_permission", { target_org: orgId, perm_key: "inventory.adjust" });

  const [{ data }, { data: summaryData }, { data: warehouses }] = await Promise.all([
    supabase.rpc("report_expiry", { org_id: orgId, p_warehouse: warehouse, p_status: status || null, p_days: days, p_limit: PAGE_SIZE, p_offset: (page - 1) * PAGE_SIZE }),
    supabase.rpc("report_expiry_summary", { org_id: orgId, p_warehouse: warehouse, p_days: days }),
    supabase.from("warehouses").select("id, name").eq("organization_id", orgId).eq("is_active", true).order("name"),
  ]);
  const rows = (data as ExpiryRow[]) ?? [];
  const total = rows[0]?.total_count ?? 0;
  const summary = summaryData as Summary | null;

  // the export always contains the full filtered result, not just this page
  let exportRows = rows;
  if (canExport && total > rows.length) {
    const { data: all } = await supabase.rpc("report_expiry", { org_id: orgId, p_warehouse: warehouse, p_status: status || null, p_days: days, p_limit: 2000, p_offset: 0 });
    exportRows = (all as ExpiryRow[]) ?? rows;
  }

  const qs = (patch: Record<string, string>) => {
    const p = new URLSearchParams();
    const merged: Record<string, string> = { status, days: String(days), warehouse: warehouse ?? "", ...patch };
    for (const [k, v] of Object.entries(merged)) if (v) p.set(k, v);
    return `?${p.toString()}`;
  };

  const cards: { key: keyof Summary; label: string; tone: string }[] = [
    { key: "expired", label: "منتهية الصلاحية", tone: "text-rose" },
    { key: "expiring", label: `تنتهي خلال ${days} يومًا`, tone: "text-amber-700" },
    { key: "ok", label: "سليمة", tone: "text-sage" },
    { key: "no_expiry", label: NO_EXPIRY_LABEL, tone: "text-charcoal/60" },
  ];

  return (
    <div>
      <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
        {canExport ? (
          <ExportButtons
            filename={`صلاحية-المنتجات-${new Date().toISOString().slice(0, 10)}`}
            headers={["المنتج", "الكود", "الباركود", "المخزن", "تاريخ الصلاحية", "الكمية", "الأيام المتبقية", "الحالة"]}
            rows={exportRows.map((r) => [r.product_name, r.sku ?? "", r.barcode ?? "", r.warehouse_name, r.expiry_date ?? NO_EXPIRY_LABEL, r.quantity, r.days_to_expiry ?? "", STATUS_LABEL[r.status]])}
          />
        ) : (
          <span />
        )}
        <ParamSelect param="warehouse" value={warehouse ?? ""} placeholder="كل المخازن" clearLabel="كل المخازن" options={(warehouses ?? []).map((w) => ({ value: w.id, label: w.name }))} />
      </div>

      <div className="mb-6 grid grid-cols-2 gap-3 lg:grid-cols-4">
        {cards.map((c) => (
          <Link key={c.key} href={qs({ status: status === c.key ? "" : c.key, page: "" })} scroll={false}>
            <Card className={`p-4 transition-colors hover:border-sage ${status === c.key ? "border-sage" : ""}`}>
              <p className="text-[0.6875rem] text-charcoal/45">{c.label}</p>
              <p className={`mt-1.5 text-xl font-semibold ${c.tone}`} dir="ltr">{num(summary?.[c.key]?.quantity ?? 0)}</p>
              <p className="mt-1 text-[0.6875rem] text-charcoal/40">{summary?.[c.key]?.batches ?? 0} دفعة</p>
            </Card>
          </Link>
        ))}
      </div>

      <div className="no-print mb-3 flex flex-wrap items-center gap-1.5">
        <span className="text-xs text-charcoal/40">قريب الانتهاء = خلال</span>
        {DAY_OPTIONS.map((d) => (
          <Link key={d} href={qs({ days: String(d), page: "" })} scroll={false} className={`rounded-lg px-2.5 py-1.5 text-xs font-medium ${d === days ? "bg-charcoal text-ivory" : "bg-paper text-charcoal/50 hover:text-charcoal"}`}>
            {d} يومًا
          </Link>
        ))}
        {status && (
          <Link href={qs({ status: "", page: "" })} scroll={false} className="rounded-lg px-2.5 py-1.5 text-xs text-sage hover:bg-sageSoft/30">
            إلغاء فلتر الحالة ({STATUS_LABEL[status]})
          </Link>
        )}
      </div>

      <DataTable<ExpiryRow>
        rows={rows}
        getRowKey={(r) => r.batch_id}
        emptyLabel="لا توجد دفعات مطابقة"
        columns={[
          { header: "المنتج", render: (r) => r.product_name },
          { header: "الباركود", render: (r) => <span dir="ltr">{r.barcode ?? "—"}</span> },
          { header: "المخزن", render: (r) => r.warehouse_name },
          { header: "تاريخ الصلاحية", render: (r) => <span className={r.expiry_date ? "" : "text-charcoal/45"}>{dateText(r.expiry_date)}</span> },
          { header: "الأيام المتبقية", render: (r) => (r.days_to_expiry === null ? "—" : <span dir="ltr" className={r.days_to_expiry < 0 ? "text-rose" : ""}>{r.days_to_expiry}</span>) },
          { header: "الكمية", render: (r) => <span dir="ltr">{num(r.quantity)} {r.unit}</span> },
          { header: "الحالة", render: (r) => <span className={`rounded-md px-2 py-0.5 text-xs font-medium ${STATUS_STYLE[r.status]}`}>{STATUS_LABEL[r.status]}</span> },
          ...(canAdjust
            ? [
                {
                  header: "إجراء",
                  render: (r: ExpiryRow) => (
                    <DisposeBatchButton
                      batchId={r.batch_id}
                      productName={r.product_name}
                      quantity={Number(r.quantity)}
                      unit={r.unit}
                      expiryLabel={dateText(r.expiry_date)}
                      defaultReason={r.status === "expired" ? "إعدام منتهي الصلاحية" : ""}
                    />
                  ),
                },
              ]
            : []),
        ]}
      />
      <Pagination page={page} pageSize={PAGE_SIZE} totalCount={Number(total)} />

      <p className="mt-4 text-xs text-charcoal/40">
        كل صف = دفعة واحدة. الصنف الواحد قد يظهر أكثر من مرة بتواريخ مختلفة. البيع يخصم الأقرب انتهاءً أولًا (FEFO) ولا يبيع المنتهي أبدًا؛ لإعدام كمية من دفعة معيّنة استخدم زر «إعدام» في صفها؛ فهو يخصم من هذه الدفعة فقط ولا يمس غيرها.
        الكمية بدون تاريخ تُخصم بعد الكميات ذات التواريخ.
      </p>
    </div>
  );
}
