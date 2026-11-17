import Link from "next/link";
import { Check } from "lucide-react";
import { Card } from "@/components/ui/card";
import { InlinePayment } from "@/components/pricing/inline-payment";
import { OPTION_LABEL, PURPOSE_LABEL } from "@/lib/billing/labels";
import { orderRef } from "@/components/pricing/result-shell";
import { formatMoney } from "@/lib/money";

const egp = (piasters: number) => `${formatMoney(piasters / 100, piasters % 100 === 0 ? 0 : 2)} ج.م`;

// The look of step 2 (Kayan's payment page), separate from the data loading in page.tsx so it can be reviewed with sample data.
export type PayViewProps = {
  order: { id: string; amount_total: number; purpose: "initial" | "renewal"; payment_option: string };
  pkgName: string;
  lines: { id: string; label: string; amount: number }[] | null;      // null: the lines do not add up to the order total, show the total alone
  recurring: { label: string; amount: number } | null;
  orgName: string; email: string;
  publishableKey: string; clientSecret: string; testMode: boolean; backHref: string;
};

export function PayView({ order, pkgName, lines, recurring, orgName, email, publishableKey, clientSecret, testMode, backHref }: PayViewProps) {
  return (
    <div className="mx-auto max-w-5xl">
      <Steps />
      <h1 className="text-2xl font-semibold tracking-tight text-charcoal">إتمام الدفع</h1>
      <p className="mt-1 text-sm text-charcoal/55">اختر طريقة الدفع وأكمل العملية هنا. لا تُفعَّل الباقة إلا بعد تأكيد الدفع.</p>

      <div className="mt-6 grid gap-5 lg:grid-cols-[1fr_22rem]">
        {/* ---- XPay's form, inside Kayan --------------------------------------------------------------- */}
        <Card className="p-4 sm:p-7">
          <div className="mb-5 flex flex-wrap items-center justify-between gap-3 border-b border-borderSoft pb-5">
            <div>
              <p className="text-xs text-charcoal/45">المبلغ المطلوب الآن</p>
              <p className="num mt-1 text-3xl font-semibold tracking-tight text-charcoal">{egp(order.amount_total)}</p>
            </div>
            <span className="bg-sageSoft px-3 py-1.5 text-xs font-medium text-sage">{PURPOSE_LABEL[order.purpose]} — {pkgName}</span>
          </div>
          <InlinePayment publishableKey={publishableKey} clientSecret={clientSecret} orderId={order.id} testMode={testMode} backHref={backHref} />
        </Card>

        {/* ---- the order ------------------------------------------------------------------------------- */}
        <Card className="h-fit p-5 sm:p-6 lg:sticky lg:top-6">
          <h2 className="text-base font-semibold text-charcoal">ملخص الطلب</h2>
          <p className="mt-1 text-xs text-charcoal/45">{PURPOSE_LABEL[order.purpose]} — {pkgName} ({OPTION_LABEL[order.payment_option] ?? order.payment_option})</p>
          <ul className="mt-4 space-y-2.5 border-t border-borderSoft pt-4 text-sm">
            {lines ? lines.map((l) => <li key={l.id} className="flex items-start justify-between gap-3"><span className="text-charcoal/70">{l.label}</span><span className="num shrink-0 font-medium text-charcoal">{egp(l.amount)}</span></li>)
              : <li className="flex items-start justify-between gap-3"><span className="text-charcoal/70">{pkgName}</span><span className="num shrink-0 font-medium text-charcoal">{egp(order.amount_total)}</span></li>}
          </ul>
          <div className="mt-4 flex items-center justify-between border-t border-borderSoft pt-4"><span className="font-medium text-charcoal">الإجمالي المطلوب الآن</span><span className="num text-lg font-semibold text-charcoal">{egp(order.amount_total)}</span></div>
          {recurring && <p className="mt-3 text-xs leading-5 text-charcoal/50">{recurring.label}: {egp(recurring.amount)} شهريًا بعد ذلك، تدفعها بنفسك عند كل تجديد. لا يُسحب أي مبلغ تلقائيًا.</p>}
          <div className="mt-4 space-y-1 border-t border-borderSoft pt-4 text-xs text-charcoal/55">
            <p>الشركة: <span className="font-medium text-charcoal">{orgName}</span></p>
            <p dir="ltr" className="text-right">{email}</p>
            <p>رقم الطلب: <span className="num font-medium text-charcoal" dir="ltr">{orderRef(order.id)}</span></p>
          </div>
          <p className="mt-4 text-xs text-charcoal/55"><Link href={backHref} className="underline underline-offset-4">تعديل الطلب</Link></p>
        </Card>
      </div>
      <p className="mt-6 text-center text-xs text-charcoal/40"><Link href="/dashboard/billing" className="underline underline-offset-4">الباقة والمدفوعات</Link></p>
    </div>
  );
}

/** 1 review → 2 pay → 3 confirmation */
function Steps() {
  const steps = [{ label: "مراجعة الطلب", state: "done" }, { label: "الدفع", state: "current" }, { label: "التأكيد", state: "todo" }] as const;
  return (
    <ol className="mb-6 flex items-center gap-2 text-xs sm:gap-3" aria-label="خطوات الطلب">
      {steps.map((s, i) => (
        <li key={s.label} className="flex items-center gap-2 sm:gap-3" aria-current={s.state === "current" ? "step" : undefined}>
          <span className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-[0.6875rem] font-medium tabular-nums ${s.state === "done" ? "bg-sage text-ivory" : s.state === "current" ? "border border-sage text-sage" : "border border-borderSoft text-charcoal/40"}`}>
            {s.state === "done" ? <Check size={13} strokeWidth={2.4} /> : i + 1}
          </span>
          <span className={s.state === "current" ? "font-medium text-charcoal" : s.state === "done" ? "text-charcoal/60" : "text-charcoal/40"}>{s.label}</span>
          {i < steps.length - 1 && <span aria-hidden className="h-px w-6 bg-borderSoft sm:w-10" />}
        </li>
      ))}
    </ol>
  );
}
