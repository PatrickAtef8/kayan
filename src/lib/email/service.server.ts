import "server-only";
import { createAdminClient } from "@/lib/supabase/admin";
import { getSiteUrl } from "@/lib/site-url";
import { describeConfigProblem, isValidEmailAddress, loadEmailConfig } from "./config";
import { hashRecipient, maskEmail } from "./privacy";
import { renderTemplate, type Locale, type TemplateData, type TemplateName } from "./templates";
import { describeSendError, sendViaResend, type SendErrorCode } from "./transport";

/**
 * THE way Kayan sends email. Every transactional message (invitations, password reset, subscription reminders, payment notices)
 * goes through sendEmail(): one configuration, one set of templates, one log, one place that handles failures.
 *
 * What it guarantees
 *  - the sender comes from RESEND_FROM_EMAIL only (never hardcoded);
 *  - a missing / invalid configuration, an invalid recipient or any Resend error comes back as { ok: false, code, message } — it never throws;
 *  - with a dedupeKey the same template to the same person is sent at most once per key (race-safe, enforced by a unique index);
 *  - logs hold the template, a masked address and an error code — never the address, a link, a token, the subject or the body.
 */

export type SendResult =
  | { ok: true; id: string | null; skipped?: "duplicate" }
  | { ok: false; code: SendErrorCode; retryable: boolean; message: { ar: string; en: string } };

export type SendEmailInput<K extends TemplateName> = {
  template: K;
  to: string;
  data: TemplateData[K];
  locale?: Locale;
  /** Send this template to this recipient at most once per key (e.g. `renewal:${orgId}:${endsOn}:7d`). Put a time bucket in the key for "at most once per 10 minutes". */
  dedupeKey?: string;
  organizationId?: string | null;
};

const warned = new Set<string>();
function warnOnce(id: string, msg: string) {
  if (warned.has(id)) return;
  warned.add(id);
  console.warn(`[email] ${msg}`);
}

function fail(code: SendErrorCode, retryable = false): SendResult {
  return { ok: false, code, retryable, message: describeSendError(code) };
}

export function isEmailConfigured(): boolean {
  return loadEmailConfig().ok;
}

export async function sendEmail<K extends TemplateName>(input: SendEmailInput<K>): Promise<SendResult> {
  const to = String(input.to ?? "").trim().toLowerCase();
  if (!isValidEmailAddress(to)) return fail("invalid_recipient");

  const cfg = loadEmailConfig();
  if (!cfg.ok) {
    console.error(`[email] not sent (${input.template}): ${describeConfigProblem(cfg.problem)}`);
    return fail("not_configured");
  }

  let siteUrl: string | null = null;
  try { siteUrl = getSiteUrl(); } catch { /* the footer simply omits the site link */ }
  const rendered = renderTemplate(input.template, input.data, { locale: input.locale, siteUrl, supportEmail: process.env.KAYAN_SUPPORT_EMAIL?.trim() || cfg.config.replyTo });

  // --- claim the send (dedupe + audit trail). Best effort: if the log table is unreachable (migration 0071 not applied yet) we still send. ---
  let logId: string | null = null;
  let admin: ReturnType<typeof createAdminClient> | null = null;
  try {
    admin = createAdminClient();
  } catch {
    warnOnce("no-admin", "email log disabled: SUPABASE_SERVICE_ROLE_KEY is not set (duplicates cannot be prevented).");
  }
  if (admin) {
    try {
      const hash = hashRecipient(to);
      if (input.dedupeKey) {
        // a 'pending' row older than 15 minutes belongs to a send that crashed half-way: it must not block this key forever
        await admin.from("email_log").delete().eq("template", input.template).eq("dedupe_key", input.dedupeKey).eq("recipient_hash", hash).eq("status", "pending").lt("created_at", new Date(Date.now() - 15 * 60_000).toISOString());
      }
      const { data, error } = await admin.from("email_log").insert({
        template: input.template,
        recipient_hash: hash,
        recipient_masked: maskEmail(to),
        organization_id: input.organizationId ?? null,
        dedupe_key: input.dedupeKey ?? null,
        status: "pending",
      }).select("id").single();
      if (error) {
        if ((error as { code?: string }).code === "23505") return { ok: true, id: null, skipped: "duplicate" };
        warnOnce("log-insert", `email log unavailable (${(error as { code?: string }).code ?? "error"}) — apply migration 0071. Sending without duplicate protection.`);
      } else {
        logId = (data as { id: string }).id;
      }
    } catch {
      warnOnce("log-throw", "email log unavailable — sending without duplicate protection.");
    }
  }

  const result = await sendViaResend(cfg.config, {
    to,
    subject: rendered.subject,
    html: rendered.html,
    text: rendered.text,
    tags: [{ name: "template", value: input.template }],
  });

  if (logId && admin) {
    try {
      await admin.from("email_log").update(result.ok ? { status: "sent", provider_id: result.id, updated_at: new Date().toISOString() } : { status: "failed", error_code: result.code, updated_at: new Date().toISOString() }).eq("id", logId);
    } catch { /* the email result matters more than its log line */ }
  }

  if (result.ok) return { ok: true, id: result.id };
  console.error(`[email] failed template=${input.template} to=${maskEmail(to)} code=${result.code} status=${result.status ?? "-"} attempts=${result.attempts}`);
  if (result.code === "testing_sender_restricted" || result.code === "domain_not_verified") {
    warnOnce(`cfg-${result.code}`, `${result.code}: finish Resend domain verification and set RESEND_FROM_EMAIL (docs/EMAIL.md).`);
  }
  return fail(result.code, result.retryable);
}

/**
 * True when `template` was already sent (or is being sent) to this recipient in the last `minutes` minutes. Used BEFORE doing anything
 * with a side effect — e.g. an invitation re-generates the one-time link, so a second click must not issue a new link whose email is then skipped.
 * Returns false when the log is unavailable (the send itself is still protected by the rate limit).
 */
export async function hasRecentSend(template: TemplateName, to: string, minutes: number): Promise<boolean> {
  try {
    const admin = createAdminClient();
    const { data } = await admin
      .from("email_log")
      .select("id")
      .eq("template", template)
      .eq("recipient_hash", hashRecipient(to))
      .in("status", ["pending", "sent"])
      .gte("created_at", new Date(Date.now() - minutes * 60_000).toISOString())
      .limit(1);
    return !!data && data.length > 0;
  } catch {
    return false;
  }
}
