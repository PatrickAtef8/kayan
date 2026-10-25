import Link from "next/link";
import { ModernSelect } from "@/components/ui/select";
import { getReportContext } from "@/lib/report-context";
import { isRestrictedRep } from "@/lib/org-context";
import { Card } from "@/components/ui/card";
import { Stat, SimpleTable, money } from "../party-analysis";

type CustRow = {
  customer_id: string; customer_name: string; phone: string | null; rep_id: string | null; rep_name: string | null;
  opening_balance: number; total_sales: number; total_paid: number; total_returned: number; outstanding: number;
  last_payment_date: string | null; last_payment_amount: number | null; grand_total: number; total_count: number;
};
type SupRow = {
  supplier_id: string; supplier_name: string; phone: string | null;
  opening_balance: number; total_purchases: number; total_paid: number; total_returned: number; outstanding: number;
  last_payment_date: string | null; last_payment_amount: number | null; grand_total: number; total_count: number;
};

const PAGE = 100;

export default async function DebtsPage(
  props: { searchParams: Promise<{ type?: string; q?: string; rep?: string; all?: string; page?: string }> }
) {
  const searchParams = await props.searchParams;
  const { supabase, orgId } = await getReportContext();
  if (!orgId) return null;

  const restricted = await isRestrictedRep();
  const type = searchParams.type === "supplier" && !restricted ? "supplier" : "customer";
  const q = searchParams.q?.trim() ?? "";
  const onlyDebt = searchParams.all !== "1";
  const page = Math.max(1, Number(searchParams.page) || 1);
  const qs = (patch: Record<string, string | undefined>) => {
    const p = new URLSearchParams({ type, ...(q ? { q } : {}), ...(searchParams.rep ? { rep: searchParams.rep } : {}), ...(onlyDebt ? {} : { all: "1" }), ...patch });
    for (const [k, v] of [...p.entries()]) if (!v) p.delete(k);
    return `/dashboard/reports/debts?${p.toString()}`;
  };

  const { data: reps } = await supabase.from("sales_representatives").select("id, name").eq("organization_id", orgId).order("name");
  const call =
    type === "customer"
      ? await supabase.rpc("report_customer_debts", { org_id: orgId, p_search: q || null, p_rep_id: searchParams.rep || null, p_only_debt: onlyDebt, p_limit: PAGE, p_offset: (page - 1) * PAGE })
      : await supabase.rpc("report_supplier_debts", { org_id: orgId, p_search: q || null, p_only_debt: onlyDebt, p_limit: PAGE, p_offset: (page - 1) * PAGE });

  if (call.error) return <p className="text-sm text-rose">{call.error.message}</p>;
  const rows = (call.data as (CustRow | SupRow)[]) ?? [];
  const grand = rows[0]?.grand_total ?? 0;
  const count = rows[0]?.total_count ?? 0;

  return (
    <div>
      <div className="mb-5 flex gap-2">
        {(restricted ? (["customer"] as const) : (["customer", "supplier"] as const)).map((t) => (
          <Link key={t} href={`/dashboard/reports/debts?type=${t}`} className={`rounded-lg px-3 py-2 text-sm font-medium ${type === t ? "bg-sageSoft text-sage" : "text-charcoal/50 hover:bg-paper"}`}>
            {t === "customer" ? "مديونيات العملاء" : "مديونيات الموردين (المستحق علينا)"}
          </Link>
        ))}
      </div>

      <Card className="mb-5 p-4">
        <form className="flex flex-wrap items-end gap-3" action="/dashboard/reports/debts">
          <input type="hidden" name="type" value={type} />
          <label className="text-xs text-charcoal/50">
            بحث
            <input name="q" defaultValue={q} placeholder="الاسم أو الهاتف" className="mt-1 block h-10 w-56 rounded-xl border border-borderSoft px-3 text-sm text-charcoal focus:border-sage focus:outline-none" />
          </label>
          {type === "customer" && !restricted && (
            <div className="text-xs text-charcoal/50">
              المندوب
              <div className="mt-1 w-56"><ModernSelect name="rep" defaultValue={searchParams.rep ?? ""} placeholder="كل المناديب" clearLabel="كل المناديب" options={(reps ?? []).map((r) => ({ value: r.id, label: r.name }))} /></div>
            </div>
          )}
          <label className="flex items-center gap-2 pb-2 text-xs text-charcoal/60">
            <input type="checkbox" name="all" value="1" defaultChecked={!onlyDebt} /> إظهار الأرصدة الصفرية
          </label>
          <button className="h-10 rounded-xl bg-sage px-4 text-sm font-medium text-white">تطبيق</button>
        </form>
      </Card>

      <div className="mb-5 grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Stat label={type === "customer" ? "إجمالي مديونيات العملاء (حسب الفلتر)" : "إجمالي ما علينا للموردين (حسب الفلتر)"} value={`${money(grand)} ج.م`} tone="rose" />
        <Stat label={type === "customer" ? "عدد العملاء" : "عدد الموردين"} value={count} />
      </div>

      {type === "customer" ? (
        <SimpleTable
          empty="لا توجد مديونيات مطابقة"
          head={["العميل", "المندوب", "إجمالي المبيعات", "إجمالي المدفوعات", "المرتجعات", "المديونية الحالية", "آخر دفعة", "تاريخها", ""]}
          rows={(rows as CustRow[]).map((r) => [
            <Link key="n" href={`/dashboard/reports/customers/${r.customer_id}`} className="text-sage hover:underline">{r.customer_name}</Link>,
            r.rep_name ?? "—",
            <span dir="ltr" key="s">{money(r.total_sales)}</span>,
            <span dir="ltr" key="p">{money(r.total_paid)}</span>,
            <span dir="ltr" key="r">{money(r.total_returned)}</span>,
            <span dir="ltr" key="o" className="font-semibold text-rose">{money(r.outstanding)}</span>,
            <span dir="ltr" key="la">{r.last_payment_amount != null ? money(r.last_payment_amount) : "—"}</span>,
            <span dir="ltr" key="ld">{r.last_payment_date ?? "—"}</span>,
            <Link key="st" href={`/dashboard/reports/debts/statement/customer/${r.customer_id}`} className="text-xs text-sage hover:underline">كشف حساب</Link>,
          ])}
        />
      ) : (
        <SimpleTable
          empty="لا توجد مديونيات مطابقة"
          head={["المورد", "إجمالي المشتريات", "المدفوع", "المرتجعات", "المستحق له", "آخر دفعة", "تاريخها", ""]}
          rows={(rows as SupRow[]).map((r) => [
            <Link key="n" href={`/dashboard/reports/suppliers/${r.supplier_id}`} className="text-sage hover:underline">{r.supplier_name}</Link>,
            <span dir="ltr" key="s">{money(r.total_purchases)}</span>,
            <span dir="ltr" key="p">{money(r.total_paid)}</span>,
            <span dir="ltr" key="r">{money(r.total_returned)}</span>,
            <span dir="ltr" key="o" className="font-semibold text-rose">{money(r.outstanding)}</span>,
            <span dir="ltr" key="la">{r.last_payment_amount != null ? money(r.last_payment_amount) : "—"}</span>,
            <span dir="ltr" key="ld">{r.last_payment_date ?? "—"}</span>,
            <Link key="st" href={`/dashboard/reports/debts/statement/supplier/${r.supplier_id}`} className="text-xs text-sage hover:underline">كشف حساب</Link>,
          ])}
        />
      )}
      <p className="mt-2 text-xs text-charcoal/45">الرصيد الافتتاحي مضمّن في المديونية الحالية. المبيعات/المشتريات هنا قبل التحصيل، والمدفوعات تشمل ما دُفع وقت الفاتورة.</p>
      {count > PAGE && (
        <div className="mt-4 flex gap-3 text-sm">
          {page > 1 && <Link href={qs({ page: String(page - 1) })} className="text-sage hover:underline">السابق</Link>}
          {page * PAGE < count && <Link href={qs({ page: String(page + 1) })} className="text-sage hover:underline">التالي</Link>}
        </div>
      )}
    </div>
  );
}
