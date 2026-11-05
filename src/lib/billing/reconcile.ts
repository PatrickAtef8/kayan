// The ONE place that decides, from what XPay says, what happens to an order. Used by the webhook and by the page the
// customer returns to, so both reach the same verdict. It never reads a payment status from the browser or from the
// webhook body: it asks XPay for the session (server to server, with the secret key) and acts on THAT answer.
import type { XpayApi, XpaySession } from "./xpay-client.ts";

export type OrderRef = { id: string; status: string; xpay_session_id: string | null };
export type ApplyResultCode = "applied" | "already_applied" | "not_found" | "session_mismatch" | "amount_mismatch";

export interface BillingStore {
  beginWebhookEvent(eventId: string, type: string, sessionId: string | null): Promise<boolean>;
  finishWebhookEvent(eventId: string, outcome: string): Promise<void>;
  findOrderBySession(sessionId: string): Promise<OrderRef | null>;
  findOrderById(orderId: string): Promise<OrderRef | null>;
  applyPayment(a: { orderId: string; sessionId: string; paymentIntentId: string | null; amount: number; currency: string }): Promise<ApplyResultCode>;
  markOrder(orderId: string, status: "failed" | "expired" | "canceled", reason: string): Promise<boolean>;
}

export type Deps = {
  store: BillingStore;
  xpay: Pick<XpayApi, "getCheckoutSession">;
  log?: (msg: string, meta?: Record<string, unknown>) => void;
  /** Called after a payment was recorded ("applied") or parked for a human ("amount_mismatch"). Failures here never change the verdict. */
  onPaymentRecorded?: (orderId: string, result: "applied" | "amount_mismatch") => Promise<void>;
};

export type Outcome =
  | "applied" | "already_applied" | "awaiting_payment" | "session_open" | "expired" | "failed_marked"
  | "unknown_order" | "session_mismatch" | "amount_mismatch" | "not_paid" | "already_closed";

/** Finds the order a session belongs to: by the session id we stored, or (before it was stored) by our own metadata. */
async function locate(session: XpaySession, store: BillingStore): Promise<OrderRef | null> {
  const bySession = await store.findOrderBySession(session.id);
  if (bySession) return bySession;
  const hinted = session.metadata.order_id;
  if (hinted && /^[0-9a-f-]{36}$/i.test(hinted)) {
    const byId = await store.findOrderById(hinted);
    if (byId && (byId.xpay_session_id === null || byId.xpay_session_id === session.id)) return byId;
  }
  return null;
}

/** Reads the session at XPay and brings the order in line with it. Throws only for transient failures (retry later). */
export async function reconcileSession(sessionId: string, deps: Deps, hint?: { failedEvent?: boolean }): Promise<Outcome> {
  const session = await deps.xpay.getCheckoutSession(sessionId);   // throws → the caller answers 5xx / shows "checking"
  const order = await locate(session, deps.store);
  if (!order) {
    deps.log?.("billing: session without an order", { session: session.id });
    return "unknown_order";
  }

  if (session.status === "complete" && session.paymentStatus === "paid") {
    const r = await deps.store.applyPayment({
      orderId: order.id, sessionId: session.id, paymentIntentId: session.paymentIntentId,
      amount: session.amountTotal, currency: session.currency,
    });
    if (r === "amount_mismatch" || r === "session_mismatch" || r === "not_found") {
      deps.log?.("billing: a payment needs a human", { order: order.id, session: session.id, result: r });
    }
    if (r === "applied" || r === "amount_mismatch") {
      try { await deps.onPaymentRecorded?.(order.id, r); } catch (e) { deps.log?.("billing: payment notification failed", { order: order.id, error: e instanceof Error ? e.message : "unknown" }); }
    }
    return r === "not_found" ? "unknown_order" : r;
  }

  if (order.status === "paid") return "already_applied";
  if (session.paymentStatus === "no_payment_required") return "not_paid";

  if (session.status === "complete") {
    // XPay finished the checkout but no money yet (a Fawry reference waiting to be paid). The order stays open.
    if (hint?.failedEvent) {
      await deps.store.markOrder(order.id, "failed", "async_payment_failed");
      return "failed_marked";
    }
    return "awaiting_payment";
  }
  if (session.status === "expired") {
    const closed = await deps.store.markOrder(order.id, "expired", "session_expired");
    return closed ? "expired" : "already_closed";
  }
  return "session_open";
}

// ---------------------------------------------------------------------------------------------------------------
// Webhook events
// ---------------------------------------------------------------------------------------------------------------
export type XpayEvent = { id?: unknown; type?: unknown; data?: { object?: { id?: unknown } } };
export type HandlerResult = { status: 200 | 400 | 500; outcome: string };

const SESSION_EVENTS = new Set([
  "checkout.session.completed",
  "checkout.session.async_payment_succeeded",
  "checkout.session.async_payment_failed",
  "checkout.session.expired",
]);

export const isHandledEventType = (t: unknown): boolean => typeof t === "string" && SESSION_EVENTS.has(t);

/**
 * Handles one verified webhook delivery. Contract with XPay's retry schedule (non-2xx / timeout → retried up to 5 times):
 *   200  processed, duplicate, ignored, or needs a human (a retry would not help — it is logged and flagged in the DB)
 *   400  the payload is not an event we can read
 *   500  a transient failure (XPay or the database could not be reached): XPay will deliver it again, and because the
 *        event is only marked finished AFTER success, the retry is processed instead of skipped
 */
export async function handleXpayEvent(event: XpayEvent, deps: Deps): Promise<HandlerResult> {
  if (typeof event.id !== "string" || !event.id || typeof event.type !== "string") return { status: 400, outcome: "invalid_event" };
  if (!SESSION_EVENTS.has(event.type)) return { status: 200, outcome: "ignored_type" };
  const sessionId = event.data?.object?.id;
  if (typeof sessionId !== "string") return { status: 400, outcome: "invalid_event" };

  try {
    const fresh = await deps.store.beginWebhookEvent(event.id, event.type, sessionId);
    if (!fresh) return { status: 200, outcome: "duplicate" };
    const outcome = await reconcileSession(sessionId, deps, { failedEvent: event.type === "checkout.session.async_payment_failed" });
    await deps.store.finishWebhookEvent(event.id, outcome);
    return { status: 200, outcome };
  } catch (e) {
    deps.log?.("billing: webhook handling failed, XPay will retry", { event: event.id, error: e instanceof Error ? e.message : String(e) });
    return { status: 500, outcome: "retry_later" };
  }
}
