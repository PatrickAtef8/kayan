import Link from "next/link";
import { redirect } from "next/navigation";
import { Clock3, TriangleAlert } from "lucide-react";
import { AutoRefresh } from "@/components/pricing/auto-refresh";
import { OrderNotFound, ResultShell, linkPrimary, linkSecondary, orderRef } from "@/components/pricing/result-shell";
import { getCheckoutContext } from "@/lib/billing/checkout-context.server";
import { loadAndVerifyOrder } from "@/lib/billing/order-view.server";
import { canRetry, UUID_RE } from "@/lib/billing/checkout-state";
import { PRICING_CONFIG } from "@/config/pricing.config";

// Where XPay sends the customer when the payment did not complete (declined card, failed 3-D Secure, or the customer left XPay's
// page). Reaching this URL does not mean "failed": the order is re-checked with XPay first, and the wording follows what is TRUE —
// paid (sent to the success page), still confirming, left unfinished (nothing charged, can be resumed), failed, canceled or expired.
// Nothing here ever activates or unlocks anything.
export default async function CheckoutFailPage({ searchParams }: { searchParams: Promise<{ order?: string }> }) {
  const sp = await searchParams;
  const ctx = await getCheckoutContext();
  if (!ctx.orgId || ctx.roleKey !== "owner" || !sp.order || !UUID_RE.test(sp.order)) return <OrderNotFound />;
  const r = await loadAndVerifyOrder(sp.order, ctx.orgId, "fail");
  if (!r) return <OrderNotFound />;
  const { order, view } = r;
  if (view === "paid") redirect(`/checkout/success?order=${order.id}`);
  const support = PRICING_CONFIG.legal.supportUrl;
  const ref = <p className="mt-3 text-xs text-charcoal/45">رقم الطلب: <span className="num" dir="ltr">{orderRef(order.id)}</span></p>;

  if (view === "confirming") {
    return (
      <ResultShell icon={<Clock3 size={26} />} tone="wait" title="جارٍ التحقق من الدفع">
        <AutoRefresh />
        <p className="text-sm leading-7 text-charcoal/60">لم نتلقَّ تأكيدًا نهائيًا بعد. إن كنت دفعت للتو فسيُفعَّل حسابك تلقائيًا فور وصول التأكيد؛ <span className="font-medium text-charcoal">لا تُعِد الدفع</span> الآن. لن يُفتح لك النظام قبل التأكيد.</p>
        {ref}
        <div className="mt-6 flex flex-wrap gap-3"><Link href={`/checkout/fail?order=${order.id}`} className={linkPrimary}>تحقق الآن</Link><Link href="/dashboard/billing" className={linkSecondary}>الباقة والمدفوعات</Link></div>
      </ResultShell>
    );
  }

  const copy = {
    incomplete: { title: "لم تكتمل عملية الدفع", body: "غادرت صفحة الدفع قبل إتمام العملية. لم يُخصم أي مبلغ ولم تُفعَّل الباقة. يمكنك استكمال الدفع من حيث توقفت.", cta: "استكمل الدفع" },
    failed: { title: "فشلت عملية الدفع", body: "رفضت الجهة المصدرة للبطاقة العملية أو تعذّر التحقق منها. لم تُفعَّل الباقة. جرّب بطاقة أو وسيلة دفع أخرى. إن كنت متأكدًا من خصم المبلغ فسنفعّل الباقة تلقائيًا فور وصول التأكيد.", cta: "حاول مرة أخرى" },
    canceled: { title: "أُلغيت عملية الدفع", body: "أُغلق هذا الطلب قبل اكتمال الدفع، ولم تُفعَّل الباقة. يمكنك بدء عملية دفع جديدة.", cta: "ابدأ الدفع من جديد" },
    expired: { title: "انتهت صلاحية صفحة الدفع", body: "انتهت مهلة صفحة الدفع ولم يُخصم أي مبلغ. يمكنك بدء عملية دفع جديدة.", cta: "ابدأ الدفع من جديد" },
  }[view as "incomplete" | "failed" | "canceled" | "expired"];

  return (
    <ResultShell icon={<TriangleAlert size={26} />} tone="bad" title={copy.title}>
      <p className="text-sm leading-7 text-charcoal/60">{copy.body}</p>
      {ref}
      <div className="mt-6 flex flex-wrap items-start gap-3">
        {canRetry(view) && <Link href={order.purpose === "renewal" ? "/checkout?renew=1" : `/checkout?package=${encodeURIComponent(order.package_key)}&option=${encodeURIComponent(order.payment_option)}`} className={linkPrimary}>{copy.cta}</Link>}
        <Link href="/dashboard/billing" className={linkSecondary}>العودة إلى الباقات</Link>
        {support && <a href={support} className={linkSecondary}>تواصل مع الدعم</a>}
      </div>
    </ResultShell>
  );
}
