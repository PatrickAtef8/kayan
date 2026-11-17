import { test } from "node:test";
import assert from "node:assert/strict";
import { checkXpayConfig, assertKeyAllowed, embeddedCheckout, isRealProduction } from "./xpay-guard.ts";

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

test("the in-page payment window is on only with a well-formed publishable key from the SAME mode as the secret key", () => {
  assert.deepEqual(embeddedCheckout({ XPAY_SECRET_KEY: "sk_live_a" }), { enabled: false, reason: "not_set" });
  assert.deepEqual(embeddedCheckout({ XPAY_SECRET_KEY: "sk_live_a", XPAY_PUBLISHABLE_KEY: "pk_live_b" }), { enabled: true, publishableKey: "pk_live_b" });
  assert.deepEqual(embeddedCheckout({ XPAY_SECRET_KEY: "sk_test_a", XPAY_PUBLISHABLE_KEY: " pk_test_b " }), { enabled: true, publishableKey: "pk_test_b" });
  assert.deepEqual(embeddedCheckout({ XPAY_SECRET_KEY: "sk_live_a", XPAY_PUBLISHABLE_KEY: "pk_test_b" }), { enabled: false, reason: "mode_mismatch" });
  assert.deepEqual(embeddedCheckout({ XPAY_SECRET_KEY: "sk_test_a", XPAY_PUBLISHABLE_KEY: "pk_live_b" }), { enabled: false, reason: "mode_mismatch" });
  assert.deepEqual(embeddedCheckout({ XPAY_SECRET_KEY: "sk_live_a", XPAY_PUBLISHABLE_KEY: "sk_live_oops" }), { enabled: false, reason: "invalid_key" });
  assert.deepEqual(embeddedCheckout({ XPAY_SECRET_KEY: "sk_live_a", XPAY_PUBLISHABLE_KEY: "pk_live_" }), { enabled: false, reason: "invalid_key" });
});

test("a wrong publishable key is a warning, never a blocker: checkout keeps working through XPay's own page", () => {
  const base = { NODE_ENV: "production", XPAY_SECRET_KEY: "sk_live_a", XPAY_WEBHOOK_SECRET: "whsec_a", BILLING_PRICES_CONFIRMED: "true", NEXT_PUBLIC_SITE_URL: "https://k.example" };
  assert.deepEqual(checkXpayConfig(base).warnings, []);
  assert.deepEqual(checkXpayConfig({ ...base, XPAY_PUBLISHABLE_KEY: "pk_live_b" }).warnings, []);
  const bad = checkXpayConfig({ ...base, XPAY_PUBLISHABLE_KEY: "pk_test_b" });
  assert.equal(bad.blocking.length, 0);
  assert.equal(bad.warnings.length, 1);
  assert.match(bad.warnings[0], /different modes/);
  assert.match(checkXpayConfig({ ...base, XPAY_PUBLISHABLE_KEY: "nope" }).warnings[0], /does not look like/);
});
