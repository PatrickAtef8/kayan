import { getReportContext } from "@/lib/report-context";
import { Card } from "@/components/ui/card";
import { DataTable } from "@/components/ui/data-table";
import { NoFinancialAccess } from "@/components/reports/no-financial-access";
import { ExportButtons } from "@/components/ui/export-buttons";

function money(n: number) {
  return n.toLocaleString("ar-EG", { minimumFractionDigits: 2 });
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
  searchParams: { party?: string };
}) {
  const { supabase, orgId, canViewFinancial, canExport } = await getReportContext();
  if (!orgId) return null;
  if (!canViewFinancial) return <NoFinancialAccess />;

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
              {money(selected.balance)} ج.م
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
            { header: "مدين", render: (r) => (r.increase > 0 ? <span dir="ltr">{money(r.increase)}</span> : "—") },
            { header: "دائن", render: (r) => (r.decrease > 0 ? <span dir="ltr">{money(r.decrease)}</span> : "—") },
            { header: "الرصيد", render: (r) => <span dir="ltr">{money(r.balance)}</span> },
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
          { header: totalLabel, render: (r) => <span dir="ltr">{money(r.total)} ج.م</span> },
          { header: settledLabel, render: (r) => <span dir="ltr">{money(r.settled)} ج.م</span> },
          {
            header: "الرصيد",
            render: (r) => (
              <span dir="ltr" className={r.balance > 0 ? "text-rose" : "text-sage"}>
                {money(r.balance)} ج.م
              </span>
            ),
          },
        ]}
      />
    </div>
  );
}
