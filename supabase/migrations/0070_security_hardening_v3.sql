-- Kayan — 0070: security hardening, round 3 (pre-production review)
--
-- Every change here is additive or a tightening; no table, column, price, limit, module or business rule is changed, and
-- no data is touched. Safe to run on a database that already has 0001–0069 applied.
--
--   §1  ar_norm() / like_contains() were created by 0069 with NO grants. Since 0030 removed the default EXECUTE that
--       Supabase gives new functions to anon / authenticated, the signed-in role could not run them — and ar_norm() is used by
--       the GIN indexes on customers / suppliers / products, so even INSERTING a customer failed ("permission denied for
--       function ar_norm"), as did the search RPCs. Pure string helpers: granted to authenticated + service_role only.
--   §2  Table privileges converged to the intended grant model (Supabase's default ACL had voided every narrower grant).
--   §3  platform_pricing_config: anon reads the config but no longer the admin's user id (updated_by).
--   §4  rate_limit_hit(): a database-backed, atomic fixed-window counter (serverless-safe), service role only.

-- ============================================================
-- §1  Search helpers: executable by the signed-in role (and the server), never by anon
-- ============================================================
revoke all on function ar_norm(text), like_contains(text) from public, anon;
grant execute on function ar_norm(text), like_contains(text) to authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function ar_norm(text), like_contains(text) to service_role;
  end if;
end $$;

-- ============================================================
-- §2  Table privileges: converge a real Supabase project to the grant model the migrations were written for
--
--     Supabase's default ACL hands ALL on every table the `postgres` role creates to anon AND authenticated. The migrations
--     (and the test suite) assume bare PostgreSQL, where only the explicit GRANTs exist — so on a real project every narrower
--     grant, every column-level UPDATE list and every "no DELETE on the ledger" revoke was silently void and Row Level
--     Security was the ONLY barrier (TRUNCATE is not subject to RLS at all). Defence in depth is restored here:
--       · anon keeps exactly the three public-read tables; authenticated keeps exactly what each migration granted;
--       · nobody but the owner keeps TRUNCATE / REFERENCES / TRIGGER;
--       · future tables no longer inherit ALL (same treatment 0030 gave to functions): a new table now needs explicit
--         GRANTs, exactly as the suite — which runs on bare PostgreSQL — already requires.
--     Only EXCESS privileges are revoked (nothing a role needs is ever removed, even momentarily).
-- ============================================================
revoke truncate, references, trigger on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon;
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon;

revoke delete, insert, select, update on attachments from anon;
revoke delete, insert, select, update on audit_logs from anon;
revoke delete, insert, select, update on bonus_rules from anon;
revoke delete, insert, select, update on customer_balances from anon;
revoke delete, insert, select, update on customer_collections from anon;
revoke delete, insert, select, update on customers from anon;
revoke delete, insert, select, update on discount_tiers from anon;
revoke delete, insert, select, update on expense_categories from anon;
revoke delete, insert, select, update on expenses from anon;
revoke delete, insert, select, update on inventory_movements from anon;
revoke delete, insert, select, update on inventory_stock from anon;
revoke delete, insert, select, update on invoice_commissions from anon;
revoke delete, insert, select, update on operating_expenses from anon;
revoke delete, insert, select, update on organization_modules from anon;
revoke delete, insert, select, update on organization_users from anon;
revoke delete, insert, select, update on organizations from anon;
revoke delete, insert, select, update on other_balances from anon;
revoke delete, insert, select, update on partner_withdrawals from anon;
revoke delete, insert, select, update on partners from anon;
revoke delete, insert, select, update on party_notes from anon;
revoke delete, insert, select, update on product_categories from anon;
revoke delete, insert, select, update on product_prices from anon;
revoke delete, insert, select, update on product_sale_prices from anon;
revoke delete, insert, select, update on products from anon;
revoke delete, insert, select, update on purchase_invoice_items from anon;
revoke delete, insert, select, update on purchase_invoices from anon;
revoke delete, insert, select, update on purchase_return_items from anon;
revoke delete, insert, select, update on purchase_returns from anon;
revoke delete, insert, select, update on rep_commission_balances from anon;
revoke delete, insert, select, update on rep_monthly_performance from anon;
revoke select on roles from anon;
revoke delete, insert, select, update on sales_invoice_financials from anon;
revoke delete, insert, select, update on sales_invoice_items from anon;
revoke delete, insert, select, update on sales_invoices from anon;
revoke delete, insert, select, update on sales_item_financials from anon;
revoke delete, insert, select, update on sales_representatives from anon;
revoke delete, insert, select, update on sales_return_financials from anon;
revoke delete, insert, select, update on sales_return_item_financials from anon;
revoke delete, insert, select, update on sales_return_items from anon;
revoke delete, insert, select, update on sales_returns from anon;
revoke delete, insert, select, update on stock_transfer_items from anon;
revoke delete, insert, select, update on stock_transfers from anon;
revoke delete, insert, select, update on supplier_balances from anon;
revoke delete, insert, select, update on supplier_payments from anon;
revoke delete, insert, select, update on suppliers from anon;
revoke delete, insert, select, update on treasury_accounts from anon;
revoke delete, insert, select, update on treasury_balances from anon;
revoke delete, insert, select, update on treasury_movements from anon;
revoke delete, insert, select, update on v_sales_invoice_items from anon;
revoke delete, insert, select, update on v_sales_invoices from anon;
revoke delete, insert, select, update on v_sales_return_items from anon;
revoke delete, insert, select, update on v_sales_returns from anon;
revoke delete, insert, select, update on warehouses from anon;
revoke update on attachments from authenticated;
revoke delete, update on audit_logs from authenticated;
revoke delete, insert, update on customer_balances from authenticated;
revoke delete, update on customer_collections from authenticated;
revoke delete, update on expense_categories from authenticated;
revoke delete, update on expenses from authenticated;
revoke delete, insert, update on inventory_movement_costs from authenticated;
revoke delete, update on inventory_movements from authenticated;
revoke delete on inventory_stock from authenticated;
revoke delete, insert, update on invoice_commissions from authenticated;
revoke delete, insert, update on operating_expenses from authenticated;
revoke delete on organizations from authenticated;
revoke delete, insert, update on other_balances from authenticated;
revoke delete, update on partner_withdrawals from authenticated;
revoke delete, update on party_notes from authenticated;
revoke delete, insert, update on product_sale_prices from authenticated;
revoke delete, update on purchase_invoice_items from authenticated;
revoke delete, insert, update on purchase_return_items from authenticated;
revoke delete, insert, update on purchase_returns from authenticated;
revoke delete, insert, update on rep_commission_balances from authenticated;
revoke delete, insert, update on rep_monthly_performance from authenticated;
revoke delete, insert, update on sales_invoice_financials from authenticated;
revoke delete, update on sales_invoice_items from authenticated;
revoke delete, insert, update on sales_item_financials from authenticated;
revoke delete, insert, update on sales_return_financials from authenticated;
revoke delete, insert, update on sales_return_item_financials from authenticated;
revoke delete, insert, update on sales_return_items from authenticated;
revoke delete, insert, update on sales_returns from authenticated;
revoke delete, insert, update on stock_costs from authenticated;
revoke delete, insert, update on stock_transfer_costs from authenticated;
revoke delete, insert, update on stock_transfer_item_costs from authenticated;
revoke delete, insert, update on stock_transfer_items from authenticated;
revoke delete, insert, update on stock_transfers from authenticated;
revoke delete, insert, update on supplier_balances from authenticated;
revoke delete, update on supplier_payments from authenticated;
revoke delete, update on treasury_accounts from authenticated;
revoke delete, insert, update on treasury_balances from authenticated;
revoke delete, update on treasury_movements from authenticated;
revoke delete, insert, update on v_sales_invoice_items from authenticated;
revoke delete, insert, update on v_sales_invoices from authenticated;
revoke delete, insert, update on v_sales_return_items from authenticated;
revoke delete, insert, update on v_sales_returns from authenticated;

-- column-level grants (re-asserted: revoking a table-level privilege also clears the column ones)
grant insert (barcode, reorder_level, units_per_carton) on products to authenticated;
grant select (barcode, reorder_level, units_per_carton) on products to authenticated;
grant update (barcode, reorder_level, units_per_carton) on products to authenticated;
grant select (due_date) on purchase_invoices to authenticated;
grant select (sales_channel) on sales_invoices to authenticated;
grant select (return_reason) on sales_return_items to authenticated;
grant insert (payment_terms_days) on suppliers to authenticated;
grant select (payment_terms_days) on suppliers to authenticated;
grant update (payment_terms_days) on suppliers to authenticated;

-- ============================================================
-- §3  platform_pricing_config: public read of the CONFIG only, not of who last edited it
--     (the table is readable by anon so the public pricing page works; updated_by is the Super Admin's auth user id).
--     The application selects exactly (config, updated_at), so nothing that works today changes.
-- ============================================================
revoke select on platform_pricing_config from anon, authenticated;
grant select (id, config, updated_at) on platform_pricing_config to anon, authenticated;

-- ============================================================
-- §4  Rate limiting: an atomic fixed-window counter in the database.
--     Serverless instances share no memory, so an in-process counter limits nothing; the database is the one shared place.
--     Only the server (service role) can call it — a browser must never be able to read, reset or fill another person's
--     counter. One row per (key, window); old windows are swept opportunistically.
-- ============================================================
create table if not exists rate_limits (
  key          text        not null check (length(key) between 1 and 200),
  window_start timestamptz not null,
  hits         integer     not null default 0,
  primary key (key, window_start)
);
create index if not exists rate_limits_window_idx on rate_limits (window_start);
alter table rate_limits enable row level security;   -- no policy on purpose: nothing but the definer function below touches it
revoke all on rate_limits from public, anon, authenticated;

create or replace function rate_limit_hit(p_key text, p_window_seconds integer, p_max integer) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_start timestamptz;
  v_hits  integer;
  v_reset timestamptz;
begin
  if p_key is null or length(p_key) not between 1 and 200 or p_window_seconds not between 1 and 86400 or p_max < 1 then
    raise exception 'invalid rate limit arguments';
  end if;
  v_start := to_timestamp(floor(extract(epoch from clock_timestamp()) / p_window_seconds) * p_window_seconds);
  v_reset := v_start + make_interval(secs => p_window_seconds);

  insert into rate_limits as r (key, window_start, hits) values (p_key, v_start, 1)
  on conflict (key, window_start) do update set hits = r.hits + 1
  returning r.hits into v_hits;

  if random() < 0.01 then   -- housekeeping: windows older than two days can never matter again
    delete from rate_limits where window_start < now() - interval '2 days';
  end if;

  return jsonb_build_object(
    'allowed', v_hits <= p_max,
    'hits', v_hits,
    'retry_after', greatest(1, ceil(extract(epoch from (v_reset - clock_timestamp())))::integer)
  );
end $$;
revoke all on function rate_limit_hit(text, integer, integer) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function rate_limit_hit(text, integer, integer) to service_role;
    grant select, insert, update, delete on rate_limits to service_role;
  end if;
end $$;
