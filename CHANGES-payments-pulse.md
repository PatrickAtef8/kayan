# نبض المدفوعات — Payments pulse (admin) + refund / hold awareness

No database migration. Nothing here grants or revokes access.

* `src/components/admin/payments-pulse.tsx` — new Super Admin card on the overview page: live/test badge, a pulsing dot (grey = no signal yet,
  green = healthy, amber = something needs you), last signal time, 7-day counters (confirmed / waiting for the customer / failed or expired /
  needs attention), a 7-day bar chart of confirmed payments, the last 8 deliveries with an Arabic status chip, and a collapsible setup helper
  (endpoint URL + the 4 events), open by default until the first event arrives.
* `src/lib/billing/webhook-activity.ts` (+ `.server.ts`, `.test.ts`) — pure labels / counters / Arabic relative time, and the read of `billing_webhook_events`.
* `src/lib/billing/reconcile.ts` + `src/app/api/webhooks/xpay/route.ts` — refund, dispute and risk-hold events are now RECORDED (outcome `needs_attention`)
  instead of dropped, so they appear flagged in the panel. Matched by prefix (`refund.*`, `charge.refunded`, `charge.dispute*`, `payment.held|hold*`).
  Everything else stays acknowledged and ignored. Duplicates and transient DB failures follow the same 200 / 500 contract as the checkout events.
* `docs/BILLING.md` — which events to subscribe to, and a "Going live" checklist (test keys → live keys).
* `package.json` — the new test file is part of `npm run test:billing`.
