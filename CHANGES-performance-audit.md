# Performance audit — implemented changes

| Area | Files |
|---|---|
| Auth: local JWT verification (`getClaims`) | `proxy.ts` (via `src/lib/supabase/middleware.ts`), `src/lib/org-context.ts` |
| Layout: role counters in the parallel batch | `src/app/dashboard/layout.tsx` |
| Per-request permission helpers | `src/lib/org-context.ts` |
| Pages batched (permissions + data in one `Promise.all`) | `dashboard/sales/page.tsx`, `purchases/page.tsx`, `customers/page.tsx`, `suppliers/page.tsx`, `products/page.tsx`, `inventory/page.tsx` |
| SQL totals / per-party balances / inventory value | `supabase/migrations/0059_perf_balance_totals.sql`, `supabase/tests/111_perf_balance_totals_test.sql`, `dashboard/page.tsx` |
| Inventory pagination | `dashboard/inventory/page.tsx` |
| Whole-catalogue cost query | `src/lib/costs.ts` (`getAllProductCosts`), `purchases/page.tsx` |
| Chunked bulk imports | `src/lib/bulk.ts`, `customers/actions.ts`, `suppliers/actions.ts`, `products/actions.ts` |
| Sales form memoisation | `dashboard/sales/sales-form.tsx` |

Apply `0059_perf_balance_totals.sql` to the database BEFORE deploying the code (the pages call the new functions).
Behaviour is unchanged: the same views, tables and RLS are used, only the work moved into SQL / parallel batches.
