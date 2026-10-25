import { Money } from "@/components/ui/money";
import { notFound } from "next/navigation";
import { getReportContext } from "@/lib/report-context";
import { ExportButtons } from "@/components/ui/export-buttons";
import { BackLink, Section, SimpleTable, Stat } from "../../../../party-analysis";
import { STATUS_LABEL, STATUS_STYLE, dateText, money } from "@/lib/party-reports";

type Item = {
  kind: string; doc_id: string | null; doc_number: string | null; doc_date: string | null; due_date: string | null;
  doc_total: number; linked_paid: number; returns_net: number; on_account_applied: number; remaining: number;
  days_overdue: number | null; status: string;
};
type Pay = { payment_id: string; payment_date: string; amount: number; payment_method: string | null; reference: string | null; doc_number: string | null; notes: string | null; total_amount: number };
type Led = { entry_date: string; entry_type: string; reference: string; description: string; increase: number; decrease: number; balance: number };

const LEDGER_LABEL: Record<string, string> = {
  opening: "رصيد مُرحَّل", sale: "فاتورة بيع", collection: "تحصيل", return: "مرتجع", refund: "استرداد نقدي", purchase: "فاتورة شراء", payment: "دفعة",
};

export default async function StatementPage(props: { params: Promise<{ type: string; id: string }> }) {
  const { type, id } = await props.params;
  if (type !== "customer" && type !== "supplier") notFound();
  const isCustomer = type === "customer";

  const { supabase, orgId, canExport } = await getReportContext();
  if (!orgId) return null;

  const [items, pays, ledger, party] = await Promise.all([
    supabase.rpc("report_party_open_items", { org_id: orgId, p_type: type, p_party: id }),
    supabase.rpc("report_party_payments", { org_id: orgId, p_type: type, p_party: id, p_limit: 1000, p_offset: 0 }),
    supabase.rpc("report_party_ledger", { org_id: orgId, p_type: type, p_party: id }),
    isCustomer
      ? supabase.from("customers").select("name, phone, sales_representatives(name)").eq("id", id).eq("organization_id", orgId).maybeSingle()
      : supabase.from("suppliers").select("name, phone, payment_terms_days").eq("id", id).eq("organization_id", orgId).maybeSingle(),
  ]);
  if (items.error) return <p className="text-sm text-rose">{items.error.message}</p>;
  if (!party.data) notFound();

  const rows = ((items.data as Item[]) ?? []).map((r) => ({
    ...r, doc_total: Number(r.doc_total), linked_paid: Number(r.linked_paid), returns_net: Number(r.returns_net), on_account_applied: Number(r.on_account_applied), remaining: Number(r.remaining),
  }));
  const payments = ((pays.data as Pay[]) ?? []).map((p) => ({ ...p, amount: Number(p.amount) }));
  const paidTotal = Number(payments[0]?.total_amount ?? 0);
  const ledgerRows = ledger.error ? [] : ((ledger.data as Led[]) ?? []);

  const opening = rows.find((r) => r.kind === "opening")?.doc_total ?? 0;
  const invoiced = rows.filter((r) => r.kind === "invoice").reduce((a, r) => a + r.doc_total, 0);
  const returnsNet = rows.reduce((a, r) => a + r.returns_net, 0);
  const balance = rows.reduce((a, r) => a + r.remaining, 0);
  const expected = opening + invoiced - paidTotal - returnsNet;
  const reconciled = Math.abs(expected - balance) < 0.005;
  const p = party.data as unknown as { name: string; phone: string | null; sales_representatives?: { name: string } | { name: string }[] | null; payment_terms_days?: number | null };
  const repName = Array.isArray(p.sales_representatives) ? p.sales_representatives[0]?.name : p.sales_representatives?.name;
  const docLabel = (r: Item) => (r.kind === "opening" ? "رصيد افتتاحي" : r.kind === "credit" ? "رصيد دائن" : r.doc_number ? `${isCustomer ? "فاتورة" : "فاتورة شراء"} ${r.doc_number}` : isCustomer ? "فاتورة" : "فاتورة شراء");

  return (
    <div>
      <div className="no-print"><BackLink href="/dashboard/reports/debts" label="تقرير المديونيات" /></div>
      <div className="mb-5 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-xl font-semibold text-charcoal">كشف حساب {isCustomer ? "العميل" : "المورد"}: {p.name}</h2>
          <p className="mt-1 text-sm text-charcoal/55">
            {isCustomer && <>المندوب: <span className="font-medium text-charcoal">{repName ?? "غير محدد"}</span></>}
            {!isCustomer && p.payment_terms_days != null && <>مدة السداد: <span className="font-medium text-charcoal">{p.payment_terms_days} يوم</span></>}
            {p.phone && <span className="mr-4" dir="ltr">{p.phone}</span>}
            <span className="mr-4">بتاريخ {dateText(new Date().toLocaleDateString("en-CA", { timeZone: "Africa/Cairo" }))}</span>
          </p>
        </div>
        {canExport && (
          <ExportButtons
            filename={`كشف-حساب-${p.name}`}
            headers={["البند", "التاريخ", ...(isCustomer ? [] : ["الاستحقاق"]), "الإجمالي", "مدفوع (مربوط بالفاتورة)", "مرتجع", "سُدِّد من دفعات على الحساب", "المتبقي", "الحالة"]}
            rows={rows.map((r) => [docLabel(r), r.doc_date ?? "", ...(isCustomer ? [] : [r.due_date ?? ""]), r.doc_total, r.linked_paid, r.returns_net, r.on_account_applied, r.remaining, STATUS_LABEL[r.status] ?? r.status])}
          />
        )}
      </div>

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-5">
        <Stat label="رصيد افتتاحي" value={<Money value={opening} suffix="" />} />
        <Stat label="إجمالي الفواتير" value={<Money value={invoiced} suffix="" />} />
        <Stat label={isCustomer ? "إجمالي المحصّل" : "إجمالي المدفوع"} value={<Money value={paidTotal} suffix="" />} tone="sage" />
        <Stat label="المرتجعات (بعد المسترد نقدًا)" value={<Money value={returnsNet} suffix="" />} />
        <Stat label={isCustomer ? "المتبقي على العميل" : "المتبقي للمورد"} value={<Money value={balance} />} tone={balance > 0 ? "rose" : undefined} />
      </div>
      <p className={`mt-2 text-xs ${reconciled ? "text-charcoal/45" : "font-medium text-rose"}`}>
        {reconciled ? "✓ " : "⚠ لا يتطابق: "}الرصيد = رصيد افتتاحي ({money(opening)}) + الفواتير ({money(invoiced)}) − {isCustomer ? "المحصّل" : "المدفوع"} ({money(paidTotal)}) − المرتجعات ({money(returnsNet)}) = {money(expected)}
        {reconciled ? " — يطابق مجموع المتبقي على الفواتير أدناه." : ` — بينما مجموع المتبقي ${money(balance)}.`}
      </p>

      <Section title="الفواتير والمتبقي على كل فاتورة">
        <SimpleTable
          empty="لا توجد فواتير"
          head={["البند", "التاريخ", ...(isCustomer ? [] : ["الاستحقاق"]), "الإجمالي", "مدفوع (مربوط)", "مرتجع", "سُدِّد من «على الحساب»", "المتبقي", "الحالة"]}
          rows={rows.map((r) => [
            docLabel(r),
            dateText(r.doc_date),
            ...(isCustomer ? [] : [dateText(r.due_date)]),
            <span dir="ltr" key="t">{r.kind === "credit" ? "—" : money(r.doc_total)}</span>,
            <span dir="ltr" key="lp">{r.linked_paid > 0 ? money(r.linked_paid) : "—"}</span>,
            <span dir="ltr" key="rn">{r.returns_net > 0 ? money(r.returns_net) : "—"}</span>,
            <span dir="ltr" key="oa">{r.on_account_applied > 0 ? money(r.on_account_applied) : "—"}</span>,
            <Money value={r.remaining} suffix="" key="rm" className={`font-medium ${r.remaining > 0 ? "text-rose" : ""}`} />,
            <span key="s" className={`rounded-md px-2 py-0.5 text-xs font-medium ${STATUS_STYLE[r.status] ?? ""}`}>
              {STATUS_LABEL[r.status] ?? r.status}{r.days_overdue ? ` ${r.days_overdue} يوم` : ""}
            </span>,
          ])}
        />
      </Section>

      <Section title={isCustomer ? "الدفعات المستلمة" : "الدفعات المسددة"}>
        <SimpleTable
          empty="لا توجد دفعات"
          head={["التاريخ", "المبلغ", "طريقة الدفع", "المرجع", "سُدِّد به", "ملاحظات"]}
          rows={payments.map((x) => [
            dateText(x.payment_date),
            <Money value={x.amount} suffix="" key="a" className="font-medium" />,
            x.payment_method ?? "—",
            <span dir="ltr" key="r">{x.reference ?? "—"}</span>,
            x.doc_number ? <span dir="ltr" key="d">فاتورة {x.doc_number}</span> : <span key="d" className="text-charcoal/50">على الحساب</span>,
            x.notes ?? "—",
          ])}
        />
      </Section>

      {ledgerRows.length > 0 && (
        <Section title="حركة الحساب بالتاريخ (الرصيد التراكمي)">
          <SimpleTable
            empty="لا توجد حركات"
            head={["التاريخ", "النوع", "المرجع", "مدين (علينا/له)", "دائن", "الرصيد"]}
            rows={ledgerRows.map((l) => [
              dateText(l.entry_date),
              LEDGER_LABEL[l.entry_type] ?? l.entry_type,
              <span dir="ltr" key="r">{l.reference || "—"}</span>,
              <span dir="ltr" key="i">{Number(l.increase) > 0 ? money(l.increase) : "—"}</span>,
              <span dir="ltr" key="d">{Number(l.decrease) > 0 ? money(l.decrease) : "—"}</span>,
              <Money value={l.balance} suffix="" key="b" className="font-medium" />,
            ])}
          />
        </Section>
      )}
      <p className="mt-4 text-xs text-charcoal/45">
        الدفعات غير المربوطة بفاتورة («على الحساب») تُسدِّد الأقدم أولًا: الرصيد الافتتاحي ثم الفواتير بتاريخها. المرتجع يُخصم من فاتورته، وما رُدَّ نقدًا لا يُعدّ رصيدًا. مجموع «المتبقي» يساوي رصيد {isCustomer ? "العميل" : "المورد"} في صفحة المديونيات.
      </p>
    </div>
  );
}
