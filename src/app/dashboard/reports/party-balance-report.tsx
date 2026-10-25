import { Money } from "@/components/ui/money";
import { formatMoney } from "@/lib/money";
import { getReportContext } from "@/lib/report-context";
import { Card } from "@/components/ui/card";
import { DataTable } from "@/components/ui/data-table";
import { NoFinancialAccess } from "@/components/reports/no-financial-access";
import { ExportButtons } from "@/components/ui/export-buttons";
import { SearchBox } from "@/components/ui/search-box";

function money(n: number) {
  return formatMoney(n);
}

type BalanceRow = { party_id: string; name: string; phone: string | null; total: number; settled: number; balance: number };
type LedgerRow = { entry_date: string; entry_type: string; reference: string; description: string | null; increase: number; decrease: number; balance: number };

const ENTRY_LABEL: Record<string, string> = {
  opening: "رصيد افتتاحي",
  sale: "فاتورة بيع",
  collection: "تحصيل",
  purchase: "فاتورة شراء",
  payment: "دفعة",
  return: "مرتجع",
};

export async function PartyBalanceReport({
  type,
  basePath,
  searchParams,
}: {
  type: "customer" | "supplier";
  basePath: string;
  searchParams: { party?: string; q?: string };
}) {
  const { supabase, orgId, canViewFinancial, canExport } = await getReportContext();
  if (!orgId) return null;
  if (!canViewFinancial) {
    // Not locked: a person without financial permission (a sales rep) still sees their customers — names and contact
    // details only, never a balance, a total or any amount. Suppliers stay financial-only.
    if (type === "customer") return <CustomersWithoutMoney supabase={supabase} q={searchParams.q?.trim() ?? ""} />;
    return <NoFinancialAccess />;
  }

  const { data: balances } = await supabase.rpc("report_party_balances", { org_id: orgId, p_type: type });
  const rows = (balances as BalanceRow[]) ?? [];

  const selectedId = searchParams.party;
  const selected = rows.find((r) => r.party_id === selectedId);

  let ledger: LedgerRow[] = [];
  if (selected) {
    const { data } = await supabase.rpc("report_party_ledger", { org_id: orgId, p_type: type, p_party: selected.party_id });
    ledger = (data as LedgerRow[]) ?? [];
  }

  const totalLabel = type === "customer" ? "إجمالي المبيعات" : "إجمالي المشتريات";
  const settledLabel = type === "customer" ? "المحصّل" : "المدفوع";

  if (selected) {
    return (
      <div>
        <a href={basePath} className="mb-5 inline-block text-xs text-sage hover:underline">
          ← الرجوع للقائمة
        </a>
        <a href={`${basePath}/${selected.party_id}`} className="mb-5 mr-4 inline-block text-xs text-sage hover:underline">
          التحليل التفصيلي (فواتير، خصومات، Bonus، مدفوعات، مرتجعات، ملاحظات) ←
        </a>
        <div className="mb-5 flex items-center justify-between">
          <Card className="flex-1 p-5 sm:p-6">
            <p className="text-sm text-charcoal/50">{selected.name}</p>
            <p className="mt-1 text-2xl font-semibold tracking-tight text-charcoal" dir="ltr">
              <Money value={selected.balance} />
            </p>
          </Card>
          {canExport && (
            <div className="mr-3">
              <ExportButtons
                filename={`كشف-حساب-${selected.name}`}
                headers={["التاريخ", "النوع", "المرجع", "مدين", "دائن", "الرصيد"]}
                rows={ledger.map((r) => [r.entry_date, ENTRY_LABEL[r.entry_type] ?? r.entry_type, r.reference, r.increase || "", r.decrease || "", r.balance])}
              />
            </div>
          )}
        </div>
        <DataTable<LedgerRow & { key: string }>
          rows={ledger.map((r, i) => ({ ...r, key: `${r.entry_date}-${r.entry_type}-${r.reference}-${i}` }))}
          getRowKey={(r) => r.key}
          emptyLabel="لا توجد حركات"
          columns={[
            { header: "التاريخ", render: (r) => <span dir="ltr">{r.entry_date}</span> },
            { header: "النوع", render: (r) => ENTRY_LABEL[r.entry_type] ?? r.entry_type },
            { header: "المرجع", render: (r) => r.reference || "—" },
            { header: "مدين", render: (r) => (r.increase > 0 ? <Money value={r.increase} suffix="" /> : "—") },
            { header: "دائن", render: (r) => (r.decrease > 0 ? <Money value={r.decrease} suffix="" /> : "—") },
            { header: "الرصيد", render: (r) => <Money value={r.balance} suffix="" /> },
          ]}
        />
      </div>
    );
  }

  return (
    <div>
      {canExport && (
        <div className="mb-4 flex justify-end">
          <ExportButtons
            filename={type === "customer" ? "أرصدة-العملاء" : "أرصدة-الموردين"}
            headers={["الاسم", "الهاتف", totalLabel, settledLabel, "الرصيد"]}
            rows={rows.map((r) => [r.name, r.phone ?? "", r.total, r.settled, r.balance])}
          />
        </div>
      )}
      <DataTable<BalanceRow>
        rows={rows}
        getRowKey={(r) => r.party_id}
        emptyLabel="لا توجد بيانات"
        columns={[
          {
            header: "الاسم",
            render: (r) => (
              <a href={`${basePath}?party=${r.party_id}`} className="text-charcoal hover:text-sage hover:underline">
                {r.name}
              </a>
            ),
          },
          { header: "الهاتف", render: (r) => <span dir="ltr">{r.phone ?? "—"}</span> },
          { header: totalLabel, render: (r) => <span dir="ltr"><Money value={r.total} /></span> },
          { header: settledLabel, render: (r) => <span dir="ltr"><Money value={r.settled} /></span> },
          {
            header: "الرصيد",
            render: (r) => (
              <span dir="ltr" className={r.balance > 0 ? "text-rose" : "text-sage"}>
                <Money value={r.balance} />
              </span>
            ),
          },
        ]}
      />
    </div>
  );
}

const TIER_LABEL: Record<string, string> = { retail: "تجزئة", wholesale: "جملة", distributor: "موزع" };

// The customer list for someone who may not see money. The database already limits a rep to the customers assigned
// to them, so this simply lists what they are allowed to read.
async function CustomersWithoutMoney({ supabase, q }: { supabase: Awaited<ReturnType<typeof getReportContext>>["supabase"]; q: string }) {
  let query = supabase.from("customers").select("id, name, phone, price_tier").order("name").limit(500);
  if (q) query = query.or(`name.ilike.%${q.replace(/[\\%_,()]/g, "")}%,phone.ilike.%${q.replace(/[\\%_,()]/g, "")}%`);
  const { data, error } = await query;
  const rows = (data as { id: string; name: string; phone: string | null; price_tier: string }[] | null) ?? [];

  return (
    <div>
      <p className="mb-4 text-xs leading-6 text-charcoal/50">العملاء المسندون إليك.</p>
      <div className="mb-4">
        <SearchBox placeholder="ابحث باسم العميل أو هاتفه" />
      </div>
      {error && <p className="mb-3 text-sm text-rose">{error.message}</p>}
      <DataTable<(typeof rows)[number]>
        rows={rows}
        getRowKey={(r) => r.id}
        emptyLabel={q ? "لا توجد نتائج مطابقة للبحث" : "لا يوجد عملاء مسندون إليك بعد"}
        columns={[
          { header: "الاسم", render: (r) => r.name },
          { header: "الهاتف", render: (r) => <span dir="ltr" className="num">{r.phone ?? "—"}</span> },
          { header: "نوع العميل", render: (r) => TIER_LABEL[r.price_tier] ?? r.price_tier },
        ]}
      />
    </div>
  );
}
