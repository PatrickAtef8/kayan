// Content-Security-Policy with a per-request nonce. Pure: the proxy calls it, the tests pin it.
//
// Status: shipped in REPORT-ONLY mode (nothing is blocked; violations are only reported to the browser console). Do NOT switch it to
// enforcing until docs/SECURITY_HEADERS.md's browser checklist has been run on the real deployment — a missed origin would break pages.
//
// 'strict-dynamic' lets the nonce'd Next.js bootstrap load its own chunks, so no 'unsafe-inline' for scripts is needed. Styles keep
// 'unsafe-inline' (Next/Tailwind inject style attributes; style injection is a far smaller risk than script injection).

export function generateNonce(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

export function buildCsp(opts: { nonce: string; supabaseUrl?: string; isDev?: boolean; extraConnect?: string[] }): string {
  const supa = (opts.supabaseUrl ?? "").trim().replace(/\/+$/, "");
  const ws = supa.replace(/^http/, "ws");
  const connect = ["'self'", supa, ws, ...(opts.extraConnect ?? [])].filter(Boolean).join(" ");
  return [
    "default-src 'self'",
    `script-src 'self' 'nonce-${opts.nonce}' 'strict-dynamic'${opts.isDev ? " 'unsafe-eval'" : ""}`,
    "style-src 'self' 'unsafe-inline'",
    `img-src 'self' data: blob:${supa ? ` ${supa}` : ""}`,
    "font-src 'self' data:",
    `connect-src ${connect}`,
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "object-src 'none'",
  ].join("; ");
}
