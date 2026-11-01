// Minimal, dependency-free client for the parts of the XPay API Kayan uses (Hosted Checkout):
//   POST /checkout/sessions            create the payment page          (https://docs.xpay.app/en/integrate/checkout-session/overview)
//   GET  /checkout/sessions/:id        read it back — the authoritative payment status
//   POST /checkout/sessions/:id/expire close a session nobody should pay any more
// Writes carry an Idempotency-Key (https://docs.xpay.app/en/integrate/idempotency), which is what makes it safe to retry
// a request whose answer never arrived: XPay replays the first result instead of opening a second session.
//
// This file takes the secret key as a PARAMETER and is never imported by client components. The one place that reads the
// key from the environment is xpay.server.ts, which imports "server-only".

export type XpaySession = {
  id: string;
  status: "open" | "complete" | "expired";
  paymentStatus: "unpaid" | "paid" | "no_payment_required";
  amountTotal: number;
  currency: string;
  url: string | null;
  metadata: Record<string, string>;
  paymentIntentId: string | null;
  livemode: boolean | null;
};

export class XpayError extends Error {
  status: number;
  code: string | null;
  retryable: boolean;
  constructor(message: string, opts: { status: number; code?: string | null; retryable?: boolean }) {
    super(message);
    this.name = "XpayError";
    this.status = opts.status;
    this.code = opts.code ?? null;
    this.retryable = !!opts.retryable;
  }
}

export const SESSION_ID_PATTERN = /^cs_(test|live)_[A-Za-z0-9_-]+$/;

export type CheckoutBodyInput = {
  orderId: string;
  organizationId: string;
  siteUrl: string;
  currency: string;
  lines: { label: string; amount: number }[];
  expiresAfterMinutes?: number;
};

/** The exact JSON sent to POST /checkout/sessions. Amounts are integer piasters, as XPay expects (`unitAmount`). */
export function buildCheckoutSessionBody(input: CheckoutBodyInput) {
  const base = input.siteUrl.replace(/\/+$/, "");
  const order = encodeURIComponent(input.orderId);
  return {
    mode: "payment",
    uiMode: "hosted",
    submitType: "pay",
    locale: "ar",
    // Kayan's own result pages. Neither is proof of anything: they ask XPay (server to server) what happened to this order.
    afterCompletion: { type: "redirect", redirect: { url: `${base}/checkout/success?order=${order}` } },
    // a declined card / rejected 3-D Secure / the customer leaving XPay's page comes back here instead of staying on XPay's retry screen
    cancelUrl: `${base}/checkout/fail?order=${order}`,
    lineItems: input.lines.map((l) => ({
      priceData: { currency: input.currency, unitAmount: l.amount, productData: { name: l.label } },
      quantity: 1,
    })),
    expiresAfterMinutes: input.expiresAfterMinutes ?? 60,
    // metadata only ever holds our own opaque ids — no personal data, no secrets
    metadata: { order_id: input.orderId, organization_id: input.organizationId, app: "kayan" },
  };
}

/** Turns an XPay Checkout Session payload (API response or webhook `data.object`) into the few fields Kayan reads. */
export function parseSession(raw: unknown): XpaySession {
  const o = (raw ?? {}) as Record<string, unknown>;
  const status = o.status;
  const paymentStatus = o.paymentStatus;
  if (
    typeof o.id !== "string" || !SESSION_ID_PATTERN.test(o.id) ||
    (status !== "open" && status !== "complete" && status !== "expired") ||
    (paymentStatus !== "unpaid" && paymentStatus !== "paid" && paymentStatus !== "no_payment_required") ||
    typeof o.amountTotal !== "number" || !Number.isInteger(o.amountTotal) ||
    typeof o.currency !== "string"
  ) {
    throw new XpayError("XPay returned a checkout session in an unexpected shape", { status: 502, code: "invalid_response", retryable: true });
  }
  const meta: Record<string, string> = {};
  if (o.metadata && typeof o.metadata === "object") {
    for (const [k, v] of Object.entries(o.metadata as Record<string, unknown>)) if (typeof v === "string") meta[k] = v;
  }
  const pi = o.paymentIntent as { id?: unknown } | null | undefined;
  return {
    id: o.id,
    status,
    paymentStatus,
    amountTotal: o.amountTotal,
    currency: o.currency.toUpperCase(),
    url: typeof o.url === "string" ? o.url : null,
    metadata: meta,
    paymentIntentId: pi && typeof pi.id === "string" ? pi.id : null,
    livemode: typeof o.livemode === "boolean" ? o.livemode : null,
  };
}

export type XpayClientOptions = {
  secretKey: string;
  baseUrl?: string;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
  /** extra attempts after the first one (network error, timeout, 429, 409, 5xx) */
  retries?: number;
  sleep?: (ms: number) => Promise<void>;
};

export type XpayApi = {
  createCheckoutSession(body: ReturnType<typeof buildCheckoutSessionBody>, idempotencyKey: string): Promise<XpaySession>;
  getCheckoutSession(id: string): Promise<XpaySession>;
  expireCheckoutSession(id: string, idempotencyKey: string): Promise<void>;
};

export function createXpayClient(opts: XpayClientOptions): XpayApi {
  const baseUrl = (opts.baseUrl ?? "https://api.xpay.app").replace(/\/+$/, "");
  const doFetch = opts.fetchImpl ?? fetch;
  const timeoutMs = opts.timeoutMs ?? 15000;
  const retries = opts.retries ?? 2;
  const sleep = opts.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));

  async function call(method: "GET" | "POST", path: string, body?: unknown, idempotencyKey?: string): Promise<unknown> {
    let lastError: XpayError | null = null;
    for (let attempt = 0; attempt <= retries; attempt++) {
      if (attempt > 0) await sleep(Math.min(300 * 3 ** (attempt - 1), 3000));
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), timeoutMs);
      try {
        const res = await doFetch(`${baseUrl}${path}`, {
          method,
          headers: {
            Authorization: `Bearer ${opts.secretKey}`,
            "Content-Type": "application/json",
            Accept: "application/json",
            ...(idempotencyKey ? { "Idempotency-Key": idempotencyKey } : {}),
          },
          body: body === undefined ? undefined : JSON.stringify(body),
          signal: ctrl.signal,
          cache: "no-store",
        });
        const text = await res.text();
        let json: unknown = null;
        try { json = text ? JSON.parse(text) : null; } catch { /* non-JSON error page */ }
        if (res.ok) return json;
        const err = (json as { error?: { code?: unknown; message?: unknown } } | null)?.error;
        const retryable = res.status >= 500 || res.status === 429 || res.status === 409;
        lastError = new XpayError(
          typeof err?.message === "string" ? err.message : `XPay request failed (${res.status})`,
          { status: res.status, code: typeof err?.code === "string" ? err.code : null, retryable },
        );
        if (!retryable) throw lastError;
      } catch (e) {
        if (e instanceof XpayError && !e.retryable) throw e;
        lastError = e instanceof XpayError ? e : new XpayError("Could not reach XPay", { status: 0, code: "network_error", retryable: true });
      } finally {
        clearTimeout(timer);
      }
    }
    throw lastError ?? new XpayError("Could not reach XPay", { status: 0, code: "network_error", retryable: true });
  }

  return {
    async createCheckoutSession(body, idempotencyKey) {
      const s = parseSession(await call("POST", "/checkout/sessions", body, idempotencyKey));
      if (!s.url) throw new XpayError("XPay did not return a checkout URL", { status: 502, code: "invalid_response", retryable: true });
      return s;
    },
    async getCheckoutSession(id) {
      if (!SESSION_ID_PATTERN.test(id)) throw new XpayError("invalid session id", { status: 400, code: "invalid_session_id" });
      return parseSession(await call("GET", `/checkout/sessions/${encodeURIComponent(id)}`));
    },
    async expireCheckoutSession(id, idempotencyKey) {
      if (!SESSION_ID_PATTERN.test(id)) return;
      await call("POST", `/checkout/sessions/${encodeURIComponent(id)}/expire`, {}, idempotencyKey);
    },
  };
}
