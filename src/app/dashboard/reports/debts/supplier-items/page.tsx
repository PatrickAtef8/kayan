import Link from "next/link";
import { getReportContext } from "@/lib/report-context";
import { DataTable } from "@/components/ui/data-table";
import { ExportButtons } from "@/components/ui/export-buttons";
import { DateRangeFilter } from "@/components/ui/date-range-filter";
import { ParamSelect } from "@/components/reports/param-select";
import { Stat } from "../../party-analysis";
import { dateText, isoOrNull, money, qty } from "@/lib/party-reports";

type Row = {
  supplier_id: string; supplier_name: string; product_id: string; product_name: string; unit: string;
  invoices: number; purchased_qty: number; free_qty: number; returned_qty: number; received_qty: number;
  purchased_value: number; returned_value: number; net_value: number; last_purchase_date: string | null; total_count: number;
};

export default async function SupplierItemsPage(props: { searchParams: Promise<{ from?: string; to?: string; supplier?: string }> }) {
  const sp = await props.searchParams;
  const from = isoOrNull(sp.from);
  const to = isoOrNull(sp.to);
  const supplier = sp.supplier || null;

  const { supabase, orgId, canExport } = await getReportContext();
  if (!orgId) return null;

  const [{ data, error }, { data: suppliers }] = await Promise.all([
    supabase.rpc("report_supplier_items", { org_id: orgId, p_from: from, p_to: to, p_supplier: supplier, p_limit: 2000, p_offset: 0 }),
    supabase.from("suppliers").select("id, name").eq("organization_id", orgId).order("name"),
  ]);
  if (error) return <p className="text-sm text-rose">{error.message}</p>;
  const rows = ((data as Row[]) ?? []).map((r) => ({
    ...r, invoices: Number(r.invoices), purchased_qty: Number(r.purchased_qty), free_qty: Number(r.free_qty), returned_qty: Number(r.returned_qty),
    received_qty: Number(r.received_qty), purchased_value: Number(r.purchased_value), returned_value: Number(r.returned_value), net_value: Number(r.net_value),
  }));
  const t = rows.reduce((a, r) => ({ received: a.received + r.received_qty, value: a.value + r.net_value }), { received: 0, value: 0 });
  const truncated = Number(rows[0]?.total_count ?? 0) > rows.length;

  return (
    <div>
      <div className="no-print mb-5 flex flex-wrap items-center gap-2">
        <DateRangeFilter from={from ?? undefined} to={to ?? undefined} />
        <ParamSelect param="supplier" value={supplier ?? ""} placeholder="كل الموردين" clearLabel="كل الموردين" options={(suppliers ?? []).map((s) => ({ value: s.id, label: s.name }))} />
      </div>

      <div className="mb-4">
        {canExport && (
          <ExportButtons
            filename="أصناف-الموردين"
            headers={["المورد", "الصنف", "عدد الفواتير", "المشتريات", "بونص (مجاني)", "المرتجع", "صافي المستلم", "قيمة المشتريات", "قيمة المرتجع", "الصافي", "آخر شراء"]}
            rows={rows.map((r) => [r.supplier_name, r.product_name, r.invoices, r.purchased_qty, r.free_qty, r.returned_qty, r.received_qty, r.purchased_value, r.returned_value, r.net_value, r.last_purchase_date ?? ""])}
          />
        )}
      </div>

      <div className="mb-5 grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Stat label="صافي الكمية المستلمة" value={qty(t.received)} />
        <Stat label="صافي قيمة المشتريات" value={`${money(t.value)} ج.م`} />
      </div>

      <DataTable<Row>
        rows={rows}
        getRowKey={(r) => `${r.supplier_id}-${r.product_id}`}
        emptyLabel="لا توجد مشتريات في هذه الفترة"
        columns={[
          { header: "المورد", render: (r) => <Link href={`/dashboard/reports/debts/statement/supplier/${r.supplier_id}`} className="text-sage hover:underline">{r.supplier_name}</Link> },
          { header: "الصنف", render: (r) => r.product_name },
          { header: "الفواتير", render: (r) => <span dir="ltr">{r.invoices}</span> },
          { header: "المشتريات", render: (r) => <span dir="ltr">{qty(r.purchased_qty)} {r.unit}</span> },
          { header: "بونص", render: (r) => <span dir="ltr">{r.free_qty > 0 ? qty(r.free_qty) : "—"}</span> },
          { header: "المرتجع", render: (r) => <span dir="ltr" className={r.returned_qty > 0 ? "text-rose" : ""}>{r.returned_qty > 0 ? qty(r.returned_qty) : "—"}</span> },
          { header: "صافي المستلم", render: (r) => <span dir="ltr" className="font-medium">{qty(r.received_qty)}</span> },
          { header: "صافي القيمة", render: (r) => <span dir="ltr">{money(r.net_value)} ج.م</span> },
          { header: "آخر شراء", render: (r) => dateText(r.last_purchase_date) },
        ]}
      />
      {truncated && <p className="mt-3 text-xs text-amber-700">يعرض أول {rows.length} سطرًا فقط — ضيّق الفترة أو اختر موردًا.</p>}
      <p className="mt-4 text-xs text-charcoal/45">
        المشتريات تُستلم في المخزن لحظة حفظ الفاتورة (لا توجد خطوة استلام منفصلة)، فصافي المستلم = المشتريات + البونص المجاني − المرتجع. الفترة بتاريخ الفاتورة، والمرتجع يُخصم من فاتورته الأصلية. القيمة بعد خصومات الأصناف والفاتورة.
      </p>
    </div>
  );
}
