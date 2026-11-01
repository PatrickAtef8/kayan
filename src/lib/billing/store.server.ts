import "server-only";
import { createAdminClient } from "@/lib/supabase/admin";
import type { ApplyResultCode, BillingStore, OrderRef } from "./reconcile.ts";

// The BillingStore backed by the database. Every call goes through the service role and the billing_* SQL functions of
// migration 0060, which are executable by that role alone. By the time anything here runs, the server has already
// verified WHO is asking (a signed-in owner) or WHAT is asking (an XPay-signed webhook) — see actions.ts / the route.

const ORDER_COLUMNS = "id, status, xpay_session_id";

export function createSupabaseBillingStore(admin = createAdminClient()): BillingStore {
  const orderRef = (row: unknown): OrderRef | null => (row ? (row as OrderRef) : null);
  return {
    async beginWebhookEvent(eventId, type, sessionId) {
      const { data, error } = await admin.rpc("billing_begin_webhook_event", { p_event_id: eventId, p_type: type, p_session: sessionId });
      if (error) throw new Error(`billing_begin_webhook_event: ${error.message}`);
      return data === true;
    },
    async finishWebhookEvent(eventId, outcome) {
      const { error } = await admin.rpc("billing_finish_webhook_event", { p_event_id: eventId, p_outcome: outcome });
      if (error) throw new Error(`billing_finish_webhook_event: ${error.message}`);
    },
    async findOrderBySession(sessionId) {
      const { data, error } = await admin.from("billing_orders").select(ORDER_COLUMNS).eq("xpay_session_id", sessionId).maybeSingle();
      if (error) throw new Error(`find order by session: ${error.message}`);
      return orderRef(data);
    },
    async findOrderById(orderId) {
      const { data, error } = await admin.from("billing_orders").select(ORDER_COLUMNS).eq("id", orderId).maybeSingle();
      if (error) throw new Error(`find order: ${error.message}`);
      return orderRef(data);
    },
    async applyPayment(a) {
      const { data, error } = await admin.rpc("billing_apply_payment", {
        p_order: a.orderId, p_session: a.sessionId, p_payment_intent: a.paymentIntentId, p_amount: a.amount, p_currency: a.currency,
      });
      if (error) throw new Error(`billing_apply_payment: ${error.message}`);
      return ((data as { result?: string } | null)?.result ?? "not_found") as ApplyResultCode;
    },
    async markOrder(orderId, status, reason) {
      const { data, error } = await admin.rpc("billing_mark_order", { p_order: orderId, p_status: status, p_reason: reason });
      if (error) throw new Error(`billing_mark_order: ${error.message}`);
      return data === true;
    },
  };
}
