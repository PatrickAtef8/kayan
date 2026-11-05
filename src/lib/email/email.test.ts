import { test } from "node:test";
import assert from "node:assert/strict";
import { loadEmailConfig, parseSender, isValidEmailAddress, describeConfigProblem } from "./config.ts";
import { renderTemplate, TEMPLATE_NAMES, type TemplateData, type TemplateName } from "./templates.ts";
import { escapeHtml, safeUrl, renderLayout } from "./layout.ts";
import { sendViaResend, classifyResendError, describeSendError, type FetchLike } from "./transport.ts";
import { maskEmail, hashRecipient } from "./privacy.ts";

const env = (o: Record<string, string>) => o as Record<string, string | undefined>;

test("config: both variables are required, nothing is defaulted or hardcoded", () => {
  assert.deepEqual(loadEmailConfig(env({})), { ok: false, problem: "missing_api_key" });
  assert.deepEqual(loadEmailConfig(env({ RESEND_API_KEY: "re_x" })), { ok: false, problem: "missing_from" });
  assert.deepEqual(loadEmailConfig(env({ RESEND_API_KEY: "re_x", RESEND_FROM_EMAIL: "not an address" })), { ok: false, problem: "invalid_from" });
  assert.deepEqual(loadEmailConfig(env({ RESEND_API_KEY: "  ", RESEND_FROM_EMAIL: "a@b.com" })), { ok: false, problem: "missing_api_key" });
  for (const p of ["missing_api_key", "missing_from", "invalid_from", "invalid_reply_to"] as const) assert.ok(describeConfigProblem(p).length > 10);
});

test("config: a plain address gets the Kayan display name; a named one is kept; only the env value decides the sender", () => {
  const a = loadEmailConfig(env({ RESEND_API_KEY: "k", RESEND_FROM_EMAIL: "no-reply@kayan.example" }));
  assert.ok(a.ok && a.config.from === "Kayan | كيان <no-reply@kayan.example>" && a.config.fromAddress === "no-reply@kayan.example" && !a.config.testingSender);
  const b = loadEmailConfig(env({ RESEND_API_KEY: "k", RESEND_FROM_EMAIL: "Acme Team <hello@acme.test>" }));
  assert.ok(b.ok && b.config.from === "Acme Team <hello@acme.test>");
  // switching the domain = changing the one variable
  const c = loadEmailConfig(env({ RESEND_API_KEY: "k", RESEND_FROM_EMAIL: "no-reply@new-domain.test" }));
  assert.ok(c.ok && c.config.fromAddress === "no-reply@new-domain.test");
});

test("config: the resend.dev testing sender is detected", () => {
  const r = loadEmailConfig(env({ RESEND_API_KEY: "k", RESEND_FROM_EMAIL: "onboarding@resend.dev" }));
  assert.ok(r.ok && r.config.testingSender);
});

test("config: header injection through the sender or reply-to is rejected", () => {
  assert.equal(parseSender("a@b.com\r\nBcc: x@y.com"), null);
  assert.equal(parseSender("Evil\n <a@b.com>"), null);
  assert.equal(loadEmailConfig(env({ RESEND_API_KEY: "k", RESEND_FROM_EMAIL: "a@b.com", RESEND_REPLY_TO: "x@y.com\nBcc: z@z.com" })).ok, false);
  assert.equal(isValidEmailAddress("a@b.com\nBcc: c@d.com"), false);
  assert.equal(isValidEmailAddress("nobody"), false);
  assert.equal(isValidEmailAddress("a@b"), false);
  assert.equal(isValidEmailAddress("ahmed.ali+kayan@company.com.eg"), true);
});

const SAMPLES: { [K in TemplateName]: TemplateData[K] } = {
  team_invite: { orgName: "شركة <النور> & أولاده", roleName: "مندوب", inviterName: "أحمد", link: "https://kayan.example/reset-password?token_hash=abc&type=invite" },
  team_invite_existing: { orgName: "Acme", roleName: "Accountant", link: "https://kayan.example/invites" },
  password_reset: { link: "https://kayan.example/reset-password?token_hash=abc&type=recovery" },
  subscription_reminder: { orgName: "Acme", daysLeft: 7, endsOn: "2026-12-01", packageName: "Professional", renewUrl: "https://kayan.example/dashboard/billing" },
  payment_receipt: { orgName: "Acme", packageName: "Complete", amountLabel: "1,500 ج.م", paidOn: "2026-11-03", reference: "A1B2C3D4", periodEnd: "2026-12-03", billingUrl: "https://kayan.example/dashboard/billing" },
  payment_needs_review: { orgName: "Acme", amountLabel: "1,500 ج.م", reference: "A1B2C3D4", billingUrl: "https://kayan.example/dashboard/billing" },
};

test("templates: every template renders in Arabic (RTL) and English (LTR) with one shared brand shell", () => {
  for (const name of TEMPLATE_NAMES) {
    for (const locale of ["ar", "en"] as const) {
      const r = renderTemplate(name, SAMPLES[name] as never, { locale, siteUrl: "https://kayan.example" });
      assert.ok(r.subject.length > 5 && !/[\r\n]/.test(r.subject), `${name}/${locale} subject`);
      assert.ok(r.html.includes(locale === "ar" ? 'dir="rtl"' : 'dir="ltr"'), `${name}/${locale} direction`);
      assert.ok(r.html.includes(`lang="${locale}"`));
      assert.ok(r.html.includes("#344E41"), "brand colour");               // the shared header / button colour
      assert.ok(r.html.includes(locale === "ar" ? "كيان" : "Kayan"));
      assert.ok(!/<script|javascript:|<img /i.test(r.html), "no script / remote image");
      assert.ok(r.text.length > 20);
      assert.ok(/<a [^>]*href="https?:\/\//.test(r.html), `${name} has a button link`);
    }
  }
});

test("templates: user-controlled text is escaped (no HTML injection through a company name)", () => {
  const r = renderTemplate("team_invite", { ...SAMPLES.team_invite, orgName: '<img src=x onerror=alert(1)>"', inviterName: "<b>x</b>" });
  assert.ok(!r.html.includes("<img src=x"));
  assert.ok(!r.html.includes("<b>x</b>"));
  assert.ok(r.html.includes("&lt;img src=x onerror=alert(1)&gt;&quot;"));
  assert.ok(!/[\r\n]/.test(renderTemplate("team_invite", { ...SAMPLES.team_invite, orgName: "A\r\nBcc: x@y.com" }).subject));
});

test("layout: only absolute http(s) links become buttons", () => {
  assert.equal(safeUrl("javascript:alert(1)"), null);
  assert.equal(safeUrl("data:text/html,x"), null);
  assert.equal(safeUrl("/relative"), null);
  assert.equal(safeUrl('https://a.com/"onmouseover="x'), null);
  assert.ok(safeUrl("https://a.com/x?y=1&z=2"));
  const r = renderLayout({ locale: "en", preheader: "p", heading: "h", blocks: [], cta: { label: "Go", url: "javascript:alert(1)" }, reason: "r" });
  assert.ok(!r.html.includes("javascript:"));
  assert.equal(escapeHtml(`<&>"'`), "&lt;&amp;&gt;&quot;&#39;");
});

test("templates: reminder wording follows the days left (upcoming, today, ended) and says renewal is manual", () => {
  const up = renderTemplate("subscription_reminder", { ...SAMPLES.subscription_reminder, daysLeft: 3 }, { locale: "en" });
  const today = renderTemplate("subscription_reminder", { ...SAMPLES.subscription_reminder, daysLeft: 0 }, { locale: "en" });
  const ended = renderTemplate("subscription_reminder", { ...SAMPLES.subscription_reminder, daysLeft: -2 }, { locale: "en" });
  assert.match(up.subject, /ends in 3 days/);
  assert.match(today.subject, /ends today/);
  assert.match(ended.subject, /has ended/);
  assert.match(up.text, /Nothing is charged automatically/);
  assert.match(renderTemplate("subscription_reminder", SAMPLES.subscription_reminder).html, /لا يتم خصم أي مبلغ تلقائيًا/);
});

const okFetch = (calls: { init: Parameters<FetchLike>[1] }[]): FetchLike => async (_u, init) => { calls.push({ init }); return { ok: true, status: 200, json: async () => ({ id: "em_123" }) }; };
const CFG = { apiKey: "re_secret", from: "Kayan <a@b.com>", replyTo: null };
const MSG = { to: "u@x.com", subject: "s", html: "<p>h</p>", text: "t" };

test("transport: posts the Resend payload with bearer auth and an idempotency key; the sender is the configured one", async () => {
  const calls: { init: Parameters<FetchLike>[1] }[] = [];
  const r = await sendViaResend(CFG, MSG, { fetchImpl: okFetch(calls) });
  assert.deepEqual(r, { ok: true, id: "em_123", attempts: 1 });
  const body = JSON.parse(calls[0].init.body);
  assert.equal(body.from, "Kayan <a@b.com>");
  assert.deepEqual(body.to, ["u@x.com"]);
  assert.equal(calls[0].init.headers.Authorization, "Bearer re_secret");
  assert.ok(calls[0].init.headers["Idempotency-Key"]);
});

test("transport: a retryable failure is retried with the SAME idempotency key; a permanent one is not retried", async () => {
  const keys: string[] = [];
  let n = 0;
  const flaky: FetchLike = async (_u, init) => { keys.push(init.headers["Idempotency-Key"]); n++; return n === 1 ? { ok: false, status: 503, json: async () => ({ name: "application_error", message: "x" }) } : { ok: true, status: 200, json: async () => ({ id: "em_2" }) }; };
  const r = await sendViaResend(CFG, MSG, { fetchImpl: flaky, sleep: async () => {} });
  assert.ok(r.ok && r.attempts === 2);
  assert.equal(keys[0], keys[1]);

  let m = 0;
  const bad: FetchLike = async () => { m++; return { ok: false, status: 422, json: async () => ({ name: "validation_error", message: "Invalid `to` field. The email address needs to be valid." }) }; };
  const r2 = await sendViaResend(CFG, MSG, { fetchImpl: bad, sleep: async () => {} });
  assert.deepEqual(r2, { ok: false, code: "invalid_recipient", retryable: false, status: 422, attempts: 1 });
  assert.equal(m, 1);
});

test("transport: network failures and garbage answers never throw", async () => {
  const boom: FetchLike = async () => { throw new Error("ECONNRESET"); };
  const r = await sendViaResend(CFG, MSG, { fetchImpl: boom, sleep: async () => {} });
  assert.ok(!r.ok && r.code === "network_error" && r.retryable && r.attempts === 2);
  const html: FetchLike = async () => ({ ok: false, status: 502, json: async () => { throw new Error("not json"); } });
  const r2 = await sendViaResend(CFG, MSG, { fetchImpl: html, sleep: async () => {}, maxAttempts: 1 });
  assert.ok(!r2.ok && r2.code === "provider_error");
});

test("transport: Resend's documented errors map to actionable codes (testing sender, unverified domain, bad key, rate limit)", () => {
  assert.equal(classifyResendError(403, { name: "validation_error", message: "You can only send testing emails to your own email address (me@x.com). To send emails to other recipients, please verify a domain" }).code, "testing_sender_restricted");
  assert.equal(classifyResendError(403, { name: "validation_error", message: "The kayan.example domain is not verified." }).code, "domain_not_verified");
  assert.equal(classifyResendError(401, { name: "missing_api_key", message: "Missing API key" }).code, "invalid_api_key");
  assert.equal(classifyResendError(403, { name: "restricted_api_key", message: "This API key is restricted to only send emails" }).code, "invalid_api_key");
  assert.deepEqual(classifyResendError(429, { name: "rate_limit_exceeded", message: "Too many requests" }), { code: "rate_limited", retryable: true });
  assert.equal(classifyResendError(429, { name: "daily_quota_exceeded", message: "x" }).retryable, false);
  for (const c of ["not_configured", "invalid_recipient", "testing_sender_restricted", "domain_not_verified", "invalid_api_key", "rate_limited", "network_error", "provider_error", "invalid_request"] as const) {
    const m = describeSendError(c);
    assert.ok(m.ar.length > 10 && m.en.length > 10);
    assert.ok(!/re_|@/.test(m.ar + m.en.replace("RESEND_FROM_EMAIL", "").replace("RESEND_API_KEY", "")), "messages carry no secrets or addresses");
  }
});

test("privacy: logs get a masked address and a stable hash, never the address", () => {
  assert.equal(maskEmail("john.smith@example.com"), "j***@e***.com");
  assert.equal(maskEmail("garbage"), "***");
  assert.ok(!maskEmail("john.smith@example.com").includes("smith"));
  assert.equal(hashRecipient(" A@B.com "), hashRecipient("a@b.com"));
  assert.equal(hashRecipient("a@b.com").length, 64);
});
