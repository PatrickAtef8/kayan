// Removes personal / secret data from an error report before it leaves the app. Pure, so it is unit-tested.
// Kayan's reports must carry stack traces and route names, never cookies, auth headers, e-mail addresses or form bodies.
type Event = { message?: unknown; request?: { cookies?: unknown; headers?: Record<string, unknown>; data?: unknown; query_string?: unknown }; user?: Record<string, unknown>; extra?: Record<string, unknown>; [k: string]: unknown };

const EMAIL = /[A-Za-z0-9._%+'-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
const TOKENISH = /\b(?:sk|pk|whsec|re|eyJ)[A-Za-z0-9_-]{16,}/g;

export function scrubText(s: string): string {
  return s.replace(EMAIL, "[email]").replace(TOKENISH, "[secret]");
}

export function scrubEvent<T extends Event>(event: T): T {
  if (event.request) {
    delete event.request.cookies;
    delete event.request.data;
    delete event.request.query_string;          // reset / invite links carry token_hash in the query string
    if (event.request.headers) for (const k of Object.keys(event.request.headers)) if (/^(cookie|authorization|x-.*key|xpay-signature)$/i.test(k)) delete event.request.headers[k];
  }
  if (event.user) event.user = event.user.id ? { id: event.user.id } : {};
  if (typeof event.message === "string") event.message = scrubText(event.message);
  const ex = (event as { exception?: { values?: { value?: string }[] } }).exception;
  for (const v of ex?.values ?? []) if (typeof v.value === "string") v.value = scrubText(v.value);
  return event;
}
