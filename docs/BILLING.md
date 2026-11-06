> **Update:** Kayan now has exactly two plans (`one_time` and `monthly`) instead of three packages. See `CHANGES-two-plans.md`. References below to basic/professional/complete are historical.

# Pricing, packages and XPay payments

Everything the customer sees (`/pricing`, `/dashboard/billing`) and everything that is charged comes from **one file**:
`src/config/pricing.config.ts`. Change a price / limit / module / sentence of the terms there and redeploy.

## The packages — built only from what Kayan enforces today

A package is: **which optional modules may be switched on** + **how many active team members** + **how many active warehouses**.
These three are enforced by database triggers (migration `0060`), not just hidden in the menu. Everything else (products,
warehouses, reports, Excel/PDF export, attachments, search, audit log, the three roles) is identical in every package and
is listed once as "included in every package".

| | Basic | Professional | Complete |
|---|---|---|---|
| Modules | customers, suppliers, sales, purchases, inventory, expenses, treasury | + representatives (commissions, targets) | + partners |
| Team members | 3 | 10 | unlimited |
| Warehouses | 2 | 5 | unlimited |

`Offers` is not in any package: it is a placeholder page with no function yet (never gated).
**The prices in the file are placeholders** (see below).

## The two payment options

| | A — perpetual license | B — monthly subscription |
|---|---|---|
| Due today | license + first month of hosting & maintenance (`includeFirstHostingWithLicense`) | first month |
| Then | hosting & maintenance, per month, **billed separately** | the same monthly price (access + hosting + basic maintenance) |

## Recurring billing: what XPay does and does not support

XPay's Checkout Session documents `mode: "subscription"` as **"Not yet supported on the checkout API"**
(<https://docs.xpay.app/en/integrate/checkout-session/overview#mode>), and its API exposes no way to charge a saved card
later (Payment Intents are read-only). **So Kayan does not charge anything automatically and does not pretend to.**
Each month is a separate payment the owner starts from *Billing → Renew*. A paid month is added to the date the account is
already paid through, so renewing early loses nothing; a lapsed account renews from today. The UI says this plainly
(`terms.automaticRenewal = false`). When XPay ships recurring billing, the place to extend is `src/lib/billing/checkout.server.ts`.

## How a payment flows

1. Owner picks a package + option. The browser sends **only those two keys**. The server recomputes the amount
   (`buildQuote`) — a price from the browser is never read.
2. `billing_begin_order` (service role only) checks the caller is an active owner, that the organization **fits** the package
   (so nobody pays for a package they can't use), and that there is at most one open checkout (clicking twice resumes it).
3. The server creates an XPay Checkout Session (hosted page, Arabic) with `Idempotency-Key = order id`, and sends the
   customer there. The package is chosen on `/pricing` (or the billing page), then reviewed on Kayan's own **`/checkout`** page; only its
   *Continue to payment* button creates the order and goes to XPay. XPay returns the customer to **`/checkout/success`** after a
   completed checkout and to **`/checkout/fail`** when the card is declined or the customer leaves its page (the old
   `/dashboard/billing/return` only forwards to these two).
4. **Activation happens in exactly one function**, `billing_apply_payment`, reached from two places that both ask XPay
   for the session first (server → server, secret key) and never trust the browser or the webhook body:
   * the webhook `POST /api/webhooks/xpay` (HMAC-SHA256 signature, 5-minute replay window, raw body, event-id de-duplication);
   * the `/checkout/success` and `/checkout/fail` pages (so the customer sees the result even if the webhook is late).
     Reaching either URL, or any parameter on it, proves nothing and activates nothing.
5. It activates only if the session is `complete` **and** `paid` **and** the amount/currency equal the order. It is idempotent
   (row lock): repeated deliveries, a webhook racing the return page, or two tabs never grant twice.

| Situation | Behaviour |
|---|---|
| Declined card / 3-D Secure fails | `cancelUrl` → "not completed", retry button; nothing activated |
| Customer closes the tab | session expires (60 min) → `checkout.session.expired` closes the order |
| Fawry (pays later) | `completed` + `unpaid` → order stays open "confirming"; `async_payment_succeeded` activates |
| Duplicate webhook | skipped by event id; and even if replayed, activation is idempotent |
| XPay/DB unreachable during a webhook | HTTP 500, event **not** marked done → XPay retries and it is processed |
| Wrong amount reported | order closed `failed` + `needs_review`; nothing activated |
| Customer pays an old, superseded session | still honoured if the amount matches (money is never lost) |
| Second "initial" payment for an organization that already has a license | license not granted twice; paid time added; `needs_review` |

## What you must configure by hand

1. **Environment variables** (see `.env.example`): `XPAY_SECRET_KEY` (`sk_test_…`), `XPAY_WEBHOOK_SECRET` (`whsec_…`),
   `SUPABASE_SERVICE_ROLE_KEY`, `NEXT_PUBLIC_SITE_URL` (https in production; XPay rejects `localhost` in live mode).
2. **XPay dashboard → Developer → Webhooks**: add `https://<your-site>/api/webhooks/xpay` subscribed to
   `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `checkout.session.async_payment_failed`,
   `checkout.session.expired`; copy its `whsec_…` into `XPAY_WEBHOOK_SECRET`. Test and live have separate endpoints and secrets.
3. **Run migration `0060_billing_xpay.sql`** (additive; organizations without a license are untouched).
4. **Replace the placeholder prices and review the terms text** in `pricing.config.ts`, then set `BILLING_PRICES_CONFIRMED=true`.
   Until then, production checkout is closed (non-production is open). Also decide VAT: amounts are sent as shown, no VAT line.
5. Test with XPay's test card `5123 4500 0000 0008`, expiry `01/39` (<https://docs.xpay.app/en/get-started/test-mode>).

## Product decisions deliberately left to you

* **Changing package after buying** (upgrade/downgrade, proration) is not implemented: it is a pricing policy. The Billing page
  says to contact Kayan. An organization with a license cannot start a second "initial" purchase.
* Refunds are issued from the XPay dashboard; nothing in Kayan reverses a license automatically.

## The payment gate, the grace period and the checkout pages (migration 0063)

**One source of truth.** `organization_licenses.access_paid_through` — written only by `billing_apply_payment` after XPay's payment is
verified server-side (or by the Super Admin's free-access function) — judged by the **database clock** (`billing_access_state`).

| state | meaning | access |
|---|---|---|
| `none` | never paid | closed |
| `free` | complimentary access from the platform | open |
| `license_only` | a license with no end date | open |
| `active` | now ≤ paid-through | open |
| `grace` | paid-through < now ≤ paid-through + grace | open, with a persistent Arabic warning (time left + «جدّد الآن») |
| `expired` | now > paid-through + grace | **closed** until a renewal is verified |

The grace period is global and set by the Super Admin in **/admin/packages → فترة السماح** (on/off, hours, default 24, `0` = lock
immediately, max 720). It lives in `platform_billing_settings`, which browsers cannot read or write.

**Where it is enforced.** (1) The dashboard layout, on every page render. (2) **The database**: `user_org_ids()`, `is_org_member()`,
`has_permission()` and the permission-set helpers behind the balances / costs / financial tables now require an open subscription, and
every table policy and every RPC reaches one of them — so Server Actions, API routes and direct REST/RPC calls from a locked company see and
change nothing. Test 115 walks the live schema and fails if a new tenant table or org-scoped function does not reach the gate. Deliberately
outside it: the owner's own membership row, `organization_licenses` / `billing_orders` (read-only for the owner, so they can pay), the
caller's own notifications, and the public pricing tables. (3) Clients cannot write licenses, orders, settings or call the state
functions (SELECT-only / no grants). `platform_billing_settings.gate_enforced` is a SQL-only maintenance switch (default `true`); the test-suite sets
it to `false` because its fixtures create companies without licenses.

**Who is exempt.** A Super Admin *user* (`SUPER_ADMIN_USER_IDS`) is never gated and never charged. Their **demo company** gets free access (a
complimentary license, granted automatically the first time they open their own dashboard) so their demo team works; its members
follow that real subscription — revoke it in /admin and they are locked like anyone else. Being the owner does not exempt anyone else.

**A pending, failed, canceled, expired or unverified payment never restores access**; only `billing_apply_payment` (verified, matching
amount, idempotent) does, and it restores access immediately. A renewal is counted from the later of the old end date and now.

**Order states shown to the customer:** `paid` · `confirming` (may still arrive, or XPay unreachable) · `incomplete` (left XPay, session
still open, nothing charged, resumable) · `failed` · `canceled` · `expired`. XPay does not tell us *why* a customer returned to the cancel
URL, so that return is never reported as a failure by itself.

**What an order stores.** Package, option, purpose, currency, the exact lines and total (piasters), the entitlements and the months it
grants — copied at creation; a later price change only affects new orders. Taxes and discounts are not supported by the existing business
rules, so none are shown.

## Legal pages and the acceptance record (migrations 0064–0065)

`/terms`, `/privacy`, `/refund-policy` (Arabic RTL by default, `?lang=en` for English) and `/contact` are public and linked from the site
footer; the Super Admin edits the texts, the contact number and the company identity under **/admin/legal**. Every save is a new immutable
version (`legal_documents`). The checkout page requires a ticked checkbox for all three; the server compares the versions the page showed with
the database (a stale page is refused), and **before the customer is sent to XPay** records the versions, time, IP and user agent against the
order in `billing_order_acceptances` (append-only; the owner can read their own). No payment page is opened for an order without that record
(`startCheckout` requires it), and the old direct "retry" button is gone: a retry goes back through `/checkout`. See `docs/LEGAL_REVIEW.md`.

**Package chosen before signing up.** `/pricing` → `/signup?package=…&option=…` (validated on the server against the live packages; the price
shown is the server's quote) → after sign-up the browser goes to `/checkout` with the same package; if the email must be confirmed first, the choice
is kept in the account's metadata and `/checkout/start` uses it once after the first login. `/login?package=…` works the same way. Only a package key
and an option are ever carried; `/checkout` rebuilds the quote on the server.

## Safety for existing data

Migration `0060` only adds tables/functions/triggers. An organization with **no license row** is exactly as before. Limits apply
on the way in (switching on a module, activating a member/warehouse); nothing is disabled or deleted because of a package.
Before paying, an organization that already exceeds a package is told why and cannot pay for it.

## Tests

`npm run test:billing` (pricing, signature, XPay client + retries, webhook handler incl. duplicates/forgery/transient failure)
and `supabase/tests/112_billing_test.sql` (RLS, service-role-only functions, exactly-once activation, renewals, dedupe, limits).

## Modules come from the package (migration 0066)
Sign-up no longer asks for modules. The moment a license is created (verified payment or complimentary grant) the database switches on the
modules of its package; a later widening of the package switches the new ones on; nothing is ever switched off by a later change.
Settings → Modules shows modules outside the package locked. See `CHANGES-package-controls-modules.md`.

## Production guards (added in the hardening release)
* `XPAY_SECRET_KEY` starting with `sk_test_` is **refused in real production** (NODE_ENV=production and not a Vercel preview) — checkout and verification fail closed with a clear message. Preview deployments and local development may use test keys. Logic and tests: `src/lib/billing/xpay-guard.ts`.
* `XPAY_WEBHOOK_SECRET` must be set (the readiness report flags a missing or non-`whsec_` value); checkout stays closed in production until `BILLING_PRICES_CONFIRMED=true`.
* The Super Admin home shows a **production readiness** card (XPay mode, blockers, email configuration, payments needing review) and `/admin/review` lists orders with `needs_review` across all companies (paginated, Super Admin only).
* Payment emails: the owner gets one receipt per paid order (and one "under review" notice when an order is parked) — from the webhook or the return page, whichever records the payment first.
* **Renewal is manual.** Nothing here (or in the reminder emails) charges automatically; XPay recurring payments are not used.
* Subscription reminders: daily Vercel Cron (`vercel.json`) → `/api/cron/subscription-reminders`, authenticated with `CRON_SECRET`.

## Free trial and free hosting (migration 0074)
See `CHANGES-free-trial-and-free-hosting.md`. States added: `trial` (open) and `trial_expired` (closed). The trial applies only while a company has no license; hosting price 0 makes a perpetual license `license_only` (open, no end date).
