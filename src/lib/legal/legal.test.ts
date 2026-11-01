import { test } from "node:test";
import assert from "node:assert/strict";
import { fillPlaceholders, stripReviewNotes, extractReviewNotes, parseMarkdown, parseInline, safeHref, renderLegal } from "./render.ts";
import { checkAcceptance, ACCEPTANCE_MESSAGE } from "./acceptance.ts";
import { LEGAL_DEFAULTS, LEGAL_KEYS, LEGAL_PATH } from "../../config/legal.defaults.ts";
import { parseSelection, selectionFromMetadata, checkoutPath, signupPath, loginPath } from "../billing/selection.ts";
import { buildQuote } from "../billing/pricing.ts";
import { PRICING_CONFIG } from "../../config/pricing.config.ts";
import type { PricingConfig } from "../billing/pricing.ts";

const cfg = PRICING_CONFIG as PricingConfig;
const VARS = { company_name: "كيان للبرمجيات", phone: "+20 100 000 0000", email: "hi@kayan.test", address: "القاهرة", commercial_register: "123", tax_registration: "456" };

// ================================================================ package selection through signup
test("a valid package and option from /pricing become a selection", () => {
  assert.deepEqual(parseSelection({ package: "basic", option: "monthly" }, cfg), { packageKey: "basic", option: "monthly" });
  assert.deepEqual(parseSelection({ package: "complete", option: "one_time" }, cfg), { packageKey: "complete", option: "one_time" });
});

test("an unknown package, an unknown option or a malformed value is NOT a selection", () => {
  for (const raw of [{ package: "platinum", option: "monthly" }, { package: "basic", option: "yearly" }, { package: "basic" }, { option: "monthly" }, { package: ["basic"], option: "monthly" },
    { package: "../../admin", option: "monthly" }, { package: "basic;drop", option: "monthly" }, { package: "x".repeat(100), option: "monthly" }, null, undefined, {}]) {
    assert.equal(parseSelection(raw as never, cfg), null, JSON.stringify(raw));
  }
});

test("a price, discount or total in the URL is ignored: a selection is only a package and an option", () => {
  const sel = parseSelection({ package: "basic", option: "monthly", amount: 1, price: 1, dueToday: 1, discount: 99 } as never, cfg)!;
  assert.deepEqual(Object.keys(sel).sort(), ["option", "packageKey"]);
  assert.equal(checkoutPath(sel), "/checkout?package=basic&option=monthly");
  // and what is charged comes from the server's configuration, whatever the selection carried
  assert.deepEqual(buildQuote({ packageKey: sel.packageKey, option: sel.option, purpose: "initial", amount: 1 } as never, cfg), buildQuote({ packageKey: "basic", option: "monthly", purpose: "initial" }, cfg));
});

test("a package that the Super Admin removed or renamed no longer validates", () => {
  const edited = { packages: cfg.packages.filter((p) => p.key !== "basic") };
  assert.equal(parseSelection({ package: "basic", option: "monthly" }, edited), null);
});

test("the selection remembered in the account metadata is validated like any other input", () => {
  assert.deepEqual(selectionFromMetadata({ plan_selection: { packageKey: "complete", option: "monthly" } }, cfg), { packageKey: "complete", option: "monthly" });
  assert.equal(selectionFromMetadata({ plan_selection: { packageKey: "complete", option: "monthly", price: 1 } }, { packages: [] }), null);
  assert.equal(selectionFromMetadata({ plan_selection: { packageKey: "nope", option: "monthly" } }, cfg), null);
  assert.equal(selectionFromMetadata({ plan_selection: "basic" }, cfg), null);
  assert.equal(selectionFromMetadata({}, cfg), null);
  assert.equal(selectionFromMetadata(null, cfg), null);
});

test("signup and login links keep the selection; without one they are plain", () => {
  const sel = { packageKey: "professional", option: "one_time" as const };
  assert.equal(signupPath(sel), "/signup?package=professional&option=one_time");
  assert.equal(loginPath(sel), "/login?package=professional&option=one_time");
  assert.equal(signupPath(null), "/signup");
  assert.equal(loginPath(null), "/login");
});

// ================================================================ legal text rendering
test("placeholders are filled and an empty one shows a dash, never a raw token", () => {
  assert.equal(fillPlaceholders("{{company_name}} — {{phone}}", VARS), "كيان للبرمجيات — +20 100 000 0000");
  assert.equal(fillPlaceholders("tel {{phone}} / {{email}}", { phone: "  " }), "tel — / —");
  assert.equal(fillPlaceholders("{{unknown}}", VARS), "—");
});

test("lawyer-review markers never reach the public text and are listed for the admin", () => {
  const md = "نص عادي\n[[REVIEW: راجع البند]]\n\nفقرة [[REVIEW: ثانية]] أخرى";
  assert.deepEqual(extractReviewNotes(md), ["راجع البند", "ثانية"]);
  const pub = stripReviewNotes(md);
  assert.ok(!pub.includes("REVIEW") && !pub.includes("راجع البند"));
  assert.match(pub, /نص عادي/);
});

test("the markdown subset becomes blocks", () => {
  const b = parseMarkdown("## عنوان\n\nفقرة **غامقة** و[رابط](/terms)\n\n- أ\n- ب\n\n1. واحد\n2. اثنان\n\n> ملاحظة");
  assert.deepEqual(b.map((x) => x.t), ["h2", "p", "ul", "ol", "quote"]);
  assert.equal((b[2] as { items: unknown[] }).items.length, 2);
  assert.deepEqual(parseInline("a **b** [c](/x)"), [{ t: "text", v: "a " }, { t: "bold", v: "b" }, { t: "text", v: " " }, { t: "link", href: "/x", v: "c" }]);
});

test("nothing typed in the editor can become markup or an unsafe link", () => {
  const b = parseMarkdown('<script>alert(1)</script> [x](javascript:alert(1)) [y](//evil.test) [ok](https://example.com/a)');
  const inl = (b[0] as { inline: ReturnType<typeof parseInline> }).inline;
  assert.ok(inl.every((n) => n.t !== "link" || /^https:\/\/example\.com/.test(n.href)), "only the safe link stays a link");
  assert.match(JSON.stringify(inl), /<script>/, "markup stays as inert TEXT (the component renders text nodes only)");
  for (const bad of ["javascript:alert(1)", "data:text/html,x", "//evil.test", "vbscript:x", " JaVaScRiPt:1"]) assert.equal(safeHref(bad), null, bad);
  for (const good of ["/privacy", "https://a.b/c", "mailto:a@b.co", "tel:+20100"]) assert.ok(safeHref(good), good);
});

test("renderLegal fills, strips and parses in one go", () => {
  const blocks = renderLegal("## الاتصال\n\n- الهاتف: {{phone}}\n[[REVIEW: x]]", VARS);
  assert.deepEqual(blocks.map((x) => x.t), ["h2", "ul"]);
  assert.match(JSON.stringify(blocks), /\+20 100 000 0000/);
  assert.ok(!JSON.stringify(blocks).includes("REVIEW"));
});

// ================================================================ the shipped texts
test("all three documents exist in Arabic and English with the business facts they must state", () => {
  assert.deepEqual([...LEGAL_KEYS], ["terms", "privacy", "refund"]);
  for (const k of LEGAL_KEYS) {
    const d = LEGAL_DEFAULTS[k];
    for (const t of [d.titleAr, d.bodyAr, d.titleEn, d.bodyEn]) assert.ok(t.length > 50 || t === d.titleAr || t === d.titleEn);
    assert.ok(d.bodyAr.length > 2500 && d.bodyEn.length > 2500, `${k} is a real document`);
    assert.ok(!d.bodyAr.includes("$kayanlegal$") && !d.bodyEn.includes("$kayanlegal$"));
    assert.ok(/\{\{phone\}\}/.test(d.bodyAr) && /\{\{phone\}\}/.test(d.bodyEn), `${k}: the contact number is a placeholder`);
    assert.ok(extractReviewNotes(d.bodyAr).length >= 2 && extractReviewNotes(d.bodyEn).length >= 2, `${k}: assumptions are flagged for a lawyer`);
    assert.equal(extractReviewNotes(d.bodyAr).length, extractReviewNotes(d.bodyEn).length, `${k}: both languages flag the same clauses`);
    // only known placeholders
    for (const body of [d.bodyAr, d.bodyEn]) for (const m of body.matchAll(/\{\{\s*([a-z_]+)\s*\}\}/g)) assert.ok(Object.keys(VARS).includes(m[1]), `${k}: unknown placeholder ${m[1]}`);
  }
  assert.deepEqual(LEGAL_PATH, { terms: "/terms", privacy: "/privacy", refund: "/refund-policy" });
});

test("the texts describe the real business model: XPay, no automatic charging, license vs subscription, grace period, no card data", () => {
  const t = LEGAL_DEFAULTS.terms, p = LEGAL_DEFAULTS.privacy, r = LEGAL_DEFAULTS.refund;
  for (const [ar, en] of [[t.bodyAr, t.bodyEn], [p.bodyAr, p.bodyEn], [r.bodyAr, r.bodyEn]]) { assert.match(ar, /XPay/); assert.match(en, /XPay/); }
  assert.match(t.bodyAr, /الرخصة الدائمة/); assert.match(t.bodyAr, /الاشتراك الشهري/); assert.match(t.bodyAr, /فترة سماح/); assert.match(t.bodyAr, /تلقائيًا/);
  assert.match(t.bodyEn, /Perpetual License/); assert.match(t.bodyEn, /Monthly Subscription/); assert.match(t.bodyEn, /grace period/i);
  assert.match(t.bodyEn, /never charge automatically/i); assert.match(p.bodyEn, /do not receive your card number/i);
  assert.match(p.bodyAr, /151 لسنة 2020/); assert.match(p.bodyEn, /No\. 151 of 2020/);
  assert.match(r.bodyEn, /no automatic renewal/i);
});

test("the texts do not claim a recurring charge, an uptime SLA or a guarantee the product does not give", () => {
  for (const k of LEGAL_KEYS) for (const body of [LEGAL_DEFAULTS[k].bodyEn]) {
    assert.doesNotMatch(body, /will (automatically )?(renew|charge) (your|the) (card|subscription)/i);
    assert.doesNotMatch(body, /99\.\d+\s*%/);
    assert.doesNotMatch(body, /guarantee[sd]? (that )?(the platform|uptime|availability)/i);
  }
  assert.match(LEGAL_DEFAULTS.terms.bodyEn, /do not commit to a specific uptime/i);
});

// ================================================================ the required acceptance
const CURRENT = { terms: 3, privacy: 2, refund: 1 };
test("acceptance: the exact current versions are accepted, and the SERVER's values are what is recorded", () => {
  const r = checkAcceptance({ terms: 3, privacy: 2, refund: 1, evil: 9 } as never, CURRENT);
  assert.deepEqual(r, { ok: true, versions: CURRENT });
});

test("acceptance: missing, partial, malformed or tampered versions are refused", () => {
  for (const input of [null, undefined, {}, { terms: 3 }, { terms: "3", privacy: 2, refund: 1 }, { terms: 3.5, privacy: 2, refund: 1 }, { terms: 0, privacy: 2, refund: 1 }, { terms: -1, privacy: 2, refund: 1 }, { terms: true, privacy: 2, refund: 1 }]) {
    assert.deepEqual(checkAcceptance(input as never, CURRENT), { ok: false, reason: "missing" }, JSON.stringify(input));
  }
});

test("acceptance: versions that are no longer current are 'stale' (the page was open while the text changed)", () => {
  assert.deepEqual(checkAcceptance({ terms: 2, privacy: 2, refund: 1 }, CURRENT), { ok: false, reason: "stale" });
  assert.deepEqual(checkAcceptance({ terms: 3, privacy: 2, refund: 9 }, CURRENT), { ok: false, reason: "stale" });
  assert.match(ACCEPTANCE_MESSAGE.stale, /حدّث الصفحة/);
});

test("acceptance: when the documents are not in the database nothing can be accepted", () => {
  assert.deepEqual(checkAcceptance({ terms: 1, privacy: 1, refund: 1 }, null), { ok: false, reason: "unavailable" });
  assert.deepEqual(checkAcceptance({ terms: 1, privacy: 1, refund: 1 }, { terms: 1, privacy: 1 }), { ok: false, reason: "unavailable" });
  assert.deepEqual(checkAcceptance({ terms: 0, privacy: 0, refund: 0 }, { terms: 0, privacy: 0, refund: 0 }), { ok: false, reason: "unavailable" }, "shipped text (version 0) can never be accepted");
});
