import { test } from "node:test";
import assert from "node:assert/strict";
import { decideAccess, parseAccess } from "./access-gate.ts";
import { evaluateAccess, parseDbAccess, isOpenState, type GraceSettings } from "./license-status.ts";
import { buildQuote, isHostingFree, resolvePricingConfig, validateEditable, validatePricingConfig, overridesFromEditable, toEditable, type PricingConfig } from "./pricing.ts";
import { PRICING_CONFIG } from "../../config/pricing.config.ts";
import { trialCountdownText, daysText, isValidTrialDays, trialDaysLeft, trialIsUrgent, trialLeftText, validateTrialSettings } from "./trial.ts";

const base = PRICING_CONFIG as PricingConfig;
const G24: GraceSettings = { graceEnabled: true, graceHours: 24 };
const END = new Date("2030-01-15T00:00:00Z");
const at = (ms: number) => new Date(END.getTime() + ms);

// ------------------------------------------------------------------ the trial state machine (mirror of billing_access_state, 0074)
test("no license: no trial = closed, a running trial = open, an ended one = closed", () => {
  assert.equal(evaluateAccess(null, at(0), G24), "none");
  assert.equal(evaluateAccess(null, at(-1000), G24, END.toISOString()), "trial");
  assert.equal(evaluateAccess(null, at(0), G24, END.toISOString()), "trial", "exactly at the end it is still open");
  assert.equal(evaluateAccess(null, at(1), G24, END.toISOString()), "trial_expired");
  assert.equal(evaluateAccess(null, at(0), G24, "garbage"), "none", "an unreadable date never opens anything");
  assert.equal(isOpenState("trial"), true);
  assert.equal(isOpenState("trial_expired"), false);
});

test("a license always wins over a trial", () => {
  const lapsed = { complimentary: false, access_paid_through: new Date(END.getTime() - 3 * 86_400_000).toISOString(), payment_option: "monthly" };
  assert.equal(evaluateAccess(lapsed, at(0), G24, new Date(END.getTime() + 99 * 86_400_000).toISOString()), "expired", "a running trial does not re-open a lapsed subscription");
  assert.equal(evaluateAccess({ complimentary: true, access_paid_through: null }, at(0), G24, null), "free");
});

test("free hosting: a perpetual license is never closed for a missing hosting payment; a monthly subscription still is", () => {
  const lapsedOneTime = { complimentary: false, access_paid_through: new Date(END.getTime() - 9 * 86_400_000).toISOString(), payment_option: "one_time" };
  assert.equal(evaluateAccess(lapsedOneTime, at(0), G24, null, false), "expired");
  assert.equal(evaluateAccess(lapsedOneTime, at(0), G24, null, true), "license_only");
  assert.equal(evaluateAccess({ ...lapsedOneTime, payment_option: "monthly" }, at(0), G24, null, true), "expired");
});

// ------------------------------------------------------------------ the gate
test("the gate: trial opens, an ended trial closes with its own reason", () => {
  const db = (state: string) => parseDbAccess({ state, open: state === "trial", seconds_left: 100, trial_ends_at: END.toISOString(), hosting_free: false });
  assert.deepEqual(decideAccess({ isPlatformAdmin: false, access: db("trial") }), { open: true, reason: "trial" });
  assert.deepEqual(decideAccess({ isPlatformAdmin: false, access: db("trial_expired") }), { open: false, reason: "trial_expired" });
  assert.deepEqual(decideAccess({ isPlatformAdmin: false, access: db("none") }), { open: false, reason: "never_paid" });
  assert.deepEqual(decideAccess({ isPlatformAdmin: false, access: db("expired") }), { open: false, reason: "expired" });
  assert.equal(decideAccess({ isPlatformAdmin: false, access: null }).open, false, "no answer from the database = closed");
});

test("parsing: the trial fields and the offer are read defensively", () => {
  const a = parseAccess({ org_name: "x", license: null, owners: [], access: { state: "trial", open: true, seconds_left: 5, trial_ends_at: END.toISOString(), trial_started_at: null, hosting_free: true }, trial_offer: { enabled: true, days: 7, eligible: true } });
  assert.equal(a?.access?.trialEndsAt, END.toISOString());
  assert.equal(a?.access?.hostingFree, true);
  assert.deepEqual(a?.trialOffer, { enabled: true, days: 7, eligible: true });
  const b = parseAccess({ org_name: "x", license: null, owners: [], access: { state: "none", open: false }, trial_offer: "oops" });
  assert.deepEqual(b?.trialOffer, { enabled: false, days: 15, eligible: false }, "a missing or malformed offer means: not offered");
  assert.equal(parseDbAccess({ state: "something_new" }), null, "an unknown state is no information");
});

// ------------------------------------------------------------------ settings and wording
test("trial settings: 1..365 whole days and an explicit on/off", () => {
  assert.deepEqual(validateTrialSettings({ enabled: true, days: 15 }), []);
  assert.deepEqual(validateTrialSettings({ enabled: false, days: 1 }), []);
  assert.deepEqual(validateTrialSettings({ enabled: true, days: 365 }), []);
  for (const days of [0, -3, 366, 1.5, NaN, "15", null]) assert.ok(validateTrialSettings({ enabled: true, days }).length > 0, `days=${String(days)}`);
  assert.ok(validateTrialSettings({ enabled: "yes", days: 15 }).length > 0);
  assert.equal(isValidTrialDays(15), true);
});

test("days left are rounded up, and the wording", () => {
  const now = new Date("2030-01-01T00:00:00Z");
  assert.equal(trialDaysLeft("2030-01-02T00:00:00Z", now), 1);
  assert.equal(trialDaysLeft("2030-01-01T03:00:00Z", now), 1, "3 hours left still counts as a day");
  assert.equal(trialDaysLeft("2029-12-31T00:00:00Z", now), 0);
  assert.equal(trialDaysLeft(null, now), 0);
  assert.equal(daysText(1), "يوم واحد");
  assert.equal(daysText(2), "يومان");
  assert.match(daysText(5), /أيام/);
  assert.match(daysText(15), /يومًا/);
  assert.match(trialLeftText(3600), /أقل من يوم/);
  assert.equal(trialIsUrgent(3 * 86400), true);
  assert.equal(trialIsUrgent(3 * 86400 + 1), false);
});

// ------------------------------------------------------------------ hosting & maintenance = 0
const withHosting = (v: number): PricingConfig => {
  const all = Object.fromEntries(base.packages.map((p) => [p.key, toEditable(p)]));
  all.one_time.hostingMonthlyEgp = v;
  return resolvePricingConfig(overridesFromEditable(all)).config;
};

test("the admin may save 0 hosting, but never 0 for the license or the monthly subscription", () => {
  const ok = toEditable(base.packages.find((p) => p.key === "one_time")!);
  assert.deepEqual(validateEditable("one_time", "الرخصة الدائمة", { ...ok, hostingMonthlyEgp: 0 }), []);
  assert.ok(validateEditable("one_time", "الرخصة الدائمة", { ...ok, hostingMonthlyEgp: -1 }).length > 0);
  assert.ok(validateEditable("one_time", "الرخصة الدائمة", { ...ok, hostingMonthlyEgp: Number.NaN }).length > 0, "an empty field is not 'free'");
  assert.ok(validateEditable("one_time", "الرخصة الدائمة", { ...ok, hostingMonthlyEgp: null }).length > 0);
  assert.ok(validateEditable("one_time", "الرخصة الدائمة", { ...ok, licenseEgp: 0 }).length > 0);
  const m = toEditable(base.packages.find((p) => p.key === "monthly")!);
  assert.ok(validateEditable("monthly", "الاشتراك الشهري", { ...m, subscriptionMonthlyEgp: 0 }).length > 0);
});

test("a saved 0 hosting price survives the round trip into the live configuration", () => {
  const cfg = withHosting(0);
  assert.deepEqual(validatePricingConfig(cfg), []);
  assert.equal(isHostingFree(cfg), true);
  assert.equal(isHostingFree(base), false);
  assert.equal(isHostingFree(withHosting(0.5)), false);
});

test("free hosting: the first payment is the license only, with nothing after it", () => {
  const cfg = withHosting(0);
  const q = buildQuote({ plan: "one_time", purpose: "initial" }, cfg);
  assert.deepEqual(q.lines.map((l) => l.id), ["license"]);
  assert.equal(q.dueToday, q.lines[0].amount);
  assert.ok(q.dueToday > 0);
  assert.equal(q.grantsMonths, 0, "no paid month: the license has no end date");
  assert.equal(q.recurring, null, "nothing is due again");
  assert.equal(q.hostingFree, true);
  assert.throws(() => buildQuote({ plan: "one_time", purpose: "renewal" }, cfg), /nothing to renew/, "there is no renewal to start");
});

test("free hosting does not touch the monthly plan, nor the normal one-time quote", () => {
  const cfg = withHosting(0);
  const m = buildQuote({ plan: "monthly", purpose: "renewal" }, cfg);
  assert.ok(m.dueToday > 0 && m.hostingFree === false && m.grantsMonths === 1);
  const normal = buildQuote({ plan: "one_time", purpose: "initial" }, base);
  assert.equal(normal.hostingFree, false);
  assert.deepEqual(normal.lines.map((l) => l.id), ["license", "hosting"]);
  assert.ok(buildQuote({ plan: "one_time", purpose: "renewal" }, base).dueToday > 0);
});

test("the live countdown wording", () => {
  assert.match(trialCountdownText(9 * 86400 + 3 * 3600 + 59), /أيام/);
  assert.match(trialCountdownText(9 * 86400 + 3 * 3600), /ساعات/);
  assert.equal(trialCountdownText(86400), "يوم واحد");
  assert.match(trialCountdownText(3 * 3600 + 12 * 60), /ساعات.*دقيقة/);
  assert.equal(trialCountdownText(3600), "ساعة");
  assert.match(trialCountdownText(45 * 60), /دقيقة/);
  assert.equal(trialCountdownText(59), "أقل من دقيقة");
  assert.equal(trialCountdownText(-5), "أقل من دقيقة");
});
