import { Money } from "@/components/ui/money";
import Link from "next/link";
import { getReportContext } from "@/lib/report-context";
import { DataTable } from "@/components/ui/data-table";
import { ExportButtons } from "@/components/ui/export-buttons";
import { Pagination } from "@/components/ui/pagination";
import { DateRangeFilter } from "@/components/ui/date-range-filter";
import { ParamSelect } from "@/components/reports/param-select";
import { Stat } from "../../party-analysis";
import { dateText, isoOrNull, money } from "@/lib/party-reports";

type Row = {
  payment_id: string; payment_date: string; party_id: string; party_name: string; rep_name: string | null;
  amount: number; payment_method: string | null; reference: string | null; doc_number: string | null; notes: string | null;
  total_count: number; total_amount: number;
};

const PAGE = 100;

export default async function PaymentsRegisterPage(props: { searchParams: Promise<{ type?: string; from?: string; to?: string; party?: string; rep?: string; page?: string }> }) {
  const sp = await props.searchParams;
  const type = sp.type === "customer" ? "customer" : "supplier";
  const from = isoOrNull(sp.from);
  const to = isoOrNull(sp.to);
  const party = sp.party || null;
  const rep = type === "customer" ? sp.rep || null : null;
  const page = Math.max(1, Number(sp.page) || 1);

  const { supabase, orgId, canExport } = await getReportContext();
  if (!orgId) return null;

  const args = { org_id: orgId, p_type: type, p_from: from, p_to: to, p_party: party, p_rep: rep };
  const [{ data, error }, { data: suppliers }, { data: reps }] = await Promise.all([
    supabase.rpc("report_party_payments", { ...args, p_limit: PAGE, p_offset: (page - 1) * PAGE }),
    type === "supplier" ? supabase.from("suppliers").select("id, name").eq("organization_id", orgId).order("name") : Promise.resolve({ data: [] }),
    type === "customer" ? supabase.from("sales_representatives").select("id, name").eq("organization_id", orgId).order("name") : Promise.resolve({ data: [] }),
  ]);
  if (error) return <p className="text-sm text-rose">{error.message}</p>;
  const rows = ((data as Row[]) ?? []).map((r) => ({ ...r, amount: Number(r.amount) }));
  const total = Number(rows[0]?.total_count ?? 0);
  const totalAmount = Number(rows[0]?.total_amount ?? 0);

  // the export always holds the whole filtered result, not just this page
  let exportRows = rows;
  if (canExport && total > rows.length) {
    const { data: all } = await supabase.rpc("report_party_payments", { ...args, p_limit: 1000, p_offset: 0 });
    exportRows = ((all as Row[]) ?? []).map((r) => ({ ...r, amount: Number(r.amount) }));
  }

  const toggle = (t: string) => `/dashboard/reports/debts/payments?type=${t}`;
  return (
    <div>
      <div className="mb-5 flex gap-2">
        {(["supplier", "customer"] as const).map((t) => (
          <Link key={t} href={toggle(t)} className={`rounded-lg px-3 py-2 text-sm font-medium ${type === t ? "bg-sageSoft text-sage" : "text-charcoal/50 hover:bg-paper"}`}>
            {t === "supplier" ? "مدفوعات الموردين" : "تحصيلات العملاء"}
          </Link>
        ))}
      </div>

      <div className="no-print mb-5 flex flex-wrap items-center gap-2">
        <DateRangeFilter from={from ?? undefined} to={to ?? undefined} />
        {type === "supplier" ? (
          <ParamSelect param="party" value={party ?? ""} placeholder="كل الموردين" clearLabel="كل الموردين" options={(suppliers ?? []).map((s) => ({ value: s.id, label: s.name }))} />
        ) : (
          <ParamSelect param="rep" value={rep ?? ""} placeholder="كل المناديب" clearLabel="كل المناديب" options={(reps ?? []).map((r) => ({ value: r.id, label: r.name }))} />
        )}
      </div>

      <div className="mb-4 flex items-center justify-between">
        {canExport ? (
          <ExportButtons
            filename={type === "supplier" ? "مدفوعات-الموردين" : "تحصيلات-العملاء"}
            headers={["التاريخ", type === "supplier" ? "المورد" : "العميل", ...(type === "customer" ? ["المندوب"] : []), "المبلغ", "طريقة الدفع", "المرجع", "الفاتورة", "ملاحظات"]}
            rows={exportRows.map((r) => [r.payment_date, r.party_name, ...(type === "customer" ? [r.rep_name ?? ""] : []), r.amount, r.payment_method ?? "", r.reference ?? "", r.doc_number ?? "على الحساب", r.notes ?? ""])}
          />
        ) : (
          <span />
        )}
      </div>

      <div className="mb-5 grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Stat label={type === "supplier" ? "إجمالي المدفوع للموردين" : "إجمالي المحصّل من العملاء"} value={<Money value={totalAmount} />} tone={type === "supplier" ? undefined : "sage"} />
        <Stat label="عدد الدفعات" value={total} />
      </div>

      <DataTable<Row>
        rows={rows}
        getRowKey={(r) => r.payment_id}
        emptyLabel="لا توجد دفعات مطابقة"
        columns={[
          { header: "التاريخ", render: (r) => dateText(r.payment_date) },
          { header: type === "supplier" ? "المورد" : "العميل", render: (r) => <Link href={`/dashboard/reports/debts/statement/${type}/${r.party_id}`} className="text-sage hover:underline">{r.party_name}</Link> },
          ...(type === "customer" ? [{ header: "المندوب", render: (r: Row) => r.rep_name ?? "—" }] : []),
          { header: "المبلغ", render: (r) => <span dir="ltr" className="font-medium"><Money value={r.amount} /></span> },
          { header: "طريقة الدفع", render: (r) => r.payment_method ?? "—" },
          { header: "المرجع", render: (r) => <span dir="ltr">{r.reference ?? "—"}</span> },
          { header: "سُدِّد به", render: (r) => (r.doc_number ? <span dir="ltr">فاتورة {r.doc_number}</span> : <span className="text-charcoal/50">على الحساب</span>) },
          { header: "ملاحظات", render: (r) => r.notes ?? "—" },
        ]}
      />
      <Pagination page={page} pageSize={PAGE} totalCount={total} />
      <p className="mt-4 text-xs text-charcoal/45">يشمل ما دُفع/حُصِّل وقت الفاتورة. «على الحساب» دفعة غير مربوطة بفاتورة، وتُسدِّد الأقدم أولًا في كشف الحساب.</p>
    </div>
  );
}
