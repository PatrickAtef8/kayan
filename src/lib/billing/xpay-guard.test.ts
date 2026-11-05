import { test } from "node:test";
import assert from "node:assert/strict";
import { checkXpayConfig, assertKeyAllowed, isRealProduction } from "./xpay-guard.ts";

const prod = { NODE_ENV: "production", VERCEL_ENV: "production", NEXT_PUBLIC_SITE_URL: "https://kayan.example", BILLING_PRICES_CONFIRMED: "true", XPAY_WEBHOOK_SECRET: "whsec_abc" };

test("a test key is refused in real production, allowed in preview / development", () => {
  assert.throws(() => assertKeyAllowed({ ...prod, XPAY_SECRET_KEY: "sk_test_abc" }), /test key/);
  assert.doesNotThrow(() => assertKeyAllowed({ ...prod, XPAY_SECRET_KEY: "sk_live_abc" }));
  assert.doesNotThrow(() => assertKeyAllowed({ ...prod, VERCEL_ENV: "preview", XPAY_SECRET_KEY: "sk_test_abc" }));
  assert.doesNotThrow(() => assertKeyAllowed({ NODE_ENV: "development", XPAY_SECRET_KEY: "sk_test_abc" }));
  assert.equal(isRealProduction({ NODE_ENV: "production" }), true);            // self-hosted production
  assert.equal(isRealProduction({ NODE_ENV: "production", VERCEL_ENV: "preview" }), false);
});

test("the readiness report names every blocker for production", () => {
  const r = checkXpayConfig({ NODE_ENV: "production", VERCEL_ENV: "production", XPAY_SECRET_KEY: "sk_test_abc" });
  assert.equal(r.mode, "test");
  assert.ok(r.blocking.some((m) => /TEST key/.test(m)));
  assert.ok(r.blocking.some((m) => /XPAY_WEBHOOK_SECRET is not set/.test(m)));
  assert.ok(r.blocking.some((m) => /BILLING_PRICES_CONFIRMED/.test(m)));
  const ok = checkXpayConfig({ ...prod, XPAY_SECRET_KEY: "sk_live_abc" });
  assert.deepEqual(ok.blocking, []);
  assert.equal(ok.mode, "live");
});

test("no secret value ever appears in a report", () => {
  const r = checkXpayConfig({ ...prod, XPAY_SECRET_KEY: "sk_test_SUPERSECRET", XPAY_WEBHOOK_SECRET: "nope_SECRET2" });
  assert.ok(!JSON.stringify(r).includes("SUPERSECRET") && !JSON.stringify(r).includes("SECRET2"));
  assert.ok(r.warnings.some((w) => /whsec_/.test(w)));
});

test("outside production nothing blocks but a missing key", () => {
  assert.deepEqual(checkXpayConfig({ NODE_ENV: "development", XPAY_SECRET_KEY: "sk_test_a", XPAY_WEBHOOK_SECRET: "whsec_a" }).blocking, []);
  assert.ok(checkXpayConfig({ NODE_ENV: "development" }).blocking.length >= 2);
});
