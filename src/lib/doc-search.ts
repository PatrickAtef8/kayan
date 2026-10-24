// Helpers for finding / opening one specific document (invoice).  Pure, so they are unit tested
// (`npm run test:unit`).
//
// Rule: a link that must open ONE invoice carries its id (`?inv=<uuid>`), never its number.  Numbers are for people to
// read and search; they are not unique across suppliers, can contain characters that break a URL, and a text search for
// "12" also finds "123".

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(v: unknown): v is string {
  return typeof v === "string" && UUID_RE.test(v);
}

/** The `inv` search param as a valid id, or null (anything else is ignored rather than sent to the database). */
export function invoiceParam(v: string | string[] | undefined): string | null {
  const s = Array.isArray(v) ? v[0] : v;
  return isUuid(s?.trim()) ? s!.trim().toLowerCase() : null;
}

/** What the user typed, as a LITERAL for ILIKE: "%" and "_" are not wildcards, "\" is not an escape. */
export function escapeLike(q: string): string {
  return q.replace(/[\\%_]/g, (c) => `\\${c}`);
}

/** `%…%` pattern for a literal contains-search. */
export function containsPattern(q: string): string {
  return `%${escapeLike(q)}%`;
}

export type InvoiceKind = "sales" | "purchase";

/** Where "open this invoice" leads (same shape the database builds for notifications). */
export function invoiceHref(kind: InvoiceKind, id: string): string {
  return `/dashboard/${kind === "sales" ? "sales" : "purchases"}?inv=${encodeURIComponent(id)}`;
}
