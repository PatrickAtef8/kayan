# Kayan — security review, round 3 (pre-production)

Scope: general application security and the payment path, on top of `SECURITY_AUDIT.md` / `SECURITY_AUDIT_V2.md`.
Not changed: package prices, limits, modules, business rules, the XPay integration and verification, the grace period, Super Admin and
the permanent Demo Company, no recurring billing. Nothing was deployed and no database was touched (a scratch PostgreSQL only).

## Fixed

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | **Critical** | `next` 16.3.8 is inside the vulnerable range of two critical advisories (unauthenticated RCE through the Image Optimization API with SVG input; Server Actions DoS) | `next` / `eslint-config-next` → 16.4.3 (same major). `npm audit`: 1 critical + 2 high → 0 / 0 |
| 2 | **High (functional)** | Migration 0069 created `ar_norm()` / `like_contains()` with **no grants**. Since 0030 removed the default EXECUTE on new functions, a signed-in user could not run them — and `ar_norm()` backs GIN indexes on customers / suppliers / products, so *inserting* a customer, supplier or product, and every search, failed | 0070 §1 |
| 3 | **High** | On a real Supabase project the default ACL grants ALL on every new table to `anon` **and** `authenticated`, silently voiding every narrower grant the migrations (and the test suite, which runs on bare PostgreSQL) assume: `anon` held full DML on ~53 tables, `authenticated` ~41 extra DELETE grants, TRUNCATE (which ignores RLS) everywhere, and the column-level UPDATE lists. RLS was the *only* barrier | 0070 §2: revoke exactly the excess (nothing a role needs is ever removed), re-assert the column-level grants, stop future tables inheriting ALL. The test stub now reproduces Supabase's default ACL so this class of bug is visible to the suite |
| 4 | Medium | `platform_pricing_config` is public (pricing page) but included `updated_by` = the Super Admin's auth user id | 0070 §3: column-level grant `(id, config, updated_at)` — the only columns the app reads |
| 5 | Medium | **No rate limiting anywhere** — payment starts (each calls XPay), the checkout return pages (poll XPay on every load), team invitations (send a real e-mail to any address) | 0070 §4 `rate_limit_hit()` (atomic, service-role only, per key and window) + `src/lib/rate-limit*.ts`; applied to checkout start (10 / 10 min / user), XPay verification (30 / min / company — past it the page keeps saying "verifying", never "failed") and invitations (30 / h / company). Fails open if the counter is unreachable (an outage must not stop a customer paying) and logs it |
| 6 | Medium | 44 server actions returned raw `error.message` (constraint / table / column names, English Postgres text) to the browser | `safeErrorMessage()` in `db-errors.ts`: Arabic business messages raised by the RPCs pass through, everything else becomes a generic sentence and the original is logged server-side |
| 7 | Low | Sign-out had no same-origin check and redirected with 307 (re-POSTs to `/login`) | `isSameOriginRequest()` (Origin, then Sec-Fetch-Site) + 303 |
| 8 | Low | `XPAY_API_BASE_URL` is where the **secret key** is sent, but was not validated | `validateXpayBaseUrl()`: https only, no credentials, `xpay.app` host in production (localhost http allowed outside production) |
| 9 | Low | Webhook buffered an oversized body before rejecting it | early `Content-Length` check (the post-read check stays) |
| 10 | Low | Enforced CSP was only `frame-ancestors` | also `base-uri 'self'; object-src 'none'` (cannot break a page). Full script/style policy stays Report-Only — see below |
| 11 | Build | `components/pricing/billing-actions.tsx` was dead code that no longer type-checked (imported a non-existent `retryOrder`), so `tsc` and `next build` failed | removed (nothing referenced it) |
| 12 | Tests | 8 stale tests (0055 / 0056 / 0066 changed behaviour on purpose; `money.ts` wraps amounts in bidi isolates by design; `notifications.ts` used an alias plain Node cannot resolve; the `auth.users` stub lacked 3 columns) | tests updated to the documented behaviour; one relative import |

Reviewed and found sound (no change): webhook signature (raw body, HMAC-SHA256, 5-minute replay window, constant-time compare, event
de-duplication), reconciliation (re-fetches the session from XPay, never trusts the webhook body), `billing_apply_payment` (row lock,
amount + currency check, idempotent — a replayed webhook or a return-page race activates once), service-role-only billing functions,
quote engine validation, the DB-level payment/grace gate, Super Admin (verified JWT, id allow-list, every action guarded), all 88 server
actions authenticate (authorisation is in RLS / permission functions), uploads (private bucket, 10 MB, MIME allow-list, org-folder RLS,
60 s signed URLs), legal-text rendering (text nodes only, URL scheme allow-list), no `dangerouslySetInnerHTML` / `eval` anywhere.

## Regression tests added

* `supabase/tests/120_security_hardening_v3_test.sql` — search helpers callable by `authenticated` only; anon can execute only
  `legal_current_versions` and hold only SELECT on the three public tables; nobody has TRUNCATE / REFERENCES / TRIGGER; every table has RLS;
  ledgers / audit log / invoices / billing rows refuse direct DML; a new table starts with no API privileges; `updated_by` unreadable;
  rate limiter: service-role only, counts, refuses, per-key, window reset, bad-argument rejection.
* `src/lib/security.test.ts` (in `npm run test:unit`) — rate-limit core, base-URL validation, same-origin check, safe error messages.

## Still open / needs a decision

* **Full CSP is Report-Only.** Enforcing `script-src` with `'unsafe-inline'` adds little; the proper fix is a nonce-based policy, which needs a
  real-browser pass (Next inline bootstrap, fonts, Supabase, the XPay redirect and `form-action`). Not done here.
* `/checkout/start` changes state on a GET (it clears the pending-package marker). Idempotent and low impact; left as is.
* A **test** XPay key in production would let anyone "pay" with a test card. Not blocked in code (it would change your current setup) —
  see manual step 4.
* The 16 remaining `npm audit` moderates are all ESLint-toolchain (`minimatch`), dev-only; npm's suggested "fix" is a downgrade to ESLint 4.
* No browser / end-to-end test was possible here; `next build` was verified with `--webpack` and a mocked font response only because the
  sandbox cannot reach Google Fonts.

## Manual steps before go-live

1. **Apply `0069` (if not yet) and `0070`** to the Supabase project, 0070 *with* or immediately after 0069. 0070 is idempotent and additive.
   After applying, this should return no row for `anon` other than the three public tables:
   `select table_name, privilege_type from information_schema.role_table_grants where grantee='anon' and table_schema='public';`
2. **Supabase → Authentication**: minimum password length ≥ 8 (10+ preferred) and leaked-password protection (if your plan has it);
   **require e-mail confirmation** (the Super Admin e-mail allow-list trusts the address — prefer `SUPER_ADMIN_USER_IDS`); (CAPTCHA: **leave OFF** until the forms send a `captchaToken` — see docs/SUPABASE_AUTH_SETTINGS.md); keep the Auth rate limits for sign-in / sign-up / OTP / e-mail at their defaults or tighter; restrict *Site URL* and the
   *Redirect URLs* allow-list to your domain. Password rules are enforced by Supabase Auth, not by this code.
3. Vercel env (server only): `SUPABASE_SERVICE_ROLE_KEY`, `XPAY_SECRET_KEY`, `XPAY_WEBHOOK_SECRET`, `BILLING_PRICES_CONFIRMED`,
   `SUPER_ADMIN_USER_IDS`. Nothing secret may use a `NEXT_PUBLIC_` name. Leave `XPAY_API_BASE_URL` unset unless XPay tells you otherwise.
4. **Production must use an `sk_live_…` key.** With a test key the checkout shows "test mode", but test sessions can be completed with a
   test card and would activate a licence.
5. Run `npm ci && npx tsc --noEmit && npx eslint . && npm run test:unit && npm run test:billing && npm run test:notifications && npm run test:db && npx next build`.
