# Performance audit notes

Measured on a local Postgres 16 with synthetic multi-tenant data (31 orgs,
100k invoices / 300k lines, one large org with 40k invoices). Absolute times
differ on Supabase; the ratios are what matter.

## What changed
- `0020_rls_membership_perf.sql` — RLS policies used `is_org_member(organization_id)`
  (SECURITY DEFINER, not inlinable → one call per scanned row). They now use
  `organization_id IN (SELECT user_org_ids())`, evaluated once per statement.
  Identical semantics. 613 ms → ~15 ms for a 120k-row count; list pages, balance
  views, dashboard and reports all get 10–40x faster. Covered by `tests/70_rls_membership_test.sql`.
- `0021_dashboard_totals.sql`
  - `dashboard_sales_totals()` sums in SQL instead of the dashboard downloading every
    invoice of the period (40k rows on "all time"). Profit is only returned to members
    with `view_financial`.
  - `dashboard_sales_rollups()` returns the trend chart, top customers and top reps in
    ONE pass, without the invoice-line scans `report_sales_breakdown` does for
    quantities the dashboard never shows. Verified row-for-row (incl. ordering) against
    the original function on 15 period/dataset combinations. All-time: 3,316 ms -> 116 ms
    (three calls -> one); this-year: 526 ms -> 48 ms.
  - `expenses (organization_id, created_at desc)` index.
  - Covered by `tests/80_dashboard_totals_test.sql`.
- `src/lib/org-context.ts` — per-request memoised user/membership so the layout and
  the page share one `auth.getUser()` + one membership query (React `cache`; nothing
  is cached across requests). Layout lookups now run in parallel; alert queries
  filter in SQL instead of pulling whole tables.
- Expenses list is paginated (20/page, like the other lists).
- `SearchBox` no longer pushes a navigation on mount (it re-rendered every list page
  on the server and reset `?page=N` to 1 on deep links).
- Bundle: Supabase browser client lazy-loaded in global search and attachments;
  framer-motion via `LazyMotion` (async feature load); `lenis` dynamically imported;
  unused `react-hook-form`, `zod`, `@hookform/resolvers` removed.
- Sales / purchase **returns** pages no longer ship every invoice to the browser for the
  picker. `AsyncSearchSelect` fetches the 30 most recent on open and searches by invoice
  number or customer/supplier name as you type (server actions, RLS-checked).
- **Navigation / action feedback (perceived performance)**
  - `loading.tsx` at `settings/`, `reports/`, `sales/`, `purchases/` as well as `dashboard/`.
    A loading boundary only re-triggers when the *child segment* changes, so the single
    dashboard-level one could not cover moving between sibling pages (settings tabs,
    report tabs, list <-> returns).
  - `NavigationProgress`: top progress bar + busy cursor + slightly dimmed content from the
    moment any internal link is clicked or `router.push` is called, until the new page is
    committed (12 s safety timeout so it can never stick). State lives in
    `lib/navigation-state.ts`.
  - Clicked tab / sidebar item highlights immediately (`usePendingPath`).
  - Report period dropdown and date-range inputs show the chosen value immediately instead
    of snapping back until the server answers.
  - Visible spinners/labels on inline actions that only disabled a control or showed
    nothing: module toggle, team member role/remove, role delete confirm, "other balances"
    remove, representative activate/deactivate, sign-out.
- `app/dashboard/loading.tsx` skeleton for instant navigation feedback.

## Deliberately not done
Load balancer, CDN, server-side/ISR caching of tenant data, extra pooling
(Supabase handles it), API compression (host already gzips), debouncing (already
present), image optimization (the app serves no images).

## Known remaining bottlenecks
- Each navigation still pays several sequential Supabase round trips (middleware session check, page auth check, membership lookup, page query). Feedback now hides this but doesn't remove it; see the auth-header option discussed in the audit.
- Dashboard "top products" (all time) is still ~420 ms at 40k invoices: it genuinely needs
  invoice-line data. Options: a bounded default period, or a monthly rollup table.
- Sales / purchase **entry forms** load the whole product and customer list, because
  price-tier logic runs client-side. Fixing that means an async product picker that keeps
  chosen products' price data in form state - do it together with an end-to-end
  click-test of invoice creation.
- `count: "exact"` is NOT a problem after 0020 (6 ms at 40k rows); an earlier estimate
  was measured before the RLS fix.
- (Resolved since: the project is on Next 16 / ESLint 9 with `eslint.config.mjs`.)

---

# Performance audit, round 2 (see CHANGES-performance-audit.md for the file-by-file list)

## What changed
- **Fewer sequential round trips per navigation**
  - `proxy.ts` + `org-context.ts`: `auth.getClaims()` replaces `auth.getUser()` for reads. With asymmetric JWT signing
    keys enabled on the Supabase project the token is verified locally (no Auth round trip, twice per page before);
    on a legacy shared-secret project the library falls back to `getUser()`, i.e. the old behaviour. Server actions
    that write still call `auth.getUser()`.
  - `dashboard/layout.tsx`: the role-dependent counters (`warehouse_pending_counts`, `stock_shortage_counts`) are now
    part of the same parallel batch instead of two awaits after it.
  - `org-context.ts`: per-request memoised `hasPermission`, `hasAnyPermission`, `getOwnRepId`, `getSalesLimits`.
    Sales, purchases, customers, suppliers, products and inventory pages ask for every permission inside their first
    `Promise.all` (they were awaited one RPC after another). Sales also fetches payments, returns and cost/profit in one batch.
- **No more "download everything and add it up"** (`0059_perf_balance_totals.sql`)
  - `dashboard_balance_totals()` gives receivable / payable / inventory value / treasury in one call (same views, same RLS).
  - `customer_balances_for(ids)` / `supplier_balances_for(ids)`: the customers and suppliers pages only aggregate the
    ≤20 parties on screen instead of the whole organization.
  - Inventory page is paginated (50/page, zero-quantity rows filtered in SQL) and its total comes from `inventory_value_total()`.
  - Purchases page reads the whole catalogue's costs with one `getAllProductCosts()` query (the old `.in(<all ids>)` URL
    overflowed for a few hundred products and silently fell back to cost 0).
  - Covered by `supabase/tests/111_perf_balance_totals_test.sql`.
- **Bulk imports** (`src/lib/bulk.ts`): customers / suppliers / products are inserted in chunks of 200 (one request per
  chunk, not per row); a refused chunk is retried row by row so each row keeps its own error message. (The import
  actions have no screen yet; they are ready for the Excel import.)
- **Sales entry form**: product / customer lookups are Maps and the option lists are memoised instead of being
  scanned and rebuilt for every invoice row on every render.

## Verified here
- `tsc --noEmit` and `eslint` clean; `next build` compiles (checked with a local font, since the sandbox cannot reach Google Fonts).
- Database suite: new `111` test passes; `80_dashboard_totals` and `101_dashboard_trend` fail identically BEFORE this
  work (tests written for an older signature of the trend functions) - they need updating separately.
- Client JS after build: ~3.1 MB raw / ~1.0 MB gzip over 82 chunks, of which the single largest (1.2 MB raw, the PDF
  renderer) loads only when a PDF export is clicked.

## Still open / to measure on the real deployment
- **Vercel function region vs Supabase region** (no `vercel.json` in the repo). Set the function region next to the
  database in the Vercel project settings; every remaining round trip pays that distance.
- Supabase API `max_rows` (default 1000): the sales/purchase entry forms still load the whole customer and product list.
  Replace with `AsyncSearchSelect`-style pickers together with an end-to-end invoice click-test (as noted above).
- `EXPLAIN (ANALYZE, BUFFERS)` of `customer_balances` / `supplier_balances` (still used by reports) and
  `dashboard_balance_totals` on the 100k-invoice seed; these views still aggregate the whole organization when asked for all parties.
- Re-check `getClaims()` after enabling asymmetric signing keys: layout TTFB should drop by one Auth round trip.
