# Email (Resend)

Every email Kayan sends goes through **one service** (`src/lib/email/`) and **one set of templates**, so invitations, password resets,
reminders and receipts look like one product. Nothing was tested against a live Resend account while this was built (see
"What has and has not been verified" at the bottom).

## What sends what

| Email | Sent by | Template (`src/lib/email/templates.ts`) |
|---|---|---|
| Sales rep / warehouse custodian invitation — new person | app (Resend API) | `team_invite` |
| Invitation — person who already has an account | app (Resend API) | `team_invite_existing` |
| Password reset | app (Resend API) | `password_reset` |
| Payment confirmed / payment needs review | app, from the XPay webhook and the return page (once per order) | `payment_receipt`, `payment_needs_review` |
| Subscription expiry reminders (7, 3, 1 days before, on the day, once after) | daily Vercel Cron → `/api/cron/subscription-reminders` | `subscription_reminder` |
| Sign-up confirmation, magic link, email-change, re-authentication | **Supabase Auth** (it sends these itself) → goes out through Resend **SMTP** | generated HTML in `supabase/email-templates/` |

Renewal is **manual**. Reminder emails only link to the billing page; nothing is charged automatically (XPay recurring payments are not used).

## Environment variables

| Name | Meaning |
|---|---|
| `RESEND_API_KEY` | Resend API key. Server only. |
| `RESEND_FROM_EMAIL` | The sender: `no-reply@your-domain.com` or `Kayan <no-reply@your-domain.com>`. **Required; never hardcoded.** |
| `RESEND_REPLY_TO`, `KAYAN_SUPPORT_EMAIL` | Optional reply-to / footer support address. |
| `NEXT_PUBLIC_SITE_URL` | Base of every link in the emails. |
| `CRON_SECRET` | Authenticates the reminder cron. |

## Right now: no domain yet (testing sender)

1. Create a Resend account, create an API key.
2. Set `RESEND_API_KEY` and `RESEND_FROM_EMAIL=onboarding@resend.dev`.
3. **Limitation that matters:** Resend's shared testing sender (`@resend.dev`) delivers **only to the email address of your own Resend account**.
   Inviting a real sales rep or warehouse custodian will fail with a clear error (the invitation is recorded, the owner is told the email could not be
   sent and can add the same address again later to resend). For a test, invite *your own* Resend-account address.
4. The admin dashboard home shows "مرسل اختبار" while the testing sender is configured.

## After you buy a domain (no code change)

1. Resend → **Domains** → add your domain → add the DNS records Resend shows (SPF/DKIM, and DMARC as Resend recommends) at your DNS provider → wait for "Verified".
2. Vercel → Environment Variables → set `RESEND_FROM_EMAIL=no-reply@your-domain.com` (or `Kayan <no-reply@your-domain.com>`) → **redeploy**.
3. Supabase SMTP sender (below): change *Sender email* to the same address.
4. Send yourself a test invitation and a password reset. Check spam placement and the rendering of the Arabic template in Gmail, Outlook and a phone.

## Supabase Auth emails through Resend SMTP (dashboard — cannot be done from code)

Supabase sends sign-up confirmation (and magic link / email change) itself. Route them through Resend so they use your sender and are not
subject to Supabase's built-in email limits:

Supabase → **Authentication → Emails → SMTP Settings** → enable **Custom SMTP**:

| Field | Value |
|---|---|
| Host | `smtp.resend.com` |
| Port | `465` (SSL) — or `587` (STARTTLS) |
| Username | `resend` |
| Password | your Resend API key |
| Sender email | the same address as `RESEND_FROM_EMAIL` (must be on your verified domain; with the testing sender, `onboarding@resend.dev`) |
| Sender name | `Kayan | كيان` |

Then **Authentication → Emails → Templates**: paste each file from `supabase/email-templates/` into the matching template and use the subject in
`subjects.txt` (regenerate with `node --experimental-strip-types scripts/gen-auth-email-templates.mjs` if you change the brand in `layout.ts`):

| Supabase template | File |
|---|---|
| Confirm signup | `confirm-signup.html` |
| Invite user | `invite.html` (the app normally sends invitations itself; this is the fallback) |
| Magic link | `magic-link.html` |
| Change email address | `email-change.html` |
| Reset password | `recovery.html` (fallback if Resend is not configured) |
| Reauthentication | `reauthentication.html` |

The links use `{{ .SiteURL }}`, so **Authentication → URL Configuration → Site URL must be your production address** and your domain must be in the Redirect URLs allow-list.
Keep **Confirm email** ON. Keep **CAPTCHA** OFF (see `docs/SUPABASE_AUTH_SETTINGS.md`).

## How the invitation / reset links work

The app asks Supabase Auth for a one-time token (`auth.admin.generateLink`, which creates the invited account **without sending anything**), then emails a link
to **its own** page: `/reset-password?token_hash=…&type=invite|recovery`. Nothing is consumed until the browser runs that page, so mail scanners that pre-open
links cannot burn the token. The page already handled `token_hash` links before this change.

If `RESEND_API_KEY`/`RESEND_FROM_EMAIL` are missing, invitations and password reset **fall back to Supabase's own emails** (so the product keeps working), and the
admin home shows the email configuration problem.

## Failure handling

* Invalid recipient → refused before calling Resend. Missing/invalid configuration, wrong key, unverified domain, testing-sender restriction, rate limit, timeouts and
  5xx are all mapped to a plain Arabic message for the person who clicked; retryable failures are retried once with the **same idempotency key** (no double email).
* **No duplicates:** an invitation / reset to the same address within 10 / 2 minutes is refused before a new link is issued (a new link would invalidate the old one);
  receipts and reminders use a database-enforced once-per-key rule (`email_log`, migration 0071).
* **Logs** contain the template name, a masked address (`j***@e***.com`), a status code. Never the address, link, token, subject or body. The `email_log` table stores a
  SHA-256 of the address plus the masked form.
* Password reset answers identically whether or not the account exists (no account enumeration); delivery problems are shown only outside production.

## What has and has not been verified

Verified by automated tests: template rendering (Arabic RTL + English, escaping, link safety), configuration parsing (sender never hardcoded, header-injection rejected),
the Resend request shape / retry / error mapping (against a fake `fetch`), reminder timing on Cairo calendar days, the log/dedupe table (database tests).

**Not verified** (needs your credentials): an actual delivery through Resend, Supabase `generateLink` behaviour in your project, the SMTP integration, rendering in real mail clients.
Do the post-deployment checks in `PRODUCTION_DEPLOYMENT_CHECKLIST.md` before relying on it.
