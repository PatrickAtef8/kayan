import Link from "next/link";
import { redirect } from "next/navigation";
import { Lock } from "lucide-react";
import { OrderNotFound, ResultShell, linkPrimary, linkSecondary } from "@/components/pricing/result-shell";
import { getCheckoutContext } from "@/lib/billing/checkout-context.server";
import { UUID_RE } from "@/lib/billing/checkout-state";
import { loadPricingConfig } from "@/lib/billing/config";
import { buildQuote, getPackage, type Quote } from "@/lib/billing/pricing";
import { embeddedCheckoutStatus, getXpay, xpayIsTestMode } from "@/lib/billing/xpay.server";
import { getSupabase } from "@/lib/org-context";
import { PayView } from "./pay-view";

type PayOrder = { id: string; status: string; package_key: string; payment_option: string; purpose: "initial" | "renewal"; amount_total: number; xpay_session_id: string | null; checkout_url: string | null };

// Step 2 of 3 — Kayan's own payment page. Step 1 is /checkout (review + accept the terms), step 3 is /checkout/success. XPay's form is embedded here.
// Nothing on this page is a source of truth for money: the amount is the order's (created and priced on the server), the session is read back from
// XPay, and a payment counts only when the webhook / the result page's server-to-server check says so.
export default async function CheckoutPayPage({ searchParams }: { searchParams: Promise<{ order?: string }> }) {
  const sp = await searchParams;
  const ctx = await getCheckoutContext();
  if (!ctx.orgId || ctx.roleKey !== "owner" || !sp.order || !UUID_RE.test(sp.order)) return <OrderNotFound />;

  const supabase = await getSupabase();
  const [{ data }, { config: cfg }] = await Promise.all([
    supabase.from("billing_orders").select("id, status, package_key, payment_option, purpose, amount_total, xpay_session_id, checkout_url").eq("id", sp.order).eq("organization_id", ctx.orgId).maybeSingle(),
    loadPricingConfig(supabase),
  ]);
  const order = data as PayOrder | null;
  if (!order) return <OrderNotFound />;

  const result = `/checkout/success?order=${order.id}`;
  if (order.status !== "pending") redirect(result);                    // paid / failed / expired: the result page tells the customer which
  if (order.checkout_url) redirect(order.checkout_url);                // a session made for XPay's own page: continue there

  const embedded = embeddedCheckoutStatus();
  if (!embedded.enabled || !order.xpay_session_id) return <Unavailable />;
  let session;
  try { session = await getXpay().getCheckoutSession(order.xpay_session_id); } catch (e) { console.error("checkout/pay: could not read the session —", e instanceof Error ? e.message : e); return <Unavailable />; }
  if (session.status !== "open") redirect(result);                     // already paid, or expired: the result page checks with XPay and routes it
  if (!session.clientSecret) return <Unavailable />;

  const renewal = order.purpose === "renewal";
  const pkgName = getPackage(order.payment_option, cfg)?.name ?? getPackage(order.package_key, cfg)?.name ?? order.package_key;
  // the lines are only shown when they add up to exactly what this order charges
  let quote: Quote | null = null;
  try { const q = buildQuote({ plan: order.payment_option, purpose: order.purpose }, cfg); if (q.dueToday === order.amount_total) quote = q; } catch { /* the total alone is enough */ }
  const backHref = renewal ? "/checkout?renew=1" : `/checkout?plan=${encodeURIComponent(order.payment_option)}`;

  return (
    <PayView
      order={order} pkgName={pkgName} lines={quote ? quote.lines : null} recurring={quote?.recurring ?? null}
      orgName={ctx.access?.orgName ?? "—"} email={ctx.user.email ?? ""}
      publishableKey={embedded.publishableKey} clientSecret={session.clientSecret} testMode={xpayIsTestMode()} backHref={backHref}
    />
  );
}

function Unavailable() {
  return (
    <ResultShell icon={<Lock size={22} />} tone="wait" title="نموذج الدفع غير متاح الآن">
      <p className="text-sm leading-7 text-charcoal/60">تعذّر تجهيز صفحة الدفع. لم يُخصم أي مبلغ. حاول مرة أخرى بعد قليل، وإن تكرّر ذلك فتواصل مع فريق كيان.</p>
      <div className="mt-6 flex flex-wrap gap-3"><Link href="/checkout" className={linkPrimary}>العودة إلى الطلب</Link><Link href="/dashboard/billing" className={linkSecondary}>الباقة والمدفوعات</Link></div>
    </ResultShell>
  );
}
