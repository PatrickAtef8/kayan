import { test } from "node:test";
import assert from "node:assert/strict";
import { eventLabel, eventStatus, pulseHealth, relativeAr, summarize, type WebhookRow } from "./webhook-activity.ts";
import { isAttentionEventType, isHandledEventType, recordAttentionEvent, type BillingStore } from "./reconcile.ts";

const NOW = Date.parse("2026-11-17T12:00:00Z");
const ago = (ms: number) => new Date(NOW - ms).toISOString();
const MIN = 60_000, HOUR = 3_600_000, DAY = 86_400_000;
const row = (over: Partial<WebhookRow>): WebhookRow => ({ event_type: "checkout.session.completed", outcome: "applied", received_at: ago(MIN), processed_at: ago(MIN - 500), ...over });

test("event types get Arabic labels; refunds, disputes and holds are recognised by prefix; unknown types are shown as-is", () => {
  assert.equal(eventLabel("checkout.session.completed"), "اكتمل الدفع");
  assert.equal(eventLabel("refund.created"), "استرداد");
  assert.equal(eventLabel("charge.refunded"), "استرداد");
  assert.equal(eventLabel("payment.hold_released"), "حجز مخاطر على دفعة");
  assert.equal(eventLabel("something.new"), "something.new");
});

test("an event without an outcome is «processing», then «stuck» after ten minutes", () => {
  assert.equal(eventStatus({ outcome: null, processed_at: null, received_at: ago(2 * MIN) }, NOW).tone, "wait");
  assert.equal(eventStatus({ outcome: null, processed_at: null, received_at: ago(11 * MIN) }, NOW).tone, "attention");
  assert.equal(eventStatus({ outcome: "applied", processed_at: ago(MIN), received_at: ago(MIN) }, NOW).tone, "ok");
  assert.equal(eventStatus({ outcome: "amount_mismatch", processed_at: ago(MIN), received_at: ago(MIN) }, NOW).tone, "attention");
  assert.equal(eventStatus({ outcome: "failed_marked", processed_at: ago(MIN), received_at: ago(MIN) }, NOW).tone, "bad");
});

test("summarize counts only the last seven days and flags what needs a human", () => {
  const rows: WebhookRow[] = [
    row({}),
    row({ received_at: ago(3 * HOUR), processed_at: ago(3 * HOUR) }),
    row({ outcome: "awaiting_payment" }),
    row({ outcome: "failed_marked" }),
    row({ outcome: "expired" }),
    row({ outcome: "amount_mismatch" }),
    row({ event_type: "refund.created", outcome: "needs_attention" }),
    row({ received_at: ago(8 * DAY), processed_at: ago(8 * DAY) }),   // older than a week: ignored
  ];
  const s = summarize(rows, NOW);
  assert.equal(s.total, 7);
  assert.equal(s.paid, 2);
  assert.equal(s.awaiting, 1);
  assert.equal(s.failed, 2);
  assert.equal(s.attention, 2);
  assert.equal(s.days.length, 7);
  assert.equal(s.days.reduce((n, d) => n + d.paid, 0), 2);
  assert.equal(s.lastReceivedAt, ago(MIN));
});

test("health: idle without any event, attention when something needs a human, ok otherwise", () => {
  assert.equal(pulseHealth(false, summarize([], NOW)), "idle");
  assert.equal(pulseHealth(true, summarize([row({})], NOW)), "ok");
  assert.equal(pulseHealth(true, summarize([row({ outcome: "unknown_order" })], NOW)), "attention");
  assert.equal(pulseHealth(true, summarize([row({ outcome: null, processed_at: null, received_at: ago(30 * MIN) })], NOW)), "attention");
});

test("relative time uses correct Arabic number agreement", () => {
  assert.equal(relativeAr(ago(10_000), NOW), "الآن");
  assert.equal(relativeAr(ago(MIN), NOW), "منذ دقيقة");
  assert.equal(relativeAr(ago(2 * MIN), NOW), "منذ دقيقتين");
  assert.equal(relativeAr(ago(5 * MIN), NOW), "منذ 5 دقائق");
  assert.equal(relativeAr(ago(15 * MIN), NOW), "منذ 15 دقيقة");
  assert.equal(relativeAr(ago(HOUR), NOW), "منذ ساعة");
  assert.equal(relativeAr(ago(2 * HOUR), NOW), "منذ ساعتين");
  assert.equal(relativeAr(ago(5 * HOUR), NOW), "منذ 5 ساعات");
  assert.equal(relativeAr(ago(DAY), NOW), "منذ يوم");
  assert.equal(relativeAr(ago(3 * DAY), NOW), "منذ 3 أيام");
  assert.equal(relativeAr(ago(12 * DAY), NOW), "منذ 12 يومًا");
  assert.equal(relativeAr(new Date(NOW + 5 * MIN).toISOString(), NOW), "الآن");
});

// ------------------------------------------------------------- refund / dispute / hold events are recorded, never acted on
function fakeStore(opts: { fresh?: boolean; failOn?: "begin" | "finish" } = {}) {
  const calls: string[] = [];
  const store: BillingStore = {
    async beginWebhookEvent(id, type, session) { calls.push(`begin:${id}:${type}:${session}`); if (opts.failOn === "begin") throw new Error("db down"); return opts.fresh ?? true; },
    async finishWebhookEvent(id, outcome) { calls.push(`finish:${id}:${outcome}`); if (opts.failOn === "finish") throw new Error("db down"); },
    async findOrderBySession() { calls.push("findOrderBySession"); return null; },
    async findOrderById() { calls.push("findOrderById"); return null; },
    async applyPayment() { calls.push("applyPayment"); return "applied"; },
    async markOrder() { calls.push("markOrder"); return true; },
  };
  return { store, calls };
}

test("which event types are recorded, which are acted on, and which are ignored", () => {
  for (const t of ["refund.created", "refund.failed", "charge.refunded", "charge.dispute.created", "payment.held", "payment.hold_released", "payment.hold_captured", "payment.hold_expired"]) assert.equal(isAttentionEventType(t), true, t);
  for (const t of ["customer.created", "price.updated", "charge.succeeded", "payment_intent.succeeded", "checkout.session.completed", undefined, 5]) assert.equal(isAttentionEventType(t), false, String(t));
  assert.equal(isHandledEventType("refund.created"), false);   // a refund never reaches the code that grants access
});

test("a refund event is recorded once, with no session, and touches no order", async () => {
  const { store, calls } = fakeStore();
  const r = await recordAttentionEvent({ id: "evt_1", type: "refund.created", data: { object: { id: "re_1" } } }, { store });
  assert.deepEqual(r, { status: 200, outcome: "needs_attention" });
  assert.deepEqual(calls, ["begin:evt_1:refund.created:null", "finish:evt_1:needs_attention"]);   // no order lookup, no payment, no mark
});

test("a redelivered refund event is a duplicate (200, nothing else happens)", async () => {
  const { store, calls } = fakeStore({ fresh: false });
  assert.deepEqual(await recordAttentionEvent({ id: "evt_1", type: "charge.refunded" }, { store }), { status: 200, outcome: "duplicate" });
  assert.deepEqual(calls, ["begin:evt_1:charge.refunded:null"]);
});

test("unreadable or unrelated events are refused or ignored without touching the database", async () => {
  const { store, calls } = fakeStore();
  assert.equal((await recordAttentionEvent({ type: "refund.created" }, { store })).status, 400);
  assert.equal((await recordAttentionEvent({ id: "e", type: 5 }, { store })).status, 400);
  assert.deepEqual(await recordAttentionEvent({ id: "e", type: "customer.created" }, { store }), { status: 200, outcome: "ignored_type" });
  assert.deepEqual(calls, []);
});

test("a database failure while recording answers 500 so XPay retries", async () => {
  for (const failOn of ["begin", "finish"] as const) {
    const { store } = fakeStore({ failOn });
    const logs: string[] = [];
    assert.deepEqual(await recordAttentionEvent({ id: "evt_2", type: "refund.failed" }, { store, log: (m) => logs.push(m) }), { status: 500, outcome: "retry_later" });
    assert.equal(logs.length, 1);
  }
});
