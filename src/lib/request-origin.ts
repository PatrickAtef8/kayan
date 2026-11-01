/**
 * Same-origin check for state-changing requests that arrive as a plain form POST (no CSRF token): sign-out.
 * A browser always sends Origin (or at least Sec-Fetch-Site) on a cross-site POST, so a request from another site is recognisable.
 * Pure (takes a Headers object) so it is unit-tested with plain Node.
 */
export function isSameOriginRequest(headers: Headers, requestUrl: string): boolean {
  const hosts = new Set<string>();
  const add = (h: string | null) => { const v = h?.split(",")[0]?.trim().toLowerCase(); if (v) hosts.add(v); };
  add(headers.get("host"));
  add(headers.get("x-forwarded-host"));
  try { hosts.add(new URL(requestUrl).host.toLowerCase()); } catch { /* an unparsable URL just adds nothing */ }

  const origin = headers.get("origin");
  if (origin) {
    if (origin === "null") return false;
    try { return hosts.has(new URL(origin).host.toLowerCase()); } catch { return false; }
  }
  // no Origin (some older clients): fall back to Fetch Metadata, which a browser sets and a page cannot forge
  const site = headers.get("sec-fetch-site");
  if (site) return site === "same-origin" || site === "none";
  return true; // neither header: not a browser cross-site request (curl / server-to-server) — the session cookie is still required
}
