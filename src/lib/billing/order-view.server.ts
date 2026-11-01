import "server-only";
import { getSupabase } from "@/lib/org-context";
import { reconcileSession, type Outcome } from "./reconcile";
import { createSupabaseBillingStore } from "./store.server";
import { getXpay } from "./xpay.server";
import { checkoutView, type CheckoutView } from "./checkout-state";
import { rateLimit, RATE_POLICIES } from "@/lib/rate-limit.server";

export type OrderRow = {
  id: string; status: string; package_key: string; payment_option: string; purpose: string; amount_total: number;
  period_end: string | null; paid_at: string | null; xpay_session_id: string | null; needs_review: boolean; failure_reason: string | null;
};
const COLS = "id, status, package_key, payment_option, purpose, amount_total, period_end, paid_at, xpay_session_id, needs_review, failure_reason";

/**
 * Loads one of the caller's OWN company's orders (row level security + an explicit organization filter: another company's order id
 * simply is not found) and, while it is still pending, asks XPay — server to server — what really happened, letting the same
 * idempotent routine the webhook uses apply it. A paid session activates here at most once, however often this page is opened.
 * The URL the browser came back on (success / fail) is only a hint for the wording, never proof of payment.
 */
export async function loadAndVerifyOrder(orderId: string, organizationId: string, returnedAs: "success" | "fail"): Promise<{ order: OrderRow; view: CheckoutView; checking: boolean; outcome: Outcome | null } | null> {
  const supabase = await getSupabase();
  const load = async () => (await supabase.from("billing_orders").select(COLS).eq("id", orderId).eq("organization_id", organizationId).maybeSingle()).data as OrderRow | null;
  let order = await load();
  if (!order) return null;
  let checking = false;
  let outcome: Outcome | null = null;
  if (order.status === "pending" && order.xpay_session_id) {
    // Opening / polling this page asks XPay each time: past the cap we stop asking and keep showing "verifying" (never "failed").
    const limit = await rateLimit(RATE_POLICIES.checkoutVerify, organizationId);
    if (!limit.allowed) return { order, view: checkoutView({ status: order.status, returnedAs, checking: true, outcome: null }), checking: true, outcome: null };
    try {
      outcome = await reconcileSession(order.xpay_session_id, { store: createSupabaseBillingStore(), xpay: getXpay(), log: (m, meta) => console.error(m, meta ?? {}) });
      order = (await load()) ?? order;
    } catch (e) {
      console.error("checkout: could not verify with XPay yet —", e instanceof Error ? e.message : e);
      checking = true;               // never tell the customer it failed because WE could not reach XPay
    }
  }
  return { order, view: checkoutView({ status: order.status, returnedAs, checking, outcome }), checking, outcome };
}
