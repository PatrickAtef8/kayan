# Pricing, package selection and XPay payments

See `docs/BILLING.md` for design, configuration and the list of manual steps.

**Added:** `supabase/migrations/0060_billing_xpay.sql`; `supabase/tests/112_billing_test.sql`; `src/config/pricing.config.ts`;
`src/lib/billing/*`; `src/app/api/webhooks/xpay/route.ts`; `src/app/dashboard/billing/*`; `src/app/pricing/page.tsx`;
`src/components/pricing/*`; `src/components/dashboard/billing-banner.tsx`; `.env.example`; `docs/BILLING.md`.

**Changed (small):** `00_supabase_stub.sql` (adds the `service_role` role); marketing navbar/footer (Pricing link, `/#anchor` links so they work from
`/pricing`); dashboard sidebar (owner link «الباقة والمدفوعات»); dashboard layout (owner-only renewal banner);
audit entity labels; `package.json` (`test:billing`).

---
# Super Admin dashboard (`/admin`)

See `docs/SUPER_ADMIN.md`. **Added:** `supabase/migrations/0061_super_admin.sql`, `supabase/tests/113_super_admin_test.sql`,
`src/app/admin/*`, `src/components/admin/*`, `src/lib/admin/*`, `src/lib/billing/config.ts`, `docs/SUPER_ADMIN.md`.
**Changed (small, behaviour-preserving):** `src/lib/billing/pricing.ts` (override resolution appended), `/pricing`, `/dashboard/billing`
and `checkout.server.ts` read the live configuration (identical output while nothing is overridden), `PricingExperience` takes an
optional `packages` prop, billing page shows free (complimentary) licenses, `.env.example`, audit labels unchanged.
