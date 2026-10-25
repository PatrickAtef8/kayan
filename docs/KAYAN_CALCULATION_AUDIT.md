# Kayan — Calculation & Numbers Audit

Scope: every money / quantity / cost / profit / balance calculation in `kayan_latest.zip`
(migrations 0001–0021, all `report_*` / `dashboard_*` functions, views, and the frontend math).

Method: read the latest definition of every function, ran the repo's own DB test suite
(**all 10 files pass**), then wrote 3 probe scripts (`audit-probes/`) that run real scenarios on a
PostgreSQL 16 instance with all migrations applied and compared results to hand-calculated values.
Every number below is an actual output, not an estimate.

> The existing tests pass because they never combine line discounts, tax, invoice discounts, or mixed-cost
> batches with returns. The bugs below live in exactly those gaps.

---

## Summary

| # | Severity | Finding | Where |
|---|---|---|---|
| 1 | CRITICAL | Per-line discounts are ignored in invoice subtotal/total/profit (sales + purchases) | 0006/0008 `create_sales_invoice`, `create_purchase_invoice`; both forms |
| 2 | CRITICAL | Returns don't reverse invoice-level discount or tax → balances wrong after any return | 0011 `create_sales_return`, 0012 `create_purchase_return` |
| 3 | CRITICAL | Dashboard "صافي الربح" is not net profit; "إجمالي المبيعات" ignores returns and includes tax | 0021 `dashboard_sales_totals`, `dashboard/page.tsx` |
| 4 | HIGH | Purchase return doesn't recompute weighted-average cost → inventory value / capital overstated | 0012 |
| 5 | HIGH | `avg_cost` stored at 2 decimals → inventory value drifts from real spend | `inventory_stock.avg_cost numeric(14,2)` |
| 6 | HIGH | Overselling allowed with cost 0 → COGS 0, profit overstated, stock negative | `create_sales_invoice` |
| 7 | HIGH | No server-side validation of discount/tax/overpayment → negative invoices, "paid" with 9,549 on −450 | all invoice/collection/payment RPCs |
| 8 | HIGH | Commission: includes tax on collected basis, grows on overpayment, never reversed on returns | 0008/0010 |
| 9 | MEDIUM | Same period shows different net sales in different reports; `report_timeseries` ignores returns | 0009/0011 |
| 10 | MEDIUM | Return unit price rounded to 2 decimals → 0.01 residuals | 0011 |
| 11 | LOW | Receivable/payable totals net customer credits against debts; treasury can go negative silently | views, treasury |

---

## 1. CRITICAL — Per-line discounts are dropped from invoice totals

The forms have a per-row "discount" input and the RPCs store it in `line_total`, but
`subtotal` is `Σ qty×price` and `total` is `subtotal − invoice_discount + tax`. The line discount is never subtracted.
The frontend preview (`sales-form.tsx:52`, `purchase-form.tsx:42`) has the same omission.

Repro (probe 1):
- Sale: 3 × 40, line discount 20. Item `line_total = 100`, but invoice `subtotal = 120`, `total = 120`.
  Item profit −200, invoice profit −180 (they disagree).
- Purchase: 10 × 100, line discount 100. Item `line_total = 900`, invoice `total = 1000`.
  You owe the supplier 1000 instead of 900.

Impact: receivables, payables, profit, commission, tax base, every report.

Fix: `v_subtotal += qty*price`, `v_line_discounts += line discount`, and
`total = subtotal − (p_discount_total + v_line_discounts) + tax` (or define `discount_total` as the sum of both).
Update both forms' preview to match, and make the item sums reconcile to the invoice.

## 2. CRITICAL — Returns ignore invoice-level discount and tax

Return value = `line_total / qty × returned qty`. Invoice-level discount and tax are never reversed (the code comments
call this a design choice, but the resulting balances are wrong).

Repro (probe 1), full return of the whole invoice:
- 10 × 100 + tax 140 (total 1140) → customer balance after return = **+140** (should be 0)
- 10 × 100 − invoice discount 100 (total 900) → balance after return = **−100** (should be 0; you now owe the customer)
- 3 × 40 with line discount (total 120) → balance after full return = **20.01** (see #1 and #10)
- Partial: 5 of 10 units on a 1026 invoice (disc 100, tax 126), 500 collected → balance 26; proportional answer is 13.

Purchases are the same: returning a line bought with discount 20 refunds **100** while the line was worth **80**.

Fix: allocate invoice discount and tax to returned lines proportionally
(`returned_share = returned_line_value / invoice_subtotal`), the same `alloc` logic `report_sales_breakdown` already uses for products.

## 3. CRITICAL — Dashboard headline numbers

- "صافي الربح" = `Σ profit_total` = gross profit before returns, expenses and commissions.
  Probe 2: dashboard shows **400**; `report_summary` shows gross profit 150 and net profit **60**.
- "إجمالي المبيعات" = `Σ total`: includes tax, excludes returns. Probe 2: **1026** vs net sales **400**.

Fix: feed the dashboard from `report_summary` (or rename the tiles to "إجمالي الفواتير" / "مجمل الربح قبل المرتجعات").

## 4. HIGH — Purchase return leaves avg_cost unchanged

Stock 100 @ 10 + 100 @ 20 → avg 15. Return the whole 100 @ 20 batch → qty 100, avg still **15**, value **1500**; true value is 1000.
Flows into inventory value, رأس المال العام, COGS of later sales, and transfers (warehouse 2 got avg 15).

Fix: when the returned line's cost differs from the current average, reverse it out of the pool:
`new_avg = (qty×avg − returned_qty×returned_cost) / (qty − returned_qty)`.

## 5. HIGH — avg_cost rounded to 2 decimals

1000 @ 10.00 then 1000 @ 10.01 → avg stored 10.01 (true 10.005): stock value **20,020** vs real spend **20,010**.
Each purchase adds a rounding error multiplied by on-hand quantity.

Fix: store `avg_cost` as `numeric(14,6)` (or keep `total_value` and derive the average), round only for display and for money columns.

## 6. HIGH — Overselling → negative stock with zero cost

Selling 5 units of a product with no stock succeeds: stock −5, `avg_cost 0`, COGS 0, so profit = 100% of revenue.
The financial-position report only warns via `negative_stock_items`; the P&L is silently wrong.
Non-tracked products with no `product_prices` row also get cost 0.

Fix: reject sales above on-hand quantity (or at least flag the invoice and exclude from profit reports until costed).

## 7. HIGH — No server-side validation on money inputs

UI uses `min="0"` only. The RPCs accept (probe 1):
- invoice discount 500 on a 100 sale + tax −50 → total **−450**
- negative discount −500 → total 600 (inflated)
- collection of 9,999 on that invoice → `amount_paid = 9,549`, status "paid"

Fix: in all RPCs enforce `discount ≥ 0`, `tax ≥ 0`, `discount ≤ subtotal`, `unit_price ≥ 0`, and cap/reject payments
above the remaining invoice balance (or record the excess as customer credit explicitly).

## 8. HIGH — Commission

- `collected_amount` basis uses cash collected, which includes tax: 1,140 collected × 10% = **114** (net sales basis: 100).
- Overpayments keep adding commission: a second 1,000 payment on a paid 1,140 invoice → commission **214**.
- Returns never reduce commission (90 stays after half the sale is returned) but net profit subtracts the full amount.
  (Flagged by you as an open item in 0011; recorded here because it directly overstates expenses.)

## 9. MEDIUM — Cross-report consistency

- Sale in Sept, 1-unit return in Oct: Sept net sales = **400** in `report_summary` but **300** in `report_sales_breakdown`
  (documented design: period-scoped vs invoice-scoped).
- `report_timeseries` ignores returns completely: Sept **900** vs **400**. Not documented; charts using it overstate sales.
- The dashboard rollups do match the breakdown (test 80 confirms).

## 10. MEDIUM — Rounding in returns

Return unit price = `line_total / qty` rounded to 2 decimals. 3 units of a 100.00 line → 33.33 × 3 = **99.99**, leaving 0.01 forever.
Fix: `revenue = round(line_total × returned_qty / original_qty, 2)`, and give the last unit the remainder.

## 11. LOW / notes

- `receivable`/`payable` totals sum signed balances, so a customer credit hides someone else's debt.
- Treasury has no floor: paying a 5,000 supplier invoice with an empty treasury leaves −4,500.

---

## Verified correct (matched hand calculations)

- Invoice totals without line discounts: subtotal, discount, tax, total.
- Weighted-average formula on purchases and the cost captured at sale (COGS, item profit).
- Customer/supplier balance formulas including opening balances and returns; ledger running balances.
- Treasury balance = opening + in − out; treasury summary opening/closing.
- Stock transfers carry source cost; inventory value = Σ qty × avg_cost.
- رأس المال العام matches the SRS §41 formula, completed in migration 0057 to include أصول أخرى (assets − liabilities); `net_position` is the same figure. Migration 0058 also subtracts earned-but-unpaid rep commissions.
- `report_summary` chain (gross → discounts → returns → net → COGS → profit → expenses → commissions → net profit).
- Dashboard rollups equal `report_sales_breakdown`.

## Not reviewed in depth

Partner withdrawals and expense RPC arithmetic (only skimmed), CSV import number parsing, price-tier logic,
and runtime behavior of the frontend (no browser run). Say the word and I'll cover those.

## Reproducing

`audit-probes/probe*.sql` run against a DB built with `supabase/tests/run.sh` (they use the `t.*` helpers).

---

## Resolution status — merged version (your 0022–0027 + migration 0028)

| # | Finding | Status | Fixed by |
|---|---|---|---|
| 1 | Line discounts ignored in totals | Fixed | your 0022 pricing engine |
| 2 | Returns ignore invoice discount | Fixed | your 0022/0023 (net-price returns) |
| 2 | Returns ignore invoice tax | Fixed | 0028 (tax shares, reversed with the goods) |
| 3 | Dashboard net profit / sales mislabeled | Fixed | 0028 (dashboard = `report_summary`) |
| 4 | Purchase return leaves avg_cost | Fixed | 0028 |
| 5 | avg_cost 2 decimals | Fixed | 0028 (6 decimals; exact COGS from `cost_total`) |
| 6 | Overselling at zero cost | Fixed | 0028 (bonus lines too) |
| 7 | No server-side validation | Fixed | 0028 |
| 8 | Commission: tax included, grows on overpay | Fixed | 0028 |
| 8 | Commission not reduced by returns | Left as is | your 0024 policy ("history kept") |
| 9 | Cross-report inconsistency / timeseries | Fixed | 0028 |
| 10 | Return rounding residue | Fixed | your 0023 (last piece takes the remainder) |
| 11 | Credits net against debts; treasury floor | Not changed | policy choice |
| + | Cash refund did not move balance | Fixed | 0028 |

Test results: 531 database assertions pass (477 existing + 54 new); `tsc --noEmit` and `next lint` clean; two upgrade paths
verified on databases with existing data.
