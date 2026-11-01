import Link from "next/link";
import { redirect } from "next/navigation";
import { CircleCheck, Clock3 } from "lucide-react";
import { AutoRefresh } from "@/components/pricing/auto-refresh";
import { OrderNotFound, ResultShell, linkPrimary, linkSecondary, orderRef } from "@/components/pricing/result-shell";
import { getCheckoutContext } from "@/lib/billing/checkout-context.server";
import { loadAndVerifyOrder } from "@/lib/billing/order-view.server";
import { UUID_RE } from "@/lib/billing/checkout-state";
import { getPackage, type PricingConfig } from "@/lib/billing/pricing";
import { PRICING_CONFIG } from "@/config/pricing.config";
import { OPTION_LABEL, PURPOSE_LABEL } from "@/lib/billing/labels";
import { formatMoney } from "@/lib/money";

const cfg = PRICING_CONFIG as PricingConfig;
const date = (iso: string | null) => (iso ? new Intl.DateTimeFormat("ar-EG", { dateStyle: "long" }).format(new Date(iso)) : "—");

// Where XPay sends the customer after a completed checkout. This page is a courtesy, NOT the proof of payment: the customer may
// arrive before the payment is confirmed, or never arrive (the webhook activates the subscription either way). It
//   • shows only the caller's own company's order (a foreign order id is "not found"),
//   • asks XPay server to server what really happened and lets the same idempotent routine the webhook uses apply it,
//   • then tells the truth: confirmed / still confirming — and sends anything else to the failure page.
// A "success" parameter in the URL, or the mere fact of reaching this page, activates nothing.
export default async function CheckoutSuccessPage({ searchParams }: { searchParams: Promise<{ order?: string }> }) {
  const sp = await searchParams;
  const ctx = await getCheckoutContext();
  if (!ctx.orgId || ctx.roleKey !== "owner" || !sp.order || !UUID_RE.test(sp.order)) return <OrderNotFound />;
  const r = await loadAndVerifyOrder(sp.order, ctx.orgId, "success");
  if (!r) return <OrderNotFound />;
  const { order, view } = r;
  if (view !== "paid" && view !== "confirming") redirect(`/checkout/fail?order=${order.id}`);

  const pkgName = getPackage(order.package_key, cfg)?.name ?? order.package_key;
  const what = `${PURPOSE_LABEL[order.purpose]} — ${pkgName} (${OPTION_LABEL[order.payment_option]})`;
  const amount = `${formatMoney(order.amount_total / 100, order.amount_total % 100 === 0 ? 0 : 2)} ج.م`;

  if (view === "paid") {
    return (
      <ResultShell icon={<CircleCheck size={26} />} tone="ok" title={order.purpose === "renewal" ? "تم التجديد بنجاح" : "تم الدفع وتفعيل باقتك"}>
        <p className="text-sm leading-7 text-charcoal/60">{what} — <span className="num font-medium text-charcoal">{amount}</span></p>
        <dl className="mt-4 space-y-1.5 text-sm">
          <div className="flex justify-between gap-3"><dt className="text-charcoal/45">رقم الطلب</dt><dd className="num font-medium text-charcoal" dir="ltr">{orderRef(order.id)}</dd></div>
          {order.paid_at && <div className="flex justify-between gap-3"><dt className="text-charcoal/45">تاريخ الدفع</dt><dd className="font-medium text-charcoal">{date(order.paid_at)}</dd></div>}
          {order.period_end && <div className="flex justify-between gap-3"><dt className="text-charcoal/45">الخدمة مدفوعة حتى</dt><dd className="font-medium text-charcoal">{date(order.period_end)}</dd></div>}
        </dl>
        {order.needs_review && <p className="mt-4 bg-amber-50 p-3 text-sm text-amber-800">سجّلنا هذه الدفعة وسيراجعها فريق كيان لأنها تحتاج تأكيدًا إضافيًا. لن يضيع منها شيء.</p>}
        <div className="mt-6 flex flex-wrap gap-3"><Link href="/dashboard" className={linkPrimary}>اذهب إلى لوحة التحكم</Link><Link href="/dashboard/billing" className={linkSecondary}>الباقة والمدفوعات</Link></div>
      </ResultShell>
    );
  }
  return (
    <ResultShell icon={<Clock3 size={26} />} tone="wait" title="جارٍ تأكيد الدفع">
      <AutoRefresh />
      <p className="text-sm leading-7 text-charcoal/60">{what} — <span className="num font-medium text-charcoal">{amount}</span></p>
      <p className="mt-2 text-sm leading-7 text-charcoal/60">لا تُعِد الدفع. قد يستغرق تأكيد البنك أو فوري بضع لحظات{r.checking ? "، ولم نتمكن من الاتصال ببوابة الدفع للتحقق الآن" : ""}. ستتحدث هذه الصفحة تلقائيًا، وتُفعَّل الباقة فور التأكيد حتى لو أغلقتها. لن يُفتح لك النظام قبل ذلك.</p>
      <p className="mt-2 text-xs text-charcoal/45">رقم الطلب: <span className="num" dir="ltr">{orderRef(order.id)}</span></p>
      <div className="mt-6 flex flex-wrap gap-3"><Link href={`/checkout/success?order=${order.id}`} className={linkPrimary}>تحقق الآن</Link><Link href="/dashboard/billing" className={linkSecondary}>الباقة والمدفوعات</Link></div>
    </ResultShell>
  );
}
