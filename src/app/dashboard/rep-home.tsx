import Link from "next/link";
import type { SupabaseClient } from "@supabase/supabase-js";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { StatValue } from "@/components/ui/stat-value";
import { PeriodPicker } from "@/components/ui/period-picker";
import { resolvePeriod, type PeriodSel } from "@/lib/report-period";

// The sales representative's home. EVERYTHING here is read with the rep's own session, so the database
// (row-level security) already limits it to his assigned customers and his own invoices. It deliberately
// shows no company figure: no profit, treasury, suppliers, stock value or company-wide totals.

const money = (n: number | null | undefined) => Number(n ?? 0).toLocaleString("ar-EG", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

type Rollup = { kind: string; group_label: string; invoices: number; net_sales: number };
type Perf = { net_sales: number; collected: number; monthly_target: number | null; min_target_for_commission: number | null; commission_eligible: boolean; earned_commission: number; potential_commission: number };

export async function RepHome({ supabase, orgId, period }: { supabase: SupabaseClient; orgId: string; period: PeriodSel }) {
  // The target card follows a picked month; for a year / all-time view it shows the current month.
  const perfMonth = period.kind === "month" && period.month ? period.month : (resolvePeriod({}).month as string);
  const monthStart = `${perfMonth}-01`;

  const [totalsRes, rollupsRes, customersRes, balancesRes, perfRes, invoicesRes] = await Promise.all([
    supabase.rpc("dashboard_sales_totals", { org_id: orgId, p_from: period.from, p_to: period.to }),
    supabase.rpc("dashboard_sales_rollups", { org_id: orgId, p_from: period.from, p_to: period.to }),
    supabase.from("customers").select("id, name").order("name").limit(1000),
    supabase.from("customer_balances").select("customer_id, balance").limit(1000),
    supabase.from("rep_monthly_performance").select("net_sales, collected, monthly_target, min_target_for_commission, commission_eligible, earned_commission, potential_commission").eq("month", monthStart).limit(1),
    supabase.from("v_sales_invoices").select("id, invoice_number, invoice_date, customer_id, total").order("created_at", { ascending: false }).limit(8),
  ]);

  const totalsRow = Array.isArray(totalsRes.data) ? totalsRes.data[0] : null;
  const netSales = Number(totalsRow?.total_sales ?? 0);
  const topCustomers = ((rollupsRes.data as Rollup[] | null) ?? []).filter((r) => r.kind === "customer").slice(0, 5);
  const customers = (customersRes.data as { id: string; name: string }[] | null) ?? [];
  const nameOf = new Map(customers.map((c) => [c.id, c.name]));
  const balances = ((balancesRes.data as { customer_id: string; balance: number | null }[] | null) ?? []).filter((b) => b.balance !== null);
  const owedTotal = balances.reduce((s, b) => s + Math.max(Number(b.balance), 0), 0);
  const topDebtors = balances
    .filter((b) => Number(b.balance) > 0)
    .sort((a, b) => Number(b.balance) - Number(a.balance))
    .slice(0, 5)
    .map((b) => ({ name: nameOf.get(b.customer_id) ?? "—", balance: Number(b.balance) }));
  const perf = ((perfRes.data as Perf[] | null) ?? [])[0];
  const invoices = (invoicesRes.data as { id: string; invoice_number: string | null; invoice_date: string; customer_id: string; total: number }[] | null) ?? [];

  const target = Number(perf?.monthly_target ?? 0);
  const monthNet = Number(perf?.net_sales ?? 0);
  const progress = target > 0 ? Math.min(100, Math.round((monthNet / target) * 100)) : null;

  const cards = [
    { label: "مبيعات عملائك", value: money(netSales), unit: "ج.م", note: period.label },
    { label: "عدد عملائك", value: customers.length.toLocaleString("ar-EG"), unit: "", note: "العملاء المسندون إليك" },
    { label: "مستحق لك عند عملائك", value: money(owedTotal), unit: "ج.م", note: "الرصيد الحالي لعملائك فقط" },
  ];

  return (
    <div>
      <PageHeader title="الرئيسية" />
      <p className="mb-5 rounded-card bg-paper px-3 py-2 text-xs text-charcoal/60">كل الأرقام هنا تخص العملاء المسندين إليك وفواتيرك فقط.</p>

      <div className="mb-5 w-full sm:w-48">
        <PeriodPicker sel={period} />
      </div>

      <div className="mb-6 grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-3">
        {cards.map((c) => (
          <Card key={c.label} className="p-4 sm:p-5 last:odd:sm:col-span-2 last:odd:xl:col-span-1">
            <p className="text-xs text-charcoal/50">{c.label}</p>
            <StatValue className="mt-2" size="lg" value={c.value} unit={c.unit} />
            <p className="mt-1 text-[0.6875rem] text-charcoal/35">{c.note}</p>
          </Card>
        ))}
      </div>

      {perf && (
        <Card className="mb-7 p-5">
          <p className="mb-3 text-xs font-medium text-charcoal/40">{period.kind === "month" && !period.isCurrent ? `أداؤك في ${period.title}` : "أداؤك هذا الشهر"}</p>
          <div className="grid grid-cols-1 gap-4 min-[440px]:grid-cols-2 lg:grid-cols-4">
            <div><p className="text-[0.6875rem] text-charcoal/45">صافي مبيعاتك</p><StatValue className="mt-1" size="md" value={money(monthNet)} unit="ج.م" /></div>
            <div><p className="text-[0.6875rem] text-charcoal/45">ما حصّلته</p><StatValue className="mt-1" size="md" value={money(perf.collected)} unit="ج.م" /></div>
            {target > 0 && <div><p className="text-[0.6875rem] text-charcoal/45">هدفك الشهري</p><StatValue className="mt-1" size="md" value={money(target)} unit="ج.م" /></div>}
            <div><p className="text-[0.6875rem] text-charcoal/45">عمولتك</p><StatValue className="mt-1" size="md" value={money(perf.earned_commission)} unit="ج.م" /></div>
          </div>
          {progress !== null && (
            <div className="mt-4">
              <div className="h-2 overflow-hidden rounded-full bg-paper"><div className="h-full rounded-full bg-sage" style={{ width: `${progress}%` }} /></div>
              <p className="mt-1.5 text-[0.6875rem] text-charcoal/45">أنجزت {progress.toLocaleString("ar-EG")}٪ من هدفك الشهري{perf.commission_eligible ? "" : " — لم تصل بعد للحد الأدنى لاستحقاق العمولة"}</p>
            </div>
          )}
        </Card>
      )}

      <div className="mb-6 grid grid-cols-1 gap-4 xl:grid-cols-2">
        <Card className="p-5">
          <p className="mb-3 text-xs font-medium text-charcoal/40">أكثر عملائك شراءً</p>
          {topCustomers.length === 0 ? <p className="text-sm text-charcoal/40">لا توجد مبيعات في هذه الفترة.</p> : (
            <ul className="divide-y divide-borderSoft">
              {topCustomers.map((r) => (
                <li key={r.group_label} className="flex items-center justify-between gap-3 py-2.5 text-sm">
                  <span className="min-w-0 break-words text-charcoal">{r.group_label}</span>
                  <span className="num shrink-0 text-charcoal/70" dir="ltr">{money(r.net_sales)} ج.م</span>
                </li>
              ))}
            </ul>
          )}
        </Card>
        <Card className="p-5">
          <p className="mb-3 text-xs font-medium text-charcoal/40">عملاء عليهم مستحقات</p>
          {topDebtors.length === 0 ? <p className="text-sm text-charcoal/40">لا توجد مستحقات على عملائك.</p> : (
            <ul className="divide-y divide-borderSoft">
              {topDebtors.map((r) => (
                <li key={r.name} className="flex items-center justify-between gap-3 py-2.5 text-sm">
                  <span className="min-w-0 break-words text-charcoal">{r.name}</span>
                  <span className="num shrink-0 text-rose" dir="ltr">{money(r.balance)} ج.م</span>
                </li>
              ))}
            </ul>
          )}
        </Card>
      </div>

      <Card className="p-5">
        <div className="mb-3 flex items-center justify-between">
          <p className="text-xs font-medium text-charcoal/40">آخر فواتيرك</p>
          <Link href="/dashboard/sales" className="text-xs text-sage hover:underline">فاتورة جديدة</Link>
        </div>
        {invoices.length === 0 ? <p className="text-sm text-charcoal/40">لم تسجل أي فاتورة بعد.</p> : (
          <ul className="divide-y divide-borderSoft">
            {invoices.map((i) => (
              <li key={i.id} className="flex items-center justify-between gap-3 py-2.5 text-sm">
                <div className="min-w-0">
                  <p className="text-charcoal">{nameOf.get(i.customer_id) ?? "—"}</p>
                  <p className="text-xs text-charcoal/40"><span dir="ltr">{i.invoice_number ? `#${i.invoice_number} · ` : ""}{i.invoice_date}</span></p>
                </div>
                <span className="num shrink-0 text-charcoal/70" dir="ltr">{money(i.total)} ج.م</span>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}
