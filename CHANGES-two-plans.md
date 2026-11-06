# Two plans instead of three packages

There are exactly two plans, and a plan is a way of paying:
- `one_time` — perpetual license (paid once) + hosting & maintenance (monthly, separate)
- `monthly`  — one all-inclusive monthly price

Each has its own prices, member/warehouse limits and modules, edited by the Super Admin under /admin/packages. Both are always on sale.

## Changed
- `src/config/pricing.config.ts`: two plans (`one_time`, `monthly`); shipped defaults are placeholders (all modules, unlimited limits).
- `src/lib/billing/pricing.ts`: `buildQuote({ plan, purpose })` — only the plan comes from the browser; validation requires both plans; editable prices are per plan.
- `src/lib/billing/selection.ts`: `?plan=…`; old `package=…&option=…` links and saved metadata still resolve to the plan.
- /pricing, /checkout, /dashboard/billing, sign-up, login, admin package editor, admin actions, tests.
- Old admin price overrides (keys basic/professional/complete) match no plan and are ignored: re-enter the two plans' prices once.

## Migration `0073_two_plans.sql` (run BEFORE deploying the code)
Re-keys licenses and orders to their payment option (entitlements untouched), adds `package_key = payment_option` check constraints, makes free access the `one_time` plan. Idempotent.

## Verified
tsc, eslint, unit tests, full database suite (+ `124_two_plans_test.sql`), migration on legacy data, production build (Google Fonts mocked in the sandbox).
