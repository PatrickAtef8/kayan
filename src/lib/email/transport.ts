// Talks to Resend's REST API (POST https://api.resend.com/emails). No SDK: one fetch call, fully testable with a fake `fetch`.
// Nothing here logs, and nothing it returns contains the API key, the recipient or the message body.

import type { EmailConfig } from "./config.ts";

export type SendErrorCode =
  | "not_configured"      // RESEND_API_KEY / RESEND_FROM_EMAIL missing or malformed
  | "invalid_recipient"   // the address is malformed or Resend refused it
  | "testing_sender_restricted" // resend.dev sender: Resend only delivers to the account owner's own address
  | "domain_not_verified" // the sender's domain is not verified in Resend
  | "invalid_api_key"     // wrong / revoked / restricted key
  | "rate_limited"        // Resend said "slow down"
  | "provider_error"      // Resend 5xx / unexpected answer
  | "network_error"       // timeout / DNS / connection failure
  | "invalid_request";    // anything else Resend rejected (4xx)

export type TransportResult =
  | { ok: true; id: string | null; attempts: number }
  | { ok: false; code: SendErrorCode; retryable: boolean; status: number | null; attempts: number };

export type OutgoingMessage = { to: string; subject: string; html: string; text: string; headers?: Record<string, string>; tags?: { name: string; value: string }[] };

export type FetchLike = (url: string, init: { method: string; headers: Record<string, string>; body: string; signal?: AbortSignal }) => Promise<{ ok: boolean; status: number; json: () => Promise<unknown> }>;

export const RESEND_ENDPOINT = "https://api.resend.com/emails";

/** Maps a Resend error response onto one of our codes. Resend documents `statusCode`, `name` and `message` in the body. */
export function classifyResendError(status: number, body: unknown): { code: SendErrorCode; retryable: boolean } {
  const b = (body ?? {}) as { name?: unknown; message?: unknown };
  const name = typeof b.name === "string" ? b.name.toLowerCase() : "";
  const message = typeof b.message === "string" ? b.message.toLowerCase() : "";

  if (status === 429 || name === "rate_limit_exceeded" || name === "daily_quota_exceeded" || name === "monthly_quota_exceeded") return { code: "rate_limited", retryable: status === 429 && name === "rate_limit_exceeded" };
  if (status >= 500) return { code: "provider_error", retryable: true };
  if (message.includes("testing emails to your own email") || message.includes("only send testing emails")) return { code: "testing_sender_restricted", retryable: false };
  if (message.includes("domain is not verified") || message.includes("not verified")) return { code: "domain_not_verified", retryable: false };
  if (status === 401 || name.includes("api_key") || name === "restricted_api_key") return { code: "invalid_api_key", retryable: false };
  if (status === 403 && name === "validation_error") return { code: "domain_not_verified", retryable: false };
  if (status === 422 || status === 400) {
    if (message.includes("to") && (message.includes("email address") || message.includes("invalid"))) return { code: "invalid_recipient", retryable: false };
    return { code: "invalid_request", retryable: false };
  }
  return { code: "invalid_request", retryable: false };
}

export async function sendViaResend(
  config: Pick<EmailConfig, "apiKey" | "from" | "replyTo">,
  msg: OutgoingMessage,
  opts: { fetchImpl?: FetchLike; timeoutMs?: number; maxAttempts?: number; idempotencyKey?: string; sleep?: (ms: number) => Promise<void> } = {},
): Promise<TransportResult> {
  const doFetch: FetchLike = opts.fetchImpl ?? ((url, init) => fetch(url, init) as ReturnType<FetchLike>);
  const maxAttempts = Math.max(1, Math.min(3, opts.maxAttempts ?? 2));
  const sleep = opts.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  // One key for every attempt of THIS send: if the first request reached Resend but its answer was lost, the retry cannot create a second email.
  const idempotencyKey = opts.idempotencyKey ?? globalThis.crypto.randomUUID();

  const body = JSON.stringify({
    from: config.from,
    to: [msg.to],
    subject: msg.subject,
    html: msg.html,
    text: msg.text,
    ...(config.replyTo ? { reply_to: config.replyTo } : {}),
    ...(msg.headers ? { headers: msg.headers } : {}),
    ...(msg.tags ? { tags: msg.tags } : {}),
  });

  let last: TransportResult = { ok: false, code: "network_error", retryable: true, status: null, attempts: 0 };
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), opts.timeoutMs ?? 10_000);
    try {
      const res = await doFetch(RESEND_ENDPOINT, {
        method: "POST",
        headers: { Authorization: `Bearer ${config.apiKey}`, "Content-Type": "application/json", "User-Agent": "kayan-app/1.0", "Idempotency-Key": idempotencyKey },
        body,
        signal: controller.signal,
      });
      let json: unknown = null;
      try { json = await res.json(); } catch { /* an empty or non-JSON body is handled below */ }
      if (res.ok) {
        const id = json && typeof (json as { id?: unknown }).id === "string" ? (json as { id: string }).id : null;
        return { ok: true, id, attempts: attempt };
      }
      const c = classifyResendError(res.status, json);
      last = { ok: false, code: c.code, retryable: c.retryable, status: res.status, attempts: attempt };
    } catch {
      last = { ok: false, code: "network_error", retryable: true, status: null, attempts: attempt };
    } finally {
      clearTimeout(timer);
    }
    if (!last.ok && !last.retryable) return last;
    if (attempt < maxAttempts) await sleep(400 * attempt);
  }
  return last;
}

/** Plain-language messages for the person who triggered the send. Never contain the key, the recipient or a link. */
export function describeSendError(code: SendErrorCode): { ar: string; en: string } {
  switch (code) {
    case "not_configured": return { ar: "خدمة البريد الإلكتروني غير مُهيّأة بعد. يرجى التواصل مع مسؤول النظام.", en: "The email service is not configured yet. Please contact the system administrator." };
    case "invalid_recipient": return { ar: "عنوان البريد الإلكتروني غير صالح أو مرفوض.", en: "The email address is invalid or was rejected." };
    case "testing_sender_restricted": return { ar: "مرسل الاختبار في Resend يسلّم فقط إلى بريد حساب Resend نفسه. اربط نطاقًا موثقًا وغيّر RESEND_FROM_EMAIL لإرسال الرسائل لأي شخص.", en: "Resend's testing sender only delivers to the Resend account's own address. Verify a domain and change RESEND_FROM_EMAIL to email anyone." };
    case "domain_not_verified": return { ar: "نطاق المرسل غير موثق في Resend. أكمل توثيق النطاق ثم أعد المحاولة.", en: "The sender domain is not verified in Resend. Finish domain verification and try again." };
    case "invalid_api_key": return { ar: "مفتاح Resend غير صالح أو ملغي. راجع RESEND_API_KEY.", en: "The Resend API key is invalid or revoked. Check RESEND_API_KEY." };
    case "rate_limited": return { ar: "تم تجاوز حد الإرسال مؤقتًا. حاول بعد قليل.", en: "The sending limit was temporarily exceeded. Try again shortly." };
    case "network_error": return { ar: "تعذّر الوصول إلى خدمة البريد الآن. حاول مرة أخرى بعد قليل.", en: "The email service could not be reached. Please try again shortly." };
    case "provider_error": return { ar: "خدمة البريد تواجه مشكلة مؤقتة. حاول مرة أخرى بعد قليل.", en: "The email service is having a temporary problem. Please try again shortly." };
    case "invalid_request": return { ar: "رفضت خدمة البريد هذه الرسالة. تواصل مع الدعم إن تكرر الأمر.", en: "The email service rejected this message. Contact support if it keeps happening." };
  }
}
