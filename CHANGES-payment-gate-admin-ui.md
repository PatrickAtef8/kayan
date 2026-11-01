# Checkout flow, payment gate, grace period, admin account

## Deployment order (nothing here is run for you)
1. Back up the database.
2. Run, in this order: `0062_payment_gate.sql`, `0063_checkout_grace_gate.sql`, `0064_legal_documents_acceptance.sql`, `0065_legal_documents_seed.sql`
   (all additive/replace-only; 0065 is idempotent and generated from `src/config/legal.defaults.ts` by `scripts/gen-legal-seed.mjs`).
   0063 requires 0060-0062. It redefines `user_org_ids`, `is_org_member`, `has_permission` and five permission-set helpers
   (patched from their live definitions, with a self-check that exactly five were patched).
3. Deploy the application. Set `SUPER_ADMIN_USER_IDS` (see `.env.example`), sign in once with that account.
4. Optional, manual, destructive: `supabase/repairs/0062_remove_ownerless_companies.sql` (preview first).
Deploying the code before 0063 makes the dashboard show "could not verify the subscription" (fails closed); it never opens by mistake.

## What changed
* `/checkout` (order page) → XPay → `/checkout/success` / `/checkout/fail`; `/dashboard/billing/return` only forwards. `/pricing`
  and the billing page's package chooser now lead to `/checkout`; renewals too.
* Payment gate in the dashboard layout **and in the database**; configurable grace period (Super Admin) with a persistent Arabic
  warning; admin account exempt; demo company follows its real (free) subscription. Admin pages show the database's access state.
* Admin «الأسعار» page: customer-view features table, prices editable, grace-period card.

## Files
Migrations: `0062_payment_gate.sql`, `0063_checkout_grace_gate.sql`. Repair (manual): `supabase/repairs/0062_...sql`.
New: `src/app/checkout/**`, `src/components/pricing/{checkout-button,result-shell,feature-matrix}.tsx`,
`src/components/dashboard/{paywall,grace-banner}.tsx`, `src/components/admin/{admin-switcher,grace-settings}.tsx`,
`src/lib/billing/{access-gate,checkout-state,checkout-context.server,order-view.server,complimentary}.ts`.
Changed: dashboard layout/shell/topbar/sidebar, billing page + actions, `xpay-client.ts` (return URLs), `license-status.ts`,
`pricing.config.ts` (grace config removed; optional `legal` links), admin pages/actions/format, middleware (`/checkout` needs login,
`x-kayan-path` header), `.env.example`, docs.

## Tests
`npm run test:billing` (60). Database: `supabase/tests/114_payment_gate_test.sql`, `115_grace_gate_test.sql` (grace boundaries, renewals,
failed/pending/canceled payments, direct-request bypass, admin-demo-company, schema walk). Known old failures that fail identically
without these changes: `money.test.ts` (4) and DB tests 80/101.

## Needs live Supabase / XPay to verify
Sign-up → pay → dashboard with real XPay test cards; the XPay webhook; the cancel-URL behaviour (XPay does not document whether
leaving its page also fires `checkout.session.expired`); email-based admin allow-list; Server Actions through a real session.
Limitation: selecting a package while signed out goes to /signup and the selection is not carried through sign-up.

## Round 3: signup selection + legal pages
* **Package through signup:** `/pricing` → `/signup?package&option` (server-validated, server price) → `/checkout`; also through email confirmation (`/checkout/start`) and `/login?package&option`.
  `src/lib/billing/selection.ts`; tests in `src/lib/legal/legal.test.ts`.
* **Legal pages:** `/terms`, `/privacy`, `/refund-policy`, `/contact` (ar/en), footer links, admin editor `/admin/legal` (versioned, contact number, "reviewed by lawyer" flag),
  drafts + review list in `docs/LEGAL_REVIEW.md`.
* **Checkout acceptance:** required checkbox; versions + time + IP + user agent stored against the order (`billing_order_acceptances`); `retryOrder` and `PayButton` removed (retry goes through `/checkout`).
* **Unchanged:** prices, limits, modules, payment verification, grace-period rules, Super Admin and demo-company access, no recurring billing.
* **Tests:** unit 78 (`npm run test:billing`); DB `116_legal_acceptance_test.sql` (49) and the updated `115`; `next build --webpack` passes with the Google font mocked (the sandbox is offline).
