# Percentage discounts, immediate-payment discount, manual bonus (migration 0029)

## The rules

1. **Every discount is a percentage**: line discount, invoice discount, immediate-payment discount and tier discount.
   Invoices still store the resulting amounts in EGP (so reports and balances are unchanged) and now also the percentages used
   (`discount_pct` on lines, `invoice_discount_pct` / `cash_discount_pct` / `tier_discount_pct` on invoices).
2. **"Cash" discount = paying now.** It applies when an amount is paid / collected on the invoice itself (> 0), whatever the
   payment method (cash, Visa, InstaPay, transfer…). The payment method is only a record of how the money came in.
3. **Bonus is never automatic.** The user lists the bonus items on the invoice (product + quantity). Nothing is computed from rules.
   - A bonus of a product that is also a paid line is folded into that line (lower effective price, as before).
   - Any other product becomes its own zero-value line. Stock and cost still move; the invoice total does not change.
   - The old `bonus_rules` table is kept but nothing reads it any more.

## How the percentages combine

Line discount % comes off each line first. Then invoice % + immediate-payment % + tier % are each taken from that same base
(they add up, they do not compound) and must total at most 100%. The tier is chosen by the base after line discounts; only the
highest reached tier applies.

Example: 10 × 100, line 10% (−100), invoice 5% (−45), immediate-payment 2% paid now (−18) → total 837.

## Existing data

- Past invoices are untouched (their EGP amounts stay as billed).
- Existing tiers in EGP were converted to the percentage they represent at their threshold (1,000 → 50 EGP became 5%).
  **Review them in Settings → Discounts.** The old EGP amount is kept in `discount_amount` for reference.

## Calling the database directly

`create_sales_invoice` / `create_purchase_invoice` take `p_discount_pct`, `p_cash_discount_pct`, `p_bonus_items`
(`[{product_id, quantity}]`), and item discounts as `discount_pct`. Old-style calls fail loudly (an item with an EGP
`discount` is refused; the old parameter names no longer exist), they are never silently reinterpreted.

## Applying it

Run `supabase/repairs/preflight.sql`, make sure 0028 is applied, then run
`supabase/migrations/0029_percent_discounts_manual_bonus.sql` (single transaction; it checks that 0028 is there first).
Then deploy the frontend.
