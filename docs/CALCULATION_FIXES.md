# Calculation fixes — migration 0028 (on top of 0022–0027)

Verified by `supabase/tests/93_calculation_audit_test.sql` (hand-calculated expected values,
exact-cent comparisons) on top of the existing suite, plus two upgrade-path tests (see "How it was tested").

## What your 0022–0027 already fixed (audit findings #1, #2-discount, #10)

- Line discounts and the invoice-level discount reach subtotal / total / profit; invoice-level discount is
  allocated to lines and the last line absorbs the rounding.
- Returns are valued at the net price and the last piece takes "net − already returned", so a full return of
  the goods reverses the exact net amount (no 0.01 residue).
- Purchase stock enters at the net effective cost (after discounts, tax excluded).

## What 0028 fixes on top

| # | Fix |
|---|---|
| 2 | **Tax is reversed by returns** (sales and purchases). Each invoice line gets a `tax_alloc` share (cumulative rounding, adds up exactly); a return credits `net + tax share`. A full return of a taxed invoice brings the balance to exactly 0. |
| 3 | **Dashboard** "صافي المبيعات" / net profit = `report_summary` (before: tax-inclusive billed total and gross profit before returns, expenses and commissions). |
| 4 | **Purchase returns recompute the weighted average**: returned units leave the pool at the value they entered with (100@10 + 100@20 → return the 20-batch → avg 10, value 1,000). |
| 5 | **Cost precision**: `avg_cost`, `product_prices.cost`, `inventory_movements.unit_cost`, `stock_transfer_items.unit_cost` keep 6 decimals. Money columns stay at 2. Sale COGS and return cost come from the recorded `cost_total`, so they are exact. |
| 6 | **No selling below zero stock** (bonus lines included). Before: negative stock at cost 0, profit overstated. |
| 7 | **Validation on the server**: no negative discount / cash discount / tax / payment; tax only on a non-zero invoice; creating an invoice with an amount above its total is refused (before: silently capped); a collection or supplier payment above what is still owed on the invoice is refused. |
| 8 | **Commission**: recomputed after each collection from the invoice's own figures — `collected_amount` excludes the tax share and can no longer grow on an overpayment. |
| 9 | **Reports**: returns are subtracted net of tax everywhere (`report_summary`, `report_sales_breakdown`, dashboard rollups); `report_timeseries` now nets returns in the bucket they happen. |
| + | **Cash refunds move the balance** (customer and supplier) and appear as their own ledger entry. Before, cash left the treasury but the balance never reflected it (paid 1,000, returned 500, refunded 500 cash → balance stayed −500). |

## Behaviour changes you should know about

1. A sale that needs more stock than exists is refused: receive the stock first (or adjust it).
2. Creating an invoice with "collected" above its total is refused instead of silently capped.
3. A return's credit now includes the tax share, so a return of a taxed invoice credits more than before.
4. **Commission on returned sales is unchanged (your 0024 policy, "history kept").** 0028 does not touch it. The monthly
   gate (`rep_monthly_performance`) already nets returns into the month; the per-invoice commission stays as booked.
5. Test 60 was updated: a 200 cash refund now makes payable 2,700 instead of 2,500 (the old expectation encoded the bug).
6. `get_returnable_items` / `get_returnable_purchase_items` return two extra columns (`tax_alloc`, `tax_returned`);
   the two return forms use them to preview the credit including tax.

## Existing (historical) data

0028 does **not** rewrite past invoices or returns: their totals are what was actually billed. Balances, totals, profit and
stock values of existing data are unchanged by the migration (tax shares are back-filled onto old invoice lines so that
**future** returns reverse tax correctly). Run `supabase/repairs/0028_legacy_data_check.sql` (read-only) after migrating
to list historical rows that were affected (returns made without tax reversal, negative stock, overpaid invoices, …).

## Applying it (in this order)

> 0029 (percentage discounts / manual bonus) comes after 0028; see `docs/PERCENT_DISCOUNTS_MANUAL_BONUS.md`.

1. **Back up** the database (Supabase dashboard → Database → Backups, or `pg_dump`).
2. Run `supabase/repairs/preflight.sql`. Every migration row must say `applied`. If any says MISSING, apply those
   files from `supabase/migrations/` in number order first.
3. Run `supabase/migrations/0028_calculation_fixes.sql` (the whole file, in one go). It checks the prerequisites itself and
   stops with the list of what is missing before changing anything. It is a single transaction: an error leaves the database untouched.
4. Optional: run `supabase/repairs/0028_legacy_data_check.sql` and review what it lists.
5. Deploy the frontend (changed files: 2 return modals, 2 returns `actions.ts`, `dashboard-home.tsx`). No new packages or env vars.

## How it was tested

- Full database suite: your 477 assertions + 54 new ones (all pass).
- Upgrade path A: a database built from 0001–0027 with invoices, a return and a commission, then 0028 → history unchanged
  (balance, supplier balance, invoice total, commission, stock), new returns on the old invoices correct.
- Upgrade path B: the first-round fix file applied before 0022–0027, then 0028 → one version of each function, whole suite passes.
- `npx tsc --noEmit` and `npx next lint`: clean.
