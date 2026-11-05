# Content-Security-Policy (nonce-based) and robots

## State today
* Enforced (next.config.mjs): `frame-ancestors 'none'; base-uri 'self'; object-src 'none'`, HSTS, nosniff, referrer policy, permissions policy, `X-Frame-Options`.
* **Report-Only** (src/proxy.ts → src/lib/security/csp.ts): a full policy with a **per-request nonce** + `'strict-dynamic'` for scripts. Nothing is blocked; violations only appear in the browser console.
  It is **not enforced and must not be until the checklist below passes on the real deployment.**
* `X-Robots-Tag: noindex, nofollow, noarchive` on `/admin`, `/dashboard`, `/checkout`, `/api`, `/auth`, `/reset-password`; the layouts also carry `<meta robots noindex>`; `robots.txt` disallows them.

## Before enforcing (browser pass, on the deployed site, with DevTools console open)
1. Visit: landing, pricing, login, signup, forgot/reset password, dashboard home, an invoice form, a report page, settings, an Excel export, a PDF export, checkout → XPay → return, /admin.
2. In the console, look for `[Report Only] Refused to …` messages. Each one names a blocked origin/directive.
3. Typical items to add: the Sentry ingest host (already added to `connect-src` when `NEXT_PUBLIC_SENTRY_DSN` is set), XPay hosted-page origin if it is embedded (the app redirects, so likely none), Supabase Storage image origin (already `NEXT_PUBLIC_SUPABASE_URL`).
4. When the console is clean for a full pass: in `src/proxy.ts` change the two `content-security-policy-report-only` names to `content-security-policy` and redeploy. Keep a one-line revert ready.
5. Known caveat: nonces require pages to be rendered dynamically per request. Kayan's pages already read cookies/sessions; the static public pages may get the nonce only when rendered dynamically — verify the landing page in step 1 specifically.
6. `style-src` keeps `'unsafe-inline'` (Tailwind / Next inject style attributes). `script-src` has no `'unsafe-inline'`.
