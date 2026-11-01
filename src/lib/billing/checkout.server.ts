import "server-only";
import { randomUUID } from "node:crypto";
import { createAdminClient } from "@/lib/supabase/admin";
import { getSiteUrl } from "@/lib/site-url";
import { loadPricingConfig } from "./config.ts";
import { buildQuote, describeFitViolations, type FitViolation, type Purpose } from "./pricing.ts";
import { buildCheckoutSessionBody, XpayError } from "./xpay-client.ts";
import { BillingConfigError, getXpay, pricesConfirmed } from "./xpay.server.ts";
import type { LegalVersions } from "../legal/acceptance.ts";
import { rateLimit, RATE_POLICIES, tooManyRequestsMessage } from "@/lib/rate-limit.server";

// Starts (or resumes) a checkout for an organization whose OWNER has already been verified by the caller.
// What is charged is decided HERE, from the package key + payment option, never from an amount sent by the browser.

export type StartResult = { ok: true; url: string; orderId: string } | { ok: false; error: string };

const MSG = {
  notOwner: "هذه العملية متاحة لمالك الحساب فقط.",
  licenseExists: "لديك باقة مفعّلة بالفعل. يمكنك تجديد الاستضافة أو الاشتراك من هذه الصفحة.",
  renewalUnavailable: "تعذّر تجديد الاشتراك الآن. حدّث الصفحة وحاول مرة أخرى.",
  notConfigured: "بوابة الدفع غير مفعّلة بعد. تواصل مع فريق كيان لإتمام التفعيل.",
  pricesUnconfirmed: "الأسعار قيد المراجعة، والدفع غير متاح حاليًا. تواصل مع فريق كيان.",
  gatewayDown: "تعذّر الاتصال ببوابة الدفع. لم يُخصم أي مبلغ — حاول مرة أخرى بعد قليل.",
  invalid: "طلب غير صالح. حدّث الصفحة وحاول مرة أخرى.",
  generic: "تعذّر بدء عملية الدفع. لم يُخصم أي مبلغ — حاول مرة أخرى.",
  legalStale: "تم تحديث الشروط أو السياسات منذ فتحت هذه الصفحة. حدّث الصفحة وراجعها ثم وافق من جديد.",
  legalUnavailable: "الصفحات القانونية غير متاحة حاليًا، ولا يمكن بدء الدفع الآن. تواصل مع فريق كيان.",
};

/** Evidence that the owner accepted the CURRENT Terms / Privacy / Refund versions for this payment (recorded against the order). */
export type Acceptance = { versions: LegalVersions; locale: "ar" | "en"; ip: string | null; userAgent: string | null };

export async function startCheckout(input: {
  userId: string;
  organizationId: string;
  packageKey: string;
  option: string;
  purpose: Purpose;
  /** REQUIRED: no payment page is opened for an order without a recorded acceptance. */
  acceptance: Acceptance;
}): Promise<StartResult> {
  if (!pricesConfirmed()) return { ok: false, error: MSG.pricesUnconfirmed };

  // Each start calls XPay and writes an order: cap how fast one user can fire them (a double-click or a retry never gets near this).
  const limit = await rateLimit(RATE_POLICIES.checkoutStart, input.userId);
  if (!limit.allowed) return { ok: false, error: tooManyRequestsMessage(limit.retryAfter) };

  let xpay, siteUrl: string, admin;
  try {
    xpay = getXpay();
    siteUrl = getSiteUrl();
    admin = createAdminClient();
  } catch (e) {
    console.error("billing: payment gateway is not configured —", e instanceof Error ? e.message : e);
    return { ok: false, error: e instanceof BillingConfigError || e instanceof Error ? MSG.notConfigured : MSG.generic };
  }

  // the prices and limits in force RIGHT NOW (admin-managed, falling back to the shipped configuration)
  let quote;
  try {
    const { config } = await loadPricingConfig(admin);
    quote = buildQuote({ packageKey: input.packageKey, option: input.option, purpose: input.purpose }, config);
  } catch {
    return { ok: false, error: MSG.invalid };
  }

  const { data, error } = await admin.rpc("billing_begin_order", {
    p_org: input.organizationId,
    p_user: input.userId,
    p_package: quote.packageKey,
    p_option: quote.option,
    p_purpose: quote.purpose,
    p_currency: quote.currency,
    p_amount: quote.dueToday,
    p_recurring: quote.recurring?.amount ?? null,
    p_lines: quote.lines,
    p_entitlements: quote.entitlements,
    p_grants_months: quote.grantsMonths,
  });
  if (error || !data) {
    console.error("billing: billing_begin_order failed", error?.message);
    return { ok: false, error: MSG.generic };
  }

  const res = data as { result: string; order?: { id: string; checkout_url: string | null; xpay_session_id: string | null }; superseded_session_id?: string | null; report?: { violations: FitViolation[] } };
  switch (res.result) {
    case "not_owner": return { ok: false, error: MSG.notOwner };
    case "license_exists": return { ok: false, error: MSG.licenseExists };
    case "no_license":
    case "mismatch": return { ok: false, error: MSG.renewalUnavailable };
    case "fit_failed": return { ok: false, error: describeFitViolations(res.report?.violations ?? []).join(" ") || MSG.generic };
    case "created":
    case "reused": break;
    default: return { ok: false, error: MSG.generic };
  }
  const order = res.order!;

  // The audit trail: who accepted which versions, when — recorded against this order BEFORE the customer is sent to XPay. The database
  // re-checks that the versions are still the current ones and that the user is an active owner of this order's company.
  const rec = await admin.rpc("billing_record_acceptance", {
    p_order: order.id, p_user: input.userId, p_versions: input.acceptance.versions, p_locale: input.acceptance.locale,
    p_ip: input.acceptance.ip, p_ua: input.acceptance.userAgent,
  });
  if (rec.error || rec.data !== "recorded") {
    if (rec.error) console.error("billing: could not record the acceptance —", rec.error.message);
    return { ok: false, error: rec.data === "stale" ? MSG.legalStale : rec.data === "legal_unavailable" ? MSG.legalUnavailable : MSG.generic };
  }

  // the customer changed their mind: close the payment page they will not use (best effort — a late payment on it is
  // still matched to its order and honoured, see billing_apply_payment)
  if (res.superseded_session_id) {
    xpay.expireCheckoutSession(res.superseded_session_id, `expire-${res.superseded_session_id}`).catch((e) => console.error("billing: could not expire a superseded session", e instanceof Error ? e.message : e));
  }

  // clicking "pay" again resumes the same open payment page
  if (order.checkout_url) return { ok: true, url: order.checkout_url, orderId: order.id };

  try {
    // the order id is the Idempotency-Key: if this request times out and is retried (here or by a second click),
    // XPay returns the session it already created instead of opening another one
    const session = await xpay.createCheckoutSession(
      buildCheckoutSessionBody({ orderId: order.id, organizationId: input.organizationId, siteUrl, currency: quote.currency, lines: quote.lines.map((l) => ({ label: l.label, amount: l.amount })) }),
      order.id,
    );
    const { data: attached, error: attachError } = await admin.rpc("billing_attach_session", { p_order: order.id, p_session: session.id, p_url: session.url });
    if (attachError) throw new Error(attachError.message);
    if (attached !== true) {
      // someone else attached a session to this order in the meantime: use theirs
      const { data: row } = await admin.from("billing_orders").select("checkout_url").eq("id", order.id).maybeSingle();
      if (row?.checkout_url) return { ok: true, url: row.checkout_url as string, orderId: order.id };
      return { ok: false, error: MSG.generic };
    }
    return { ok: true, url: session.url!, orderId: order.id };
  } catch (e) {
    console.error("billing: could not create the XPay checkout session —", e instanceof XpayError ? `${e.status} ${e.code ?? ""} ${e.message}` : e);
    return { ok: false, error: e instanceof XpayError && e.status === 0 ? MSG.gatewayDown : MSG.generic };
  }
}

/** A fresh opaque id for logs; never used for money. */
export function newRequestId(): string { return randomUUID(); }
