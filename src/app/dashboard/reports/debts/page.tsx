import { Money } from "@/components/ui/money";
import Link from "next/link";
import { SearchBox } from "@/components/ui/search-box";
import { ParamSelect } from "@/components/reports/param-select";
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
  const showAll = searchParams.all === "1";
  // Searching always looks at everybody: someone who owes nothing must still be findable by name.
  const onlyDebt = !showAll && !q;
  const page = Math.max(1, Number(searchParams.page) || 1);
  const qs = (patch: Record<string, string | undefined>) => {
    const p = new URLSearchParams({ type, ...(q ? { q } : {}), ...(searchParams.rep ? { rep: searchParams.rep } : {}), ...(showAll ? { all: "1" } : {}), ...patch });
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
        <div className="flex flex-wrap items-end gap-3">
          <div className="w-full sm:w-72">
            <SearchBox placeholder={type === "customer" ? "ابحث باسم العميل أو هاتفه" : "ابحث باسم المورد أو هاتفه"} />
          </div>
          {type === "customer" && !restricted && (
            <ParamSelect param="rep" value={searchParams.rep ?? ""} placeholder="كل المناديب" clearLabel="كل المناديب" options={(reps ?? []).map((r) => ({ value: r.id, label: r.name }))} />
          )}
        </div>
        <div className="mt-3 flex flex-wrap items-center gap-1.5">
          <span className="text-xs text-charcoal/40">أعرض:</span>
          <Link href={qs({ all: undefined, page: undefined })} scroll={false} className={`rounded-lg px-2.5 py-1.5 text-xs font-medium ${!showAll ? "bg-charcoal text-ivory" : "bg-paper text-charcoal/50 hover:text-charcoal"}`}>
            {type === "customer" ? "العملاء الذين عليهم مديونية" : "الموردون الذين لهم مستحقات"}
          </Link>
          <Link href={qs({ all: "1", page: undefined })} scroll={false} className={`rounded-lg px-2.5 py-1.5 text-xs font-medium ${showAll ? "bg-charcoal text-ivory" : "bg-paper text-charcoal/50 hover:text-charcoal"}`}>
            {type === "customer" ? "كل العملاء" : "كل الموردين"}
          </Link>
        </div>
        <p className="mt-2 text-xs leading-6 text-charcoal/45">
          {q
            ? `نتائج البحث تشمل الجميع، حتى من ليس عليه مديونية.`
            : showAll
              ? type === "customer" ? "تظهر القائمة كل العملاء، ومنهم من رصيده صفر أو سدّد كل ما عليه." : "تظهر القائمة كل الموردين، ومنهم من رصيده صفر."
              : type === "customer" ? "تظهر القائمة العملاء الذين عليهم مبلغ غير مسدّد فقط." : "تظهر القائمة الموردين الذين لهم مبلغ علينا فقط."}
        </p>
      </Card>

      <div className="mb-5 grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Stat label={type === "customer" ? "إجمالي مديونيات العملاء (حسب الفلتر)" : "إجمالي ما علينا للموردين (حسب الفلتر)"} value={<Money value={grand} />} tone="rose" />
        <Stat label={type === "customer" ? "عدد العملاء" : "عدد الموردين"} value={count} />
      </div>

      {type === "customer" ? (
        <SimpleTable
          empty={q ? "لا توجد نتائج مطابقة للبحث" : showAll ? "لا يوجد عملاء مطابقون" : "لا توجد مديونيات مطابقة"}
          head={["العميل", "المندوب", "إجمالي المبيعات", "إجمالي المدفوعات", "المرتجعات", "المديونية الحالية", "آخر دفعة", "تاريخها", ""]}
          rows={(rows as CustRow[]).map((r) => [
            <Link key="n" href={`/dashboard/reports/customers/${r.customer_id}`} className="text-sage hover:underline">{r.customer_name}</Link>,
            r.rep_name ?? "—",
            <Money value={r.total_sales} suffix="" key="s" />,
            <Money value={r.total_paid} suffix="" key="p" />,
            <Money value={r.total_returned} suffix="" key="r" />,
            <Money value={r.outstanding} suffix="" key="o" className="font-semibold text-rose" />,
            <span dir="ltr" key="la">{r.last_payment_amount != null ? money(r.last_payment_amount) : "—"}</span>,
            <span dir="ltr" key="ld">{r.last_payment_date ?? "—"}</span>,
            <Link key="st" href={`/dashboard/reports/debts/statement/customer/${r.customer_id}`} className="text-xs text-sage hover:underline">كشف حساب</Link>,
          ])}
        />
      ) : (
        <SimpleTable
          empty={q ? "لا توجد نتائج مطابقة للبحث" : showAll ? "لا يوجد موردون مطابقون" : "لا توجد مديونيات مطابقة"}
          head={["المورد", "إجمالي المشتريات", "المدفوع", "المرتجعات", "المستحق له", "آخر دفعة", "تاريخها", ""]}
          rows={(rows as SupRow[]).map((r) => [
            <Link key="n" href={`/dashboard/reports/suppliers/${r.supplier_id}`} className="text-sage hover:underline">{r.supplier_name}</Link>,
            <Money value={r.total_purchases} suffix="" key="s" />,
            <Money value={r.total_paid} suffix="" key="p" />,
            <Money value={r.total_returned} suffix="" key="r" />,
            <Money value={r.outstanding} suffix="" key="o" className="font-semibold text-rose" />,
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
