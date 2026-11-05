# Kayan — Production Hardening Report

Date: 2026-11-04 · Input: `kayan_latest.zip` · Output: `kayan_production_ready.zip`

## Verdict — is Kayan production-ready?

**The code is in much better shape; Kayan is not yet ready to take real customers.** Several launch blockers are outside the code (your accounts, DNS,
dashboard settings, lawyer, real prices), and several new pieces have only been tested in isolation, never against live Resend / Supabase / XPay / Vercel.
Do not launch until the "Remaining blockers" list below is done and the post-deployment checks in `PRODUCTION_DEPLOYMENT_CHECKLIST.md` pass.

## Tests that actually ran (in the sandbox)

| Check | Result |
|---|---|
| `npx tsc --noEmit` | passed (exit 0) |
| `npm run lint` | passed, 0 problems |
| `npm test` — 193 unit tests (66 core incl. 3 Cairo-midnight, 88 billing/legal/reminders/XPay-guard, 12 notifications, 13 email, 14 platform) | all passed |
| `npm audit --omit=dev` | 0 vulnerabilities (the original lockfile also had 0; Sentry's Next.js package would have added 6, so I used the plain `@sentry/node` / `@sentry/browser` 10.78.0 instead) |
| SQL tests (`npm run test:db`) on a real PostgreSQL 16, 45 files incl. 4 new | all passed ("ALL DATABASE TESTS PASSED") |
| `npm run build` | passed **with a mocked Google Font** (the sandbox cannot reach fonts.googleapis.com; on Vercel the real font is fetched). The mock is a sandbox-only env var and is not in the ZIP |
| `next start` smoke test (fake Supabase env) | `/robots.txt`, `/sitemap.xml`, favicon route, nonce on all scripts, report-only CSP header, noindex header, cron route (401 / 500 / 405), export route (401 when signed out), `/dashboard/offers` redirects to login; `/api/health` returns 503 as expected with no database |

**Not run / not possible here:** anything against real Resend, Supabase Auth (`generateLink`, SMTP), XPay (live), Vercel Cron, Sentry ingest; a browser pass of the UI
(the new invoice-form pickers and the typed-name dialog are type-checked, built and covered by SQL tests of the search function, but **nobody has clicked them**); the
Playwright/UI e2e folder was not run; email rendering in real mail clients; CSP in a real browser.

## Issues by status

### Fixed
| # | Item | What was done |
|---|---|---|
| 1.1 | CAPTCHA docs | Contradiction removed: CAPTCHA stays **OFF** (no `captchaToken` is sent by any form); `docs/SETUP_AND_PUSH.md`, `SECURITY_AUDIT_V2/V3.md`, new `docs/SUPABASE_AUTH_SETTINGS.md` agree. |
| 1.2 | XPay | `sk_test_` refused in real production (Vercel previews excluded) at the single place keys are read; readiness report (key mode, webhook secret, `BILLING_PRICES_CONFIRMED`); admin home shows it. Manual renewal untouched; no recurring payments. |
| 1.3 | Large catalogues | Sales and purchase forms (customer, supplier, product, bonus product) use `AsyncSearchSelect` + server-side search (30 per query, Arabic-aware). SQL test proves records beyond #1000 are found in 1500-row catalogues. |
| 1.4 | Cairo time | 23 app files now use `cairoDate()`; migration 0071 adds `cairo_today()` and moves the two alert functions and ten date-column defaults onto it. Tested at winter/summer midnight in Node and SQL. |
| 1.5 | Error handling | Error boundaries (root, dashboard, admin, checkout) + `global-error.tsx`; Sentry via plain SDKs, off unless a DSN is set, scrubbed reports (no cookies/headers/query strings/emails). |
| 1.6 | Admin monitoring | `/admin/review`: `needs_review` orders across all companies, paginated (25), Super Admin only; count on admin home. |
| 1.7 | Company deletion | Exact typed name (checked on the server against the stored name); archive of audit log + billing orders + licence snapshot before deleting (migration 0072); Storage files removed *after* the database commit, bounded to the company's folder, failures reported with the folder to delete by hand; backup/PITR documented. |
| 2 | Email system | See below. |
| 3.1 | Multiple memberships | **Decision: single-company rule** (a switcher would touch ~33 files that assume the oldest membership). DB trigger refuses to activate a second membership; existing multi-company users are grandfathered. |
| 3.2 | Org creation limits | Validation trigger (name 1–120, country/currency/language shapes) + one-active-company rule; invitation rate limit existed. |
| 3.3 | Expiry reminders | Daily cron, Cairo-day thresholds (7/3/1/0 days, once after), once per cycle enforced by the database. |
| 3.4 | CSP | Nonce-based policy, **report-only** (verified that Next stamps the nonce on every script). Not enforced — checklist in `docs/SECURITY_HEADERS.md`. |
| 3.5–3.6 | SEO / indexing | Favicon, `robots.txt`, `sitemap.xml`, Open Graph/Twitter metadata, noindex (meta + header) on `/admin`, `/checkout`, `/dashboard`, API, auth. |
| 3.7 | `/api/health` | Added (up/down + DB status only). |
| 3.8 | Data export | Owner-only Excel workbook (Arabic, RTL, one sheet per record type, paged beyond 1000 rows, tenant columns and credentials omitted, rate-limited). Smoke-tested file generation; the route itself was **not** run against a database. |
| 3.9 | Offers | Hidden from sidebar/settings; page and setting return 404/refuse. |
| 5 | Housekeeping | Complete `.env.example`; README rewritten; password length docs corrected (code = 8); `npm test` added; ZIP excludes `.vercel/`, `node_modules/`, `tsconfig.tsbuildinfo`, `.next`. |

### Email system (Section 2) — what exists
`src/lib/email/`: config (sender only from `RESEND_FROM_EMAIL`, header-injection rejected), shared responsive RTL/LTR layout, 6 templates (team invite, existing-user invite, password reset,
subscription reminder, payment receipt, payment under review), a Resend transport (idempotency key, one retry, error mapping), a server service (log + once-only), privacy helpers.
Wired into: invitations (new + existing users), password reset (server action, no account enumeration, rate-limited), payment notifications (webhook + return page), reminders.
Supabase's own emails: branded templates generated from the same layout (`supabase/email-templates/`) + SMTP instructions in `docs/EMAIL.md`.
Fallback: without Resend configuration, invitations and reset use Supabase's emails so nothing breaks.

### Partially done
| Item | What is missing |
|---|---|
| Open Graph | Text metadata only — **no OG image** (needs brand artwork 1200×630). |
| Legal | Inventory done (`docs/LEGAL_OPEN_ITEMS.md`): 22 markers per language, 44 total, listed; missing company details, VAT, e-invoicing, Supabase region documented. **No legal text changed.** Privacy text does not yet list Resend/Sentry/archive. |
| Performance | Reviewed and documented; no risky change made. `getClaims()` benefit depends on your JWT signing keys (not checkable from here). Remaining full-list pickers: inventory transfer/stocktake, rep home (limit 1000), party-balance report (limit 500). |
| Auth emails via Resend | Templates and instructions ready; the SMTP switch is a Supabase dashboard action only you can do. |
| CSP | Report-only. |

### Deferred (not done)
* Company switcher (replaced by the single-company rule).
* CAPTCHA with `captchaToken` support.
* OG image; admin UI for the deletion archive and `email_log`.
* Converting the remaining full-list pickers (above).
* Retention policy / automatic cleanup for `email_log` and the deletion archive.
* Browser/e2e testing of the new UI.

## Behaviour changes you should know about
1. Invitations now create the account via the admin API and email a link to **your own** `/reset-password?token_hash=…` page; the email is sent by Resend. (Before: Supabase's invite email.)
2. Forgot-password is a server action; production never says whether an address exists.
3. A second active membership is refused by the database (message in Arabic) — e.g. accepting an invitation while already in a company.
4. `pricesConfirmed()` is no longer true for Vercel *preview* builds with `NODE_ENV=production`; it now treats only real production as live (previews may check out with placeholder prices and test keys).
5. Deleting a company now archives its audit log and payment records instead of discarding them. Test 118 still passes because live rows are still deleted.
6. `/dashboard/offers` is a 404.

## Files changed
60 new, 60 modified, none removed (full list: `CHANGED_FILES.txt` in the ZIP root). Highlights: `src/lib/email/*`, `src/lib/billing/{reminders,notify.server,xpay-guard}.ts`,
`src/app/api/{health,cron,export}`, `src/app/admin/review`, `src/app/dashboard/lookup-actions.ts`, `src/proxy.ts`, `supabase/migrations/0071–0072`, `supabase/tests/121–123`, `docs/*`.
Existing tests 20, 70, 112 were adapted: they deliberately create users who belong to several companies, which the new rule forbids, so they temporarily disable that one trigger.

## Required migrations (apply in order, to a **non-production** copy first)
`0071_cairo_time_and_email_log.sql`, then `0072_company_guards.sql`. Both additive and idempotent; neither modifies earlier migrations; **I did not run anything against production.**
Until 0071 is applied the email service still sends (it only loses duplicate protection). Until 0072 is applied, deletion still works with the typed name and file cleanup but
**nothing is archived** (the old behaviour) and the one-company/validation rules are not enforced — apply both before deploying the app.

## Required environment variables
See `.env.example`. New: `RESEND_API_KEY`, `RESEND_FROM_EMAIL`, `RESEND_REPLY_TO`, `KAYAN_SUPPORT_EMAIL`, `CRON_SECRET`, `SENTRY_DSN`, `NEXT_PUBLIC_SENTRY_DSN`.

## Remaining blockers (all need you)
1. Apply migrations 0071 + 0072 on staging, then production, in order.
2. **Domain + Resend verification**; until then invitations to anyone but your own Resend address will fail (testing sender). Set `RESEND_FROM_EMAIL`, Supabase custom SMTP, paste the auth templates.
3. XPay: live key, live webhook + `XPAY_WEBHOOK_SECRET`, **confirm real prices** and set `BILLING_PRICES_CONFIRMED=true`.
4. Supabase backups + PITR; one practised restore; decide a Storage backup approach.
5. Fill the legal identity/contact details, get the Egyptian lawyer's review, add Resend/Sentry to the privacy text, decide VAT/e-invoicing and the server region.
6. Pick Supabase and Vercel regions deliberately; check JWT signing keys.
7. A real browser pass of the invoice forms, invitations, password reset, payment, export, and the CSP console check.
8. `CRON_SECRET`, Super Admin IDs, Supabase Auth settings (`docs/SUPABASE_AUTH_SETTINGS.md`).
