import { test } from "node:test";
import assert from "node:assert/strict";
import { decideAccess, isBillingPath, parseAccess } from "./access-gate.ts";
import { evaluateAccess, parseDbAccess, remainingText, isOpenState, type AccessState, type GraceSettings } from "./license-status.ts";
import { checkoutView, canRetry } from "./checkout-state.ts";
import { adminLists } from "../admin/allowlist.ts";

const HOUR = 3_600_000;
const T = new Date("2030-01-01T00:00:00Z");                       // the instant a subscription ends in these tests
const lic = { complimentary: false, access_paid_through: T.toISOString() };
const at = (ms: number) => new Date(T.getTime() + ms);
const G24: GraceSettings = { graceEnabled: true, graceHours: 24 };
const dbAccess = (state: AccessState) => parseDbAccess({ state, open: isOpenState(state), seconds_left: 3600, grace_enabled: true, grace_hours: 24 });

// ---------------------------------------------------------------- the state machine (a pure mirror of billing_access_state in 0063)
test("expiration boundaries with a 24h grace period", () => {
  assert.equal(evaluateAccess(lic, at(-HOUR), G24), "active");
  assert.equal(evaluateAccess(lic, at(0), G24), "active", "exactly at the end it is still active");
  assert.equal(evaluateAccess(lic, at(1), G24), "grace", "one millisecond later: grace");
  assert.equal(evaluateAccess(lic, at(24 * HOUR), G24), "grace", "exactly at the end of the grace it is still open");
  assert.equal(evaluateAccess(lic, at(24 * HOUR + 1), G24), "expired");
});

test("grace disabled, or 0 hours, locks at the moment of expiration", () => {
  for (const g of [{ graceEnabled: false, graceHours: 24 }, { graceEnabled: true, graceHours: 0 }]) {
    assert.equal(evaluateAccess(lic, at(0), g), "active");
    assert.equal(evaluateAccess(lic, at(1), g), "expired");
  }
});

test("the grace length is the configured one", () => {
  assert.equal(evaluateAccess(lic, at(71 * HOUR), { graceEnabled: true, graceHours: 72 }), "grace");
  assert.equal(evaluateAccess(lic, at(73 * HOUR), { graceEnabled: true, graceHours: 72 }), "expired");
});

test("never paid / free / license-only", () => {
  assert.equal(evaluateAccess(null, T, G24), "none");
  assert.equal(evaluateAccess({ complimentary: true, access_paid_through: "2000-01-01T00:00:00Z" }, T, G24), "free", "free access never lapses");
  assert.equal(evaluateAccess({ complimentary: false, access_paid_through: null }, T, G24), "license_only");
});

// ---------------------------------------------------------------- who is let in
test("a company that never paid is closed", () => {
  assert.deepEqual(decideAccess({ isPlatformAdmin: false, access: dbAccess("none") }), { open: false, reason: "never_paid" });
  assert.deepEqual(decideAccess({ isPlatformAdmin: false, access: null }), { open: false, reason: "never_paid" }, "no information is never an open door");
});

test("paid, free and license-only companies are open", () => {
  assert.deepEqual(decideAccess({ isPlatformAdmin: false, access: dbAccess("active") }), { open: true, reason: "paid" });
  assert.deepEqual(decideAccess({ isPlatformAdmin: false, access: dbAccess("license_only") }), { open: true, reason: "paid" });
  assert.deepEqual(decideAccess({ isPlatformAdmin: false, access: dbAccess("free") }), { open: true, reason: "free" });
});

test("the grace period is open (with a warning), expiry is closed", () => {
  assert.deepEqual(decideAccess({ isPlatformAdmin: false, access: dbAccess("grace") }), { open: true, reason: "grace" });
  assert.deepEqual(decideAccess({ isPlatformAdmin: false, access: dbAccess("expired") }), { open: false, reason: "expired" });
});

test("a platform administrator is never gated; the decision does not depend on the company", () => {
  for (const s of ["none", "expired", "grace", "active"] as const) assert.equal(decideAccess({ isPlatformAdmin: true, access: dbAccess(s) }).open, true, s);
  assert.deepEqual(decideAccess({ isPlatformAdmin: true, access: null }), { open: true, reason: "platform_admin" });
});

test("members of an administrator's demo company are NOT exempt: they follow the company's real subscription", () => {
  // the caller is not an administrator; the company has no subscription → closed, whoever owns it
  assert.equal(decideAccess({ isPlatformAdmin: false, access: dbAccess("none") }).open, false);
  // once the platform gave the company free access they are in
  assert.equal(decideAccess({ isPlatformAdmin: false, access: dbAccess("free") }).open, true);
});

// ---------------------------------------------------------------- the one door an unpaid owner may use
test("an unpaid owner may reach the billing pages and nothing else in the dashboard", () => {
  assert.equal(isBillingPath("/dashboard/billing"), true);
  assert.equal(isBillingPath("/dashboard/billing/return"), true);
  for (const p of ["/dashboard", "/dashboard/sales", "/dashboard/billingx", "/dashboard/settings/billing", "/admin/billing", "", null, undefined]) assert.equal(isBillingPath(p as string), false, String(p));
});

// ---------------------------------------------------------------- reading the database answer
test("parseDbAccess / parseAccess read my_org_access and distrust anything else", () => {
  assert.equal(parseDbAccess(null), null);
  assert.equal(parseDbAccess({ state: "free-for-all" }), null);
  assert.equal(parseDbAccess({ state: "grace", open: "yes" })!.open, false, "only a real boolean true opens");
  const a = parseAccess({ org_name: "شركة", license: { complimentary: "yes", access_paid_through: null }, owners: [{ id: 5 }, null, { id: "u2" }], access: { state: "expired", open: false } });
  assert.equal(a!.license!.complimentary, false, "a license flag that is not a real true is NOT free access");
  assert.deepEqual(a!.owners, [{ id: "u2", email: null, confirmed: false }]);
  assert.equal(a!.access!.state, "expired");
  assert.equal(parseAccess({ license: null, owners: [] })!.access, null, "an old (0062) answer without the access part is not a verdict");
});

test("remainingText counts hours and minutes in Arabic", () => {
  assert.match(remainingText(23 * 3600 + 15 * 60), /23|٢٣/);
  assert.match(remainingText(90), /دقيقة|دقائق/);
  assert.equal(remainingText(-5), remainingText(0));
});

// ---------------------------------------------------------------- what the customer is told
test("checkout views: only a verified payment is 'paid'", () => {
  const v = (status: string, returnedAs: "success" | "fail", checking = false, outcome: Parameters<typeof checkoutView>[0]["outcome"] = null) => checkoutView({ status, returnedAs, checking, outcome });
  assert.equal(v("paid", "success"), "paid");
  assert.equal(v("paid", "fail"), "paid", "a paid order is paid even if the browser came back on the failure URL");
  assert.equal(v("pending", "success"), "confirming", "reaching the success URL with an unverified order is NOT success");
  assert.equal(v("pending", "success", false, "session_open"), "confirming");
  assert.equal(v("pending", "fail", false, "session_open"), "incomplete", "leaving XPay with the session open is not a failure");
  assert.equal(v("pending", "fail", false, "awaiting_payment"), "confirming", "a Fawry reference waiting to be paid is still pending");
  assert.equal(v("pending", "fail", true), "confirming", "if XPay cannot be reached we never claim failure");
  assert.equal(v("failed", "success"), "failed");
  assert.equal(v("canceled", "fail"), "canceled");
  assert.equal(v("expired", "fail"), "expired");
});

test("retry is offered only when it is safe", () => {
  assert.deepEqual((["paid", "confirming", "incomplete", "failed", "canceled", "expired"] as const).filter(canRetry), ["incomplete", "failed", "canceled", "expired"]);
});

// ---------------------------------------------------------------- the environment lists
test("the administrator lists are parsed from the two environment variables", () => {
  assert.deepEqual(adminLists({}), { ids: [], emails: [] });
  assert.deepEqual(adminLists({ SUPER_ADMIN_USER_IDS: " A-1 , ,b-2 ", SUPER_ADMIN_EMAILS: "Boss@X.com" }), { ids: ["a-1", "b-2"], emails: ["boss@x.com"] });
});
