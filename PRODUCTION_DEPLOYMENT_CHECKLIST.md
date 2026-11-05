# Kayan — Production Deployment Checklist

Work top to bottom. Tick only what you have actually done and seen. Nothing below was executed by me against your accounts.

## 0. Before anything
- [ ] Make a **backup / note the restore point** of the current production database (if one exists).
- [ ] Rehearse on a staging Supabase project + a Vercel preview first.

## 1. Supabase
- [ ] Create the project; choose the region deliberately (note it: ______). Put Vercel's function region next to it (`docs/PERFORMANCE.md`).
- [ ] **Migrations, in this order, no gaps:** `0001` … `0070` (as already deployed), then **`0071_cairo_time_and_email_log.sql`**, then **`0072_company_guards.sql`**. Do this **before** deploying the new app version.
  - Verify: `select cairo_today();` returns today's Cairo date; `select count(*) from email_log;` works; `select tgname from pg_trigger where tgname in ('zz_one_active_company','validate_organization');` returns 2 rows.
  - Existing users who already belong to two companies are unaffected (grandfathered).
- [ ] Authentication → Providers/Settings (`docs/SUPABASE_AUTH_SETTINGS.md`): Confirm email **ON**; minimum password length **8**; leaked-password protection if available; **CAPTCHA OFF**; Site URL = production URL; Redirect URLs = your domain(s).
- [ ] Authentication → Emails → **SMTP Settings**: Custom SMTP → host `smtp.resend.com`, port `465` (or `587`), user `resend`, password = Resend API key, sender = same address as `RESEND_FROM_EMAIL`.
- [ ] Authentication → Emails → **Templates**: paste the files from `supabase/email-templates/` and the subjects from `subjects.txt`.
- [ ] Project Settings → JWT Keys: note whether an asymmetric signing key is current (speed only; no action required).
- [ ] Database → **Backups** confirmed; **PITR** enabled; one restore rehearsed into a scratch project (`docs/BACKUP_AND_RECOVERY.md`).
- [ ] Storage: bucket `attachments` exists (private). Decide how files are backed up.
- [ ] Copy URL, anon key, **service role key** (server only).

## 2. Resend
- [ ] Create an account and an API key.
- [ ] **Now (no domain):** `RESEND_FROM_EMAIL=onboarding@resend.dev` — delivers only to your own Resend-account address. Test with that address only.
- [ ] **When you own a domain:** Resend → Domains → add it → add the DNS records at your DNS host → wait for **Verified** → change `RESEND_FROM_EMAIL` in Vercel to `no-reply@your-domain.com` → redeploy → change the Supabase SMTP sender to match. No code change.

## 3. XPay
- [ ] Create the **live** webhook for `https://YOUR-DOMAIN/api/webhooks/xpay`; copy its signing secret → `XPAY_WEBHOOK_SECRET`.
- [ ] `XPAY_SECRET_KEY` = the **`sk_live_…`** key. (A `sk_test_…` key is refused in production on purpose.)
- [ ] Confirm the **real prices** in `src/config/pricing.config.ts` against your offer; only then set `BILLING_PRICES_CONFIRMED=true`.
- [ ] Renewal is manual (no recurring charges) — make sure nobody promises otherwise on the site.

## 4. Vercel
- [ ] Import the repo; Node 22; set **every variable** from `.env.example` for *Production* (and test values for Preview): Supabase (3), `NEXT_PUBLIC_SITE_URL`, `RESEND_*`, `CRON_SECRET` (`openssl rand -hex 32`), XPay (3), `SUPER_ADMIN_USER_IDS`, optional Sentry DSNs.
- [ ] Function region = next to Supabase.
- [ ] Domain attached, HTTPS on; `NEXT_PUBLIC_SITE_URL` equals it exactly.
- [ ] `vercel.json` cron `/api/cron/subscription-reminders` shows under Settings → Cron Jobs (daily 07:00 UTC).
- [ ] Deploy. (The build downloads the Google font; it needs normal internet access.)

## 5. Legal (blocks launch)
- [ ] /admin/legal: company legal name, commercial register, tax card, address, contact number/email.
- [ ] Lawyer review of all 22 + 22 `[[REVIEW]]` items (`docs/LEGAL_OPEN_ITEMS.md`); VAT / e-invoicing decision; Supabase region stated; add Resend (and Sentry if used) to the privacy text. Only then tick "reviewed".

## 6. Post-deployment verification (do each; write the result)
- [ ] `GET /api/health` → 200 `{"status":"ok","db":"ok"}`. Add it to an uptime monitor.
- [ ] `GET /robots.txt`, `/sitemap.xml`; view-source of `/` shows OG tags; `/dashboard` response has `X-Robots-Tag: noindex`.
- [ ] Sign up a fresh test user → confirmation email arrives (branded, Arabic, RTL) → link works → company created → a **second** company with the same account is refused.
- [ ] Forgot password → email arrives → link → new password works. Unknown address shows the same message.
- [ ] Invite a sales rep **using your own Resend-account address** (testing sender) or any address (verified domain) → email arrives → set password → rep sees only own data. Re-adding the same address within 10 minutes is refused.
- [ ] Payment (a small real live payment, or XPay's live-mode test): redirect → return page → webhook marks paid → receipt email once → licence dates correct. A payment with a wrong amount lands in **/admin/review** and emails "under review".
- [ ] Cron: `curl -H "Authorization: Bearer $CRON_SECRET" https://YOUR-DOMAIN/api/cron/subscription-reminders` → JSON counts; no auth → 401.
- [ ] Invoice forms with a company that has >1000 customers/products: pickers find records past #1000.
- [ ] Owner downloads Settings → General → export; non-owner gets 403; file opens in Excel with Arabic intact.
- [ ] Admin → delete a **throw-away** company: wrong name is refused; right name deletes; check `company_deletion_archive`, `company_audit_archive`, and that its Storage folder is gone.
- [ ] Throw a test error (Sentry DSN set) and see it arrive scrubbed.
- [ ] Browser console on every main page: review `[Report Only]` CSP messages; fix; only then consider enforcing (`docs/SECURITY_HEADERS.md`).
- [ ] Cairo midnight: create an invoice between 00:00 and 03:00 Cairo time → its date is today's Cairo date.

## 7. Rollback
App: redeploy the previous Vercel deployment. Migrations 0071/0072 are additive: the old app keeps working with them applied (one caution: with 0072 applied the old app's "accept invitation into a second company" is refused — intended). Do not drop them.
