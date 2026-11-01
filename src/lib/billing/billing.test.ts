import { test } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { PRICING_CONFIG } from "../../config/pricing.config.ts";
import { buildQuote, validatePricingConfig, toPiasters, describeFitViolations, type PricingConfig } from "./pricing.ts";
import { evaluateAccess, daysUntil } from "./license-status.ts";
import { verifyWebhookSignature } from "./webhook-signature.ts";
import { buildCheckoutSessionBody, createXpayClient, parseSession, XpayError } from "./xpay-client.ts";
import { handleXpayEvent, reconcileSession, type BillingStore, type OrderRef, type ApplyResultCode } from "./reconcile.ts";

const cfg = PRICING_CONFIG as PricingConfig;

// ---------------------------------------------------------------- pricing
test("the shipped pricing config is valid", () => assert.deepEqual(validatePricingConfig(cfg), []));

test("config validation catches bad prices, limits, keys and modules", () => {
  const bad = structuredClone(cfg);
  bad.packages[0].pricing.monthly.subscriptionMonthlyEgp = 0;
  bad.packages[1].pricing.oneTime.licenseEgp = 10.005;
  bad.packages[1].limits.maxMembers = 0;
  bad.packages[2].key = "Bad Key" as never;
  bad.packages[2].modules = ["sales", "nonsense" as never];
  const errors = validatePricingConfig(bad).join("\n");
  assert.match(errors, /subscriptionMonthlyEgp must be greater than zero/);
  assert.match(errors, /more than two decimals/);
  assert.match(errors, /maxMembers must be a whole number/);
  assert.match(errors, /not allowed/);
  assert.match(errors, /unknown module "nonsense"/);
});

test("no package contains the placeholder 'offers' module, and every package includes the one before it", () => {
  for (const p of cfg.packages) assert.ok(!(p.modules as string[]).includes("offers"));
  for (let i = 1; i < cfg.packages.length; i++) for (const m of cfg.packages[i - 1].modules) assert.ok(cfg.packages[i].modules.includes(m), `${cfg.packages[i].key} lacks ${m}`);
});

test("option A, first payment: license + first hosting month today, hosting is the recurring charge", () => {
  const q = buildQuote({ packageKey: "basic", option: "one_time", purpose: "initial" });
  const p = cfg.packages[0].pricing.oneTime;
  assert.deepEqual(q.lines.map((l) => l.id), ["license", "hosting"]);
  assert.equal(q.dueToday, toPiasters(p.licenseEgp) + toPiasters(p.hostingMonthlyEgp));
  assert.equal(q.recurring?.amount, toPiasters(p.hostingMonthlyEgp));
  assert.equal(q.grantsMonths, 1);
});

test("option A without the bundled first hosting month charges the license only and grants no access time", () => {
  const c = structuredClone(cfg); c.terms.includeFirstHostingWithLicense = false;
  const q = buildQuote({ packageKey: "basic", option: "one_time", purpose: "initial" }, c);
  assert.deepEqual(q.lines.map((l) => l.id), ["license"]);
  assert.equal(q.grantsMonths, 0);
  assert.ok(q.recurring && q.recurring.amount > 0);
});

test("option A renewal is hosting only", () => {
  const q = buildQuote({ packageKey: "complete", option: "one_time", purpose: "renewal" });
  assert.deepEqual(q.lines.map((l) => l.id), ["hosting"]);
  assert.equal(q.dueToday, toPiasters(cfg.packages[2].pricing.oneTime.hostingMonthlyEgp));
});

test("option B: one subscription month today and the same amount recurring", () => {
  const q = buildQuote({ packageKey: "professional", option: "monthly", purpose: "initial" });
  assert.deepEqual(q.lines.map((l) => l.id), ["subscription"]);
  assert.equal(q.dueToday, toPiasters(cfg.packages[1].pricing.monthly.subscriptionMonthlyEgp));
  assert.equal(q.recurring?.amount, q.dueToday);
});

test("recurring charges are NEVER presented as automatic while XPay cannot do it", () => {
  for (const o of ["one_time", "monthly"]) assert.equal(buildQuote({ packageKey: "basic", option: o, purpose: "initial" }).recurring?.autoCharged, false);
  assert.equal(cfg.terms.automaticRenewal, false);
});

test("the quote carries the entitlements written into the license; unlimited is null", () => {
  assert.deepEqual(buildQuote({ packageKey: "basic", option: "monthly", purpose: "initial" }).entitlements.max_members, 3);
  const c = buildQuote({ packageKey: "complete", option: "monthly", purpose: "initial" }).entitlements;
  assert.equal(c.max_members, null); assert.equal(c.max_warehouses, null);
});

test("unknown package or option is rejected, amounts are integers", () => {
  assert.throws(() => buildQuote({ packageKey: "gold", option: "monthly", purpose: "initial" }));
  assert.throws(() => buildQuote({ packageKey: "basic", option: "yearly", purpose: "initial" }));
  assert.equal(toPiasters(1499.99), 149999);
  assert.ok(Number.isInteger(buildQuote({ packageKey: "basic", option: "one_time", purpose: "initial" }).dueToday));
});

test("fit violations read as Arabic sentences naming the modules", () => {
  const t = describeFitViolations([{ kind: "modules", keys: ["partners"] }, { kind: "members", current: 5, max: 3 }, { kind: "warehouses", current: 4, max: 2 }]);
  assert.equal(t.length, 3); assert.match(t[0], /الشركاء/); assert.match(t[1], /5/); assert.match(t[2], /4/);
});

// ---------------------------------------------------------------- license status
test("access state: none / license_only / active / grace / expired", () => {
  const now = new Date("2026-06-15T00:00:00Z");
  const g = { graceEnabled: true, graceHours: 7 * 24 };
  assert.equal(evaluateAccess(null, now, g), "none");
  assert.equal(evaluateAccess({ access_paid_through: null }, now, g), "license_only");
  assert.equal(evaluateAccess({ access_paid_through: "2026-06-20T00:00:00Z" }, now, g), "active");
  assert.equal(evaluateAccess({ access_paid_through: "2026-06-10T00:00:00Z" }, now, g), "grace");
  assert.equal(evaluateAccess({ access_paid_through: "2026-06-01T00:00:00Z" }, now, g), "expired");
  assert.equal(daysUntil("2026-06-20T00:00:00Z", now), 5);
  assert.equal(daysUntil(null, now), null);
});

// ---------------------------------------------------------------- checkout: what the customer sends is never what is charged
test("the quote ignores any price, discount, duration or total supplied by the browser", () => {
  const honest = buildQuote({ packageKey: "basic", option: "monthly", purpose: "initial" }, cfg);
  const tampered = buildQuote({ packageKey: "basic", option: "monthly", purpose: "initial", amount: 1, dueToday: 1, price: 1, discount: 99, months: 36, grantsMonths: 36, lines: [] } as never, cfg);
  assert.deepEqual(tampered, honest);
  assert.ok(honest.dueToday > 100);
  assert.equal(honest.grantsMonths, 1);
});

test("a renewal and a first purchase are quoted from the same configuration, and a bad package or option is refused", () => {
  const first = buildQuote({ packageKey: "basic", option: "one_time", purpose: "initial" }, cfg);
  const renew = buildQuote({ packageKey: "basic", option: "one_time", purpose: "renewal" }, cfg);
  assert.ok(first.dueToday > renew.dueToday, "the license is charged once; a renewal is hosting only");
  assert.equal(renew.grantsMonths, 1);
  assert.throws(() => buildQuote({ packageKey: "nope", option: "monthly", purpose: "initial" }, cfg));
  assert.throws(() => buildQuote({ packageKey: "basic", option: "yearly", purpose: "initial" }, cfg));
});

test("a changed package price changes NEW quotes only (an order stores its own lines and amount)", () => {
  const edited = structuredClone(cfg);
  edited.packages.find((p) => p.key === "basic")!.pricing.monthly.subscriptionMonthlyEgp += 100;
  const before = buildQuote({ packageKey: "basic", option: "monthly", purpose: "initial" }, cfg);
  const after = buildQuote({ packageKey: "basic", option: "monthly", purpose: "initial" }, edited);
  assert.equal(after.dueToday, before.dueToday + 10000);
  assert.equal(before.dueToday, buildQuote({ packageKey: "basic", option: "monthly", purpose: "initial" }, cfg).dueToday);
});

// ---------------------------------------------------------------- webhook signature
const SECRET = "whsec_test_secret";
const sign = (body: string, t: number, secret = SECRET) => `t=${t},v1=${createHmac("sha256", secret).update(`${t}.${body}`).digest("hex")}`;
const NOW = 1_800_000_000_000;
const T = NOW / 1000;

test("a correctly signed body verifies", () => assert.deepEqual(verifyWebhookSignature("{\"a\":1}", sign("{\"a\":1}", T), SECRET, NOW), { ok: true }));
test("a changed body, a wrong secret, a missing header, garbage and a stale timestamp are all rejected", () => {
  const body = "{\"a\":1}";
  assert.equal(verifyWebhookSignature(body + " ", sign(body, T), SECRET, NOW).ok, false);
  assert.equal(verifyWebhookSignature(body, sign(body, T, "whsec_other"), SECRET, NOW).ok, false);
  assert.deepEqual(verifyWebhookSignature(body, null, SECRET, NOW), { ok: false, reason: "missing" });
  assert.deepEqual(verifyWebhookSignature(body, "nonsense", SECRET, NOW), { ok: false, reason: "malformed" });
  assert.deepEqual(verifyWebhookSignature(body, `t=${T},v1=abc`, SECRET, NOW), { ok: false, reason: "mismatch" });
  assert.deepEqual(verifyWebhookSignature(body, sign(body, T - 301), SECRET, NOW), { ok: false, reason: "stale" });
  assert.equal(verifyWebhookSignature(body, sign(body, T - 299), SECRET, NOW).ok, true);
  assert.equal(verifyWebhookSignature(body, sign(body, T), "", NOW).ok, false);
});
test("a header carrying several v1 values accepts any valid one", () => {
  const body = "x"; const good = sign(body, T).split("v1=")[1];
  assert.equal(verifyWebhookSignature(body, `t=${T},v1=${"0".repeat(64)},v1=${good}`, SECRET, NOW).ok, true);
});

// ---------------------------------------------------------------- xpay client
const sessionJson = (over: Record<string, unknown> = {}) => ({ id: "cs_test_AbC123", object: "checkout.session", status: "complete", paymentStatus: "paid", amountTotal: 100, currency: "egp", url: "https://checkout.xpay.app/c/cs_test_AbC123", metadata: { order_id: "o1" }, paymentIntent: { id: "pi_test_1" }, livemode: false, ...over });

test("the checkout request body follows XPay's documented shape", () => {
  const b = buildCheckoutSessionBody({ orderId: "11111111-1111-1111-1111-111111111111", organizationId: "org", siteUrl: "https://kayan.example/", currency: "EGP", lines: [{ label: "x", amount: 149900 }] });
  assert.equal(b.afterCompletion.redirect.url, "https://kayan.example/checkout/success?order=11111111-1111-1111-1111-111111111111");
  assert.equal(b.cancelUrl, "https://kayan.example/checkout/fail?order=11111111-1111-1111-1111-111111111111");
  assert.deepEqual(b.lineItems[0], { priceData: { currency: "EGP", unitAmount: 149900, productData: { name: "x" } }, quantity: 1 });
  assert.equal(b.uiMode, "hosted"); assert.equal(b.mode, "payment"); assert.equal(b.locale, "ar");
  assert.ok(!JSON.stringify(b).includes("sk_"));
});

test("parseSession reads what Kayan needs and refuses malformed payloads", () => {
  const s = parseSession(sessionJson());
  assert.equal(s.currency, "EGP"); assert.equal(s.paymentIntentId, "pi_test_1"); assert.equal(s.metadata.order_id, "o1");
  assert.throws(() => parseSession(sessionJson({ status: "weird" })), XpayError);
  assert.throws(() => parseSession(sessionJson({ amountTotal: 10.5 })), XpayError);
  assert.throws(() => parseSession(null), XpayError);
});

function fakeFetch(replies: Array<{ status: number; body?: unknown } | "network">) {
  const calls: { url: string; init: RequestInit }[] = [];
  const impl = (async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    const r = replies.shift()!;
    if (r === "network") throw new TypeError("fetch failed");
    return new Response(JSON.stringify(r.body ?? {}), { status: r.status });
  }) as unknown as typeof fetch;
  return { impl, calls };
}
const noSleep = async () => {};

test("create session: bearer key + Idempotency-Key are sent, a timeout is retried with the SAME key", async () => {
  const f = fakeFetch(["network", { status: 200, body: sessionJson({ status: "open", paymentStatus: "unpaid" }) }]);
  const c = createXpayClient({ secretKey: "sk_test_abc", fetchImpl: f.impl, sleep: noSleep });
  const s = await c.createCheckoutSession(buildCheckoutSessionBody({ orderId: "o", organizationId: "g", siteUrl: "https://k.example", currency: "EGP", lines: [{ label: "a", amount: 100 }] }), "order-1");
  assert.equal(s.id, "cs_test_AbC123");
  assert.equal(f.calls.length, 2);
  for (const call of f.calls) {
    const h = call.init.headers as Record<string, string>;
    assert.equal(h.Authorization, "Bearer sk_test_abc"); assert.equal(h["Idempotency-Key"], "order-1");
  }
});
test("a 4xx is not retried and surfaces XPay's code; 5xx is retried then fails", async () => {
  const f1 = fakeFetch([{ status: 400, body: { error: { code: "parameter_invalid", message: "bad" } } }]);
  await assert.rejects(createXpayClient({ secretKey: "sk_test_abc", fetchImpl: f1.impl, sleep: noSleep }).getCheckoutSession("cs_test_AbC123"), (e: XpayError) => e.status === 400 && e.code === "parameter_invalid");
  assert.equal(f1.calls.length, 1);
  const f2 = fakeFetch([{ status: 503 }, { status: 503 }, { status: 503 }]);
  await assert.rejects(createXpayClient({ secretKey: "sk_test_abc", fetchImpl: f2.impl, sleep: noSleep }).getCheckoutSession("cs_test_AbC123"), (e: XpayError) => e.retryable);
  assert.equal(f2.calls.length, 3);
});
test("the session id is validated before it goes into a URL", async () => {
  const f = fakeFetch([]);
  await assert.rejects(createXpayClient({ secretKey: "sk_test_abc", fetchImpl: f.impl }).getCheckoutSession("../refunds"));
  assert.equal(f.calls.length, 0);
});

// ---------------------------------------------------------------- reconcile + webhook handler
type Order = OrderRef & { amount: number };
function harness(order: Order | null, session: ReturnType<typeof parseSession> | Error, applyResult: ApplyResultCode = "applied") {
  const seen = new Set<string>(); const done = new Set<string>();
  const log = { applied: [] as unknown[], marked: [] as unknown[], finished: [] as string[], xpayCalls: 0 };
  const store: BillingStore = {
    async beginWebhookEvent(id) { if (done.has(id)) return false; seen.add(id); return true; },
    async finishWebhookEvent(id, o) { done.add(id); log.finished.push(o); },
    async findOrderBySession(s) { return order && order.xpay_session_id === s ? order : null; },
    async findOrderById(id) { return order && order.id === id ? order : null; },
    async applyPayment(a) { log.applied.push(a); if (order?.status === "paid") return "already_applied"; if (order && applyResult === "applied") order.status = "paid"; return applyResult; },
    async markOrder(id, status, reason) { log.marked.push({ id, status, reason }); return true; },
  };
  const xpay = { async getCheckoutSession() { log.xpayCalls++; if (session instanceof Error) throw session; return session; } };
  return { deps: { store, xpay }, log, order };
}
const ev = (type: string, id = "evt_1", sid = "cs_test_AbC123") => ({ id, type, data: { object: { id: sid } } });
const mkOrder = (over: Partial<Order> = {}): Order => ({ id: "o1", status: "pending", xpay_session_id: "cs_test_AbC123", amount: 100, ...over });

test("a paid session activates the order, using XPay's numbers (not the webhook body)", async () => {
  const h = harness(mkOrder(), parseSession(sessionJson()));
  const r = await handleXpayEvent({ ...ev("checkout.session.completed"), data: { object: { id: "cs_test_AbC123", amountTotal: 1 } } } as never, h.deps);
  assert.deepEqual(r, { status: 200, outcome: "applied" });
  assert.deepEqual(h.log.applied[0], { orderId: "o1", sessionId: "cs_test_AbC123", paymentIntentId: "pi_test_1", amount: 100, currency: "EGP" });
});
test("the same event delivered twice is applied once", async () => {
  const h = harness(mkOrder(), parseSession(sessionJson()));
  await handleXpayEvent(ev("checkout.session.completed"), h.deps);
  const again = await handleXpayEvent(ev("checkout.session.completed"), h.deps);
  assert.deepEqual(again, { status: 200, outcome: "duplicate" });
  assert.equal(h.log.applied.length, 1); assert.equal(h.log.xpayCalls, 1);
});
test("two different events for one payment (completed + async succeeded) still activate once", async () => {
  const h = harness(mkOrder(), parseSession(sessionJson()));
  await handleXpayEvent(ev("checkout.session.completed", "evt_1"), h.deps);
  const r = await handleXpayEvent(ev("checkout.session.async_payment_succeeded", "evt_2"), h.deps);
  assert.equal(r.outcome, "already_applied");
});
test("an unpaid completed session (Fawry reference) activates nothing and leaves the order open", async () => {
  const h = harness(mkOrder(), parseSession(sessionJson({ paymentStatus: "unpaid" })));
  const r = await handleXpayEvent(ev("checkout.session.completed"), h.deps);
  assert.equal(r.outcome, "awaiting_payment"); assert.equal(h.log.applied.length, 0); assert.equal(h.log.marked.length, 0);
});
test("a forged 'completed' event for an unpaid session cannot activate anything (XPay is asked, not the body)", async () => {
  const h = harness(mkOrder(), parseSession(sessionJson({ status: "open", paymentStatus: "unpaid" })));
  const r = await handleXpayEvent({ ...ev("checkout.session.completed"), data: { object: { id: "cs_test_AbC123", status: "complete", paymentStatus: "paid" } } } as never, h.deps);
  assert.equal(r.outcome, "session_open"); assert.equal(h.log.applied.length, 0);
});
test("async failure closes the order as failed; expiry closes it as expired", async () => {
  const f = harness(mkOrder(), parseSession(sessionJson({ paymentStatus: "unpaid" })));
  assert.equal((await handleXpayEvent(ev("checkout.session.async_payment_failed"), f.deps)).outcome, "failed_marked");
  assert.deepEqual(f.log.marked[0], { id: "o1", status: "failed", reason: "async_payment_failed" });
  const e = harness(mkOrder(), parseSession(sessionJson({ status: "expired", paymentStatus: "unpaid" })));
  assert.equal((await handleXpayEvent(ev("checkout.session.expired"), e.deps)).outcome, "expired");
});
test("a session with no order is acknowledged (200) so XPay stops retrying, and nothing is applied", async () => {
  const h = harness(null, parseSession(sessionJson({ metadata: {} })));
  const r = await handleXpayEvent(ev("checkout.session.completed"), h.deps);
  assert.deepEqual(r, { status: 200, outcome: "unknown_order" }); assert.equal(h.log.applied.length, 0);
});
test("an order whose session id was not stored yet is found through our own metadata", async () => {
  const o = mkOrder({ xpay_session_id: null, id: "11111111-1111-1111-1111-111111111111" });
  const h = harness(o, parseSession(sessionJson({ metadata: { order_id: o.id } })));
  assert.equal((await handleXpayEvent(ev("checkout.session.completed"), h.deps)).outcome, "applied");
});
test("a metadata hint pointing at an order that belongs to ANOTHER session is refused", async () => {
  const o = mkOrder({ xpay_session_id: "cs_test_OTHER", id: "11111111-1111-1111-1111-111111111111" });
  const h = harness(o, parseSession(sessionJson({ metadata: { order_id: o.id } })));
  assert.equal((await handleXpayEvent(ev("checkout.session.completed"), h.deps)).outcome, "unknown_order");
});
test("an amount mismatch is reported, not retried forever", async () => {
  const h = harness(mkOrder(), parseSession(sessionJson()), "amount_mismatch");
  assert.deepEqual(await handleXpayEvent(ev("checkout.session.completed"), h.deps), { status: 200, outcome: "amount_mismatch" });
});
test("a transient XPay failure answers 500 and the event is NOT marked done, so the retry is processed", async () => {
  const failing = harness(mkOrder(), new XpayError("down", { status: 0, retryable: true }));
  assert.deepEqual(await handleXpayEvent(ev("checkout.session.completed"), failing.deps), { status: 500, outcome: "retry_later" });
  assert.equal(failing.log.finished.length, 0);
  // XPay retries; this time XPay answers
  const ok = harness(mkOrder(), parseSession(sessionJson()));
  const first = await handleXpayEvent(ev("checkout.session.completed"), { ...ok.deps, xpay: { async getCheckoutSession() { throw new Error("db blip"); } } });
  assert.equal(first.status, 500);
  assert.equal((await handleXpayEvent(ev("checkout.session.completed"), ok.deps)).outcome, "applied");
});
test("irrelevant event types are acknowledged untouched; unreadable ones are 400", async () => {
  const h = harness(mkOrder(), parseSession(sessionJson()));
  assert.deepEqual(await handleXpayEvent(ev("charge.succeeded"), h.deps), { status: 200, outcome: "ignored_type" });
  assert.equal((await handleXpayEvent({} as never, h.deps)).status, 400);
  assert.equal((await handleXpayEvent({ id: "e", type: "checkout.session.completed", data: {} } as never, h.deps)).status, 400);
  assert.equal(h.log.xpayCalls, 0);
});
test("the return page path: reconcileSession on an open session changes nothing; on a paid one activates", async () => {
  const open = harness(mkOrder(), parseSession(sessionJson({ status: "open", paymentStatus: "unpaid" })));
  assert.equal(await reconcileSession("cs_test_AbC123", open.deps), "session_open");
  const paid = harness(mkOrder(), parseSession(sessionJson()));
  assert.equal(await reconcileSession("cs_test_AbC123", paid.deps), "applied");
});

// ---------------------------------------------------------------- admin overrides (0061)
import { resolvePricingConfig, overridesFromEditable, toEditable, validateEditable } from "./pricing.ts";
import { isSuperAdmin } from "../admin/allowlist.ts";

test("with no override the configuration is EXACTLY the shipped one", () => {
  for (const raw of [null, undefined, {}, { packages: null }, "x", 5]) {
    const r = resolvePricingConfig(raw);
    assert.equal(r.custom, false); assert.deepEqual(r.config, cfg);
  }
});
test("saving the shipped values unchanged is still 'not custom'", () => {
  const all = Object.fromEntries(cfg.packages.map((p) => [p.key, toEditable(p)]));
  const r = resolvePricingConfig(overridesFromEditable(all));
  assert.equal(r.custom, false); assert.deepEqual(r.config.packages, cfg.packages);
});
test("an override changes prices, limits and modules — and checkout maths follows it", () => {
  const all = Object.fromEntries(cfg.packages.map((p) => [p.key, toEditable(p)]));
  all.basic.licenseEgp = 9999.5; all.basic.maxMembers = null; all.basic.modules = ["sales", "customers"];
  const r = resolvePricingConfig(overridesFromEditable(all));
  assert.equal(r.custom, true);
  const q = buildQuote({ packageKey: "basic", option: "one_time", purpose: "initial" }, r.config);
  assert.equal(q.lines[0].amount, 999950);
  assert.equal(q.entitlements.max_members, null);
  assert.deepEqual(q.entitlements.modules, ["customers", "sales"]);
  // the other packages are untouched
  assert.deepEqual(r.config.packages[1], cfg.packages[1]);
});
test("a broken override (bad price, junk, unknown module) is ignored as a whole: the defaults win", () => {
  const bad = { packages: { basic: { pricing: { oneTime: { licenseEgp: -5 } } } } };
  assert.deepEqual(resolvePricingConfig(bad).config, cfg);
  assert.deepEqual(resolvePricingConfig({ packages: { basic: { limits: { maxMembers: 0 } } } }).config, cfg);
  const junk = resolvePricingConfig({ packages: { basic: { modules: ["sales", "hack"], limits: { maxMembers: "many" } } } });
  assert.deepEqual(junk.config.packages[0].modules, ["sales"]);       // unknown module dropped, bad limit ignored
  assert.equal(junk.config.packages[0].limits.maxMembers, cfg.packages[0].limits.maxMembers);
});
test("an unknown package key in an override is ignored", () => {
  assert.deepEqual(resolvePricingConfig({ packages: { gold: { limits: { maxMembers: 1 } } } }).config.packages, cfg.packages);
});
test("what an admin types is validated, in Arabic", () => {
  const ok = toEditable(cfg.packages[0]);
  assert.deepEqual(validateEditable("basic", "الأساسية", ok), []);
  assert.match(validateEditable("basic", "الأساسية", { ...ok, licenseEgp: 0 })[0], /أكبر من صفر/);
  assert.match(validateEditable("basic", "الأساسية", { ...ok, hostingMonthlyEgp: 1.234 })[0], /خانتين/);
  assert.match(validateEditable("basic", "الأساسية", { ...ok, maxMembers: 0 })[0], /≥ 1/);
  assert.equal(validateEditable("basic", "x", { ...ok, maxMembers: null, maxWarehouses: null }).length, 0);
  assert.match(validateEditable("basic", "x", { ...ok, modules: ["sales", "sales"] })[0], /الوحدات/);
});

// ---------------------------------------------------------------- super admin allow-list
const U = "11111111-2222-3333-4444-555555555555";
test("nobody is a super admin unless configured", () => {
  assert.equal(isSuperAdmin({ id: U, email: "a@b.c", email_confirmed_at: "x" }, {}), false);
  assert.equal(isSuperAdmin(null, { SUPER_ADMIN_USER_IDS: U }), false);
});
test("a user id match is enough (case/space-insensitive); another id is not", () => {
  assert.equal(isSuperAdmin({ id: U }, { SUPER_ADMIN_USER_IDS: ` other , ${U.toUpperCase()} ` }), true);
  assert.equal(isSuperAdmin({ id: "00000000-0000-0000-0000-000000000000" }, { SUPER_ADMIN_USER_IDS: U }), false);
});
test("an email match needs a CONFIRMED email", () => {
  const env = { SUPER_ADMIN_EMAILS: "Boss@Kayan.test, x@y.z" };
  assert.equal(isSuperAdmin({ id: U, email: "boss@kayan.test", email_confirmed_at: "2026-01-01" }, env), true);
  assert.equal(isSuperAdmin({ id: U, email: "boss@kayan.test", email_confirmed_at: null }, env), false);
  assert.equal(isSuperAdmin({ id: U, email: "boss@kayan.test.evil", email_confirmed_at: "x" }, env), false);
});
