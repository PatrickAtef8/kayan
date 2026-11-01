import { test } from "node:test";
import assert from "node:assert/strict";
import { checkRateLimit, parseHit, rateLimitKey, tooManyRequestsMessage, RATE_POLICIES, type RateLimitRpc } from "./rate-limit.ts";
import { validateXpayBaseUrl } from "./billing/xpay-base-url.ts";
import { isSameOriginRequest } from "./request-origin.ts";
import { safeErrorMessage, translateDbError } from "./db-errors.ts";

// ---------------------------------------------------------------- rate limiting
const policy = { name: "t", windowSeconds: 60, max: 2 };
/** A fake of rate_limit_hit(): same contract as the SQL function (counts per key, allowed while hits <= max). */
function fakeDb() {
  const hits = new Map<string, number>();
  const calls: Array<[string, number, number]> = [];
  const rpc: RateLimitRpc = async (key, windowSeconds, max) => {
    calls.push([key, windowSeconds, max]);
    const n = (hits.get(key) ?? 0) + 1;
    hits.set(key, n);
    return { data: { allowed: n <= max, hits: n, retry_after: 42 }, error: null };
  };
  return { rpc, calls };
}

test("a subject is allowed up to the cap, then refused with a wait time", async () => {
  const { rpc } = fakeDb();
  assert.equal((await checkRateLimit(rpc, policy, "u1")).allowed, true);
  assert.equal((await checkRateLimit(rpc, policy, "u1")).allowed, true);
  const third = await checkRateLimit(rpc, policy, "u1");
  assert.equal(third.allowed, false);
  assert.equal(third.retryAfter, 42);
  assert.equal(third.degraded, false);
});

test("subjects are independent, and the policy window / cap are passed to the database unchanged", async () => {
  const { rpc, calls } = fakeDb();
  await checkRateLimit(rpc, policy, "u1"); await checkRateLimit(rpc, policy, "u1"); await checkRateLimit(rpc, policy, "u1");
  assert.equal((await checkRateLimit(rpc, policy, "u2")).allowed, true, "another user is unaffected");
  assert.deepEqual(calls[0], ["t:u1", 60, 2]);
});

test("the key is built from the policy and the subject only, and is bounded", () => {
  assert.equal(rateLimitKey(policy, "abc"), "t:abc");
  assert.ok(rateLimitKey(policy, "x".repeat(1000)).length <= 200, "the database refuses keys over 200 characters");
  assert.notEqual(rateLimitKey(RATE_POLICIES.checkoutStart, "u"), rateLimitKey(RATE_POLICIES.teamInvite, "u"), "policies never share a counter");
});

test("when the counter cannot be reached: fail open by default, fail closed on request — and it says so", async () => {
  const boom: RateLimitRpc = async () => { throw new Error("db down"); };
  const err: RateLimitRpc = async () => ({ data: null, error: { message: "nope" } });
  const logs: string[] = [];
  const log = (m: string) => logs.push(m);
  for (const rpc of [boom, err]) {
    const open = await checkRateLimit(rpc, policy, "u", { log });
    assert.deepEqual([open.allowed, open.degraded], [true, true]);
    const closed = await checkRateLimit(rpc, policy, "u", { failClosed: true, log });
    assert.deepEqual([closed.allowed, closed.degraded], [false, true]);
  }
  assert.equal(logs.length, 4, "every degraded decision is logged");
});

test("an unexpected reply is never read as 'allowed'", () => {
  for (const bad of [null, undefined, "yes", 1, [], {}, { allowed: "true" }, { allowed: 1 }]) assert.equal(parseHit(bad), null, JSON.stringify(bad));
  assert.deepEqual(parseHit({ allowed: false, retry_after: 7.2 }), { allowed: false, retryAfter: 8 });
  assert.deepEqual(parseHit({ allowed: true, retry_after: -5 }), { allowed: true, retryAfter: 0 });
  assert.deepEqual(parseHit({ allowed: true, retry_after: Infinity }), { allowed: true, retryAfter: 0 });
});

test("the shipped policies are sane (positive, a payment start is not looser than a verify poll)", () => {
  for (const p of Object.values(RATE_POLICIES)) { assert.ok(p.windowSeconds >= 1 && p.windowSeconds <= 86400); assert.ok(p.max >= 1); }
  assert.ok(RATE_POLICIES.checkoutStart.max / RATE_POLICIES.checkoutStart.windowSeconds < RATE_POLICIES.checkoutVerify.max / RATE_POLICIES.checkoutVerify.windowSeconds);
});

test("the refusal message names a sensible wait", () => {
  assert.match(tooManyRequestsMessage(5), /بعد دقيقة\./);
  assert.match(tooManyRequestsMessage(90), /دقيقتين/);
  assert.match(tooManyRequestsMessage(300), /5 دقائق/);
  assert.match(tooManyRequestsMessage(0), /بعد دقيقة\./);
});

// ---------------------------------------------------------------- XPAY_API_BASE_URL
test("no override → the default; a proper XPay URL passes in production", () => {
  assert.equal(validateXpayBaseUrl(undefined, true), undefined);
  assert.equal(validateXpayBaseUrl("   ", true), undefined);
  assert.equal(validateXpayBaseUrl("https://api.xpay.app", true), "https://api.xpay.app");
  assert.equal(validateXpayBaseUrl("https://sandbox.xpay.app", true), "https://sandbox.xpay.app");
});

test("production refuses anything that could receive the secret key", () => {
  for (const bad of [
    "http://api.xpay.app", "https://evil.com", "https://xpay.app.evil.com", "https://evilxpay.app", "https://notxpay.app",
    "https://user:pw@api.xpay.app", "http://localhost:4000", "ftp://api.xpay.app", "not a url", "//api.xpay.app",
  ]) assert.throws(() => validateXpayBaseUrl(bad, true), /XPAY_API_BASE_URL/, bad);
});

test("outside production a local mock is allowed, but plain http to a real host and credentials are still refused", () => {
  assert.equal(validateXpayBaseUrl("http://localhost:4000", false), "http://localhost:4000");
  assert.equal(validateXpayBaseUrl("http://127.0.0.1:4000", false), "http://127.0.0.1:4000");
  assert.equal(validateXpayBaseUrl("https://mock.example.test", false), "https://mock.example.test");
  assert.throws(() => validateXpayBaseUrl("http://api.xpay.app", false), /https/);
  assert.throws(() => validateXpayBaseUrl("https://a:b@mock.example.test", false), /credentials/);
});

// ---------------------------------------------------------------- same-origin check (sign-out)
const url = "https://app.kayan.example/api/auth/signout";
const h = (o: Record<string, string>) => new Headers(o);

test("a form posted from our own site is accepted", () => {
  assert.equal(isSameOriginRequest(h({ host: "app.kayan.example", origin: "https://app.kayan.example" }), url), true);
  assert.equal(isSameOriginRequest(h({ origin: "https://app.kayan.example" }), url), true, "matches the request URL's own host");
  assert.equal(isSameOriginRequest(h({ host: "internal:3000", "x-forwarded-host": "app.kayan.example", origin: "https://app.kayan.example" }), "http://internal:3000/x"), true, "behind a proxy");
});

test("a form posted from another site, an opaque origin, or look-alike host is refused", () => {
  assert.equal(isSameOriginRequest(h({ host: "app.kayan.example", origin: "https://evil.example" }), url), false);
  assert.equal(isSameOriginRequest(h({ host: "app.kayan.example", origin: "https://app.kayan.example.evil.example" }), url), false);
  assert.equal(isSameOriginRequest(h({ host: "app.kayan.example", origin: "null" }), url), false);
  assert.equal(isSameOriginRequest(h({ host: "app.kayan.example", origin: "garbage" }), url), false);
});

test("without Origin, Fetch Metadata decides; with neither it is not a browser cross-site request", () => {
  assert.equal(isSameOriginRequest(h({ "sec-fetch-site": "cross-site" }), url), false);
  assert.equal(isSameOriginRequest(h({ "sec-fetch-site": "same-site" }), url), false, "a sibling sub-domain is not us");
  assert.equal(isSameOriginRequest(h({ "sec-fetch-site": "same-origin" }), url), true);
  assert.equal(isSameOriginRequest(h({ "sec-fetch-site": "none" }), url), true);
  assert.equal(isSameOriginRequest(h({}), url), true);
});

// ---------------------------------------------------------------- what a person may be shown for a database error
test("a deliberate Arabic business message from an RPC passes through untouched", () => {
  const m = "المخزون غير كافٍ للمنتج المحدد";
  assert.equal(safeErrorMessage({ message: m, code: "P0001" }), m);
  assert.equal(translateDbError({ message: m, code: "P0001" }), m);
});

test("internal detail never reaches the screen: constraint, table and column names, raw English messages", () => {
  const leaks = [
    { code: "XX000", message: 'relation "billing_orders" does not exist' },
    { code: "23505", message: 'duplicate key value violates unique constraint "customers_org_code_key"' },
    { code: "23503", message: 'insert or update on table "sales_invoices" violates foreign key constraint "sales_invoices_customer_id_fkey"' },
    { code: "42501", message: 'new row violates row-level security policy for table "expenses"' },
    { code: "23514", message: 'new row for relation "products" violates check constraint "products_price_check"' },
    { code: undefined, message: "JWT expired at 2030-01-01T00:00:00Z, secret key sk_test_abc" },
    { code: undefined, message: 'permission denied for function ar_norm' },
  ];
  const quiet = console.error; console.error = () => {};
  try {
    for (const e of leaks) {
      const shown = safeErrorMessage(e);
      assert.ok(/[\u0600-\u06FF]/.test(shown), `Arabic sentence expected for ${e.code}`);
      assert.ok(!/[A-Za-z_]{4,}/.test(shown), `no English / identifier text may survive: ${shown}`);
    }
  } finally { console.error = quiet; }
});

test("known codes map to a helpful sentence; an unknown error is logged, not shown", () => {
  assert.match(safeErrorMessage({ code: "23505", message: "x" }), /بنفس البيانات/);
  assert.match(safeErrorMessage({ code: "42501", message: "x" }), /صلاحية/);
  assert.match(safeErrorMessage({ message: "new row violates row-level security policy" }), /صلاحية/);
  const logged: unknown[] = []; const quiet = console.error; console.error = (...a: unknown[]) => logged.push(a);
  try {
    assert.equal(safeErrorMessage({ code: "XX000", message: "internal boom" }), "حدث خطأ غير متوقع. حاول مرة أخرى.");
    assert.equal(logged.length, 1, "the original is kept for the server log");
    assert.equal(safeErrorMessage(null), "حدث خطأ غير متوقع. حاول مرة أخرى.");
  } finally { console.error = quiet; }
});
