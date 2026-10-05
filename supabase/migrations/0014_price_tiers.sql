-- Kayan — Phase 11: Multiple Price Levels (§17: "Multiple price levels
-- where required")
--
-- The SRS doesn't name specific tiers or a configurable-tiers system —
-- just that a product needs more than one price where the business needs
-- it. customers.customer_type already existed as a free-text label
-- ('retail' | 'wholesale' | 'market', per its own inline comment in
-- 0004) but was never actually READ anywhere — it was decorative. Rather
-- than repurpose that free-text field (which real data may already hold
-- arbitrary values in) into something the pricing logic depends on, this
-- adds a small, separate, constrained field purely for tier selection —
-- customer_type stays exactly as it was, still just a label.
--
-- Design:
--   1. Two new nullable columns on product_prices: wholesale_price,
--      distributor_price. NULL means "no override — use selling_price for
--      this tier", so every existing product keeps working with zero
--      migration of existing rows.
--   2. customers.price_tier: constrained to retail/wholesale/distributor,
--      defaulting to 'retail' (today's only behavior) so nothing changes
--      for a customer nobody has touched.
--   3. No new RPC — product_prices and customers are already directly
--      writable master data (client inserts/updates through Supabase
--      directly, gated by the existing is_org_member RLS), same tier as
--      products/suppliers/warehouses. Tier pricing is just two more
--      columns on a table that already works that way.
--   4. Price *selection* at invoice time is a client-side concern (same
--      as today: unit_price already free-text-overridable on every sales
--      line), not something enforced in the database — consistent with
--      how selling_price itself isn't enforced against sales_invoice_items
--      today either.

alter table product_prices
  add column if not exists wholesale_price numeric(14,2),
  add column if not exists distributor_price numeric(14,2);

alter table customers
  add column if not exists price_tier text not null default 'retail' check (price_tier in ('retail', 'wholesale', 'distributor'));

-- The existing audit trigger only watched selling_price; extend it to the
-- new tiers too, same reasoning as the original ("a price change is
-- worth a record — §46").
drop trigger if exists audit_product_price_change on product_prices;
create trigger audit_product_price_change after update on product_prices
  for each row
  when (
    OLD.selling_price is distinct from NEW.selling_price
    or OLD.wholesale_price is distinct from NEW.wholesale_price
    or OLD.distributor_price is distinct from NEW.distributor_price
  )
  execute function audit_row_change('product_price', '');
