// What the customer is told about an order. Pure, so the success page, the failure page and the tests share one mapping.
//
// XPay tells us three things about a session: its status (open / complete / expired), its payment status (unpaid / paid), and — through
// WHICH of our two return URLs the browser lands on — only how the customer LEFT its page. Neither return URL proves anything, so the
// state shown comes from the order row after a server-to-server check, and a cancel return is not reported as a failure:
//
//   paid        verified by XPay and applied (the subscription is active)
//   confirming  the payment may still arrive (bank / Fawry confirmation, or XPay could not be reached right now)
//   incomplete  the customer left XPay's page and the session is still open: nothing was charged, it can be resumed
//   failed      XPay reported the payment failed
//   canceled    the order was closed as canceled
//   expired     XPay's payment page expired
import type { Outcome } from "./reconcile.ts";

export type CheckoutView = "paid" | "confirming" | "incomplete" | "failed" | "canceled" | "expired";

export function checkoutView(input: {
  status: string;                       // billing_orders.status
  returnedAs: "success" | "fail";       // which of our two URLs the browser came back to
  checking: boolean;                    // true when XPay could not be reached for the verification
  outcome: Outcome | null;              // what the verification found (null when it was not needed / not possible)
}): CheckoutView {
  switch (input.status) {
    case "paid": return "paid";
    case "failed": return "failed";
    case "canceled": return "canceled";
    case "expired": return "expired";
  }
  // pending
  if (input.checking) return "confirming";
  if (input.outcome === "awaiting_payment") return "confirming";
  if (input.returnedAs === "success") return "confirming";
  return "incomplete";
}

/** May the customer start the payment again for this order's package? (never while a payment may still arrive, never after it was paid) */
export const canRetry = (v: CheckoutView) => v === "incomplete" || v === "failed" || v === "canceled" || v === "expired";

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
