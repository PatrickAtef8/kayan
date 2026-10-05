-- READ-ONLY. Run this on your real database BEFORE applying 0028 / 0029.
-- (Rows 0028 and 0029 themselves may say MISSING until you apply them: that is expected.)
-- Every migration row must say 'applied'. If one says MISSING, apply the missing
-- migrations from supabase/migrations/ in numeric order first, then 0028.
select m.migration,
       case when m.present then 'applied' else 'MISSING - apply this first' end as status
from (values
  ('0011_returns_and_team',            to_regclass('public.sales_returns') is not null),
  ('0012_purchase_returns',            to_regclass('public.purchase_returns') is not null),
  ('0013_custom_roles',                exists (select 1 from pg_proc where proname = 'create_custom_role')),
  ('0014_price_tiers',                 exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'price_tier')),
  ('0015_warehouse_transfers',         to_regclass('public.stock_transfer_items') is not null),
  ('0016_attachments',                 to_regclass('public.attachments') is not null),
  ('0017_global_search',               exists (select 1 from pg_proc where proname = 'global_search')),
  ('0018_opening_balances',            exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'opening_balance')),
  ('0019_alert_queries',               exists (select 1 from pg_proc where proname = 'report_overdue_collections')),
  ('0021_dashboard_totals',            exists (select 1 from pg_proc where proname = 'dashboard_sales_totals')),
  ('0022_discounts_bonus_net_pricing', to_regclass('public.discount_tiers') is not null and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sales_invoice_items' and column_name = 'net_total')),
  ('0023_net_price_returns',           exists (select 1 from pg_proc where proname = 'get_returnable_items' and pg_get_function_result(oid) like '%bonus_quantity%')),
  ('0024_rep_targets_commission_rls',  to_regclass('public.party_notes') is not null),
  ('0025_analysis_reports',            exists (select 1 from pg_proc where proname = 'report_customer_analysis')),
  ('0026_treasury_breakdown',          exists (select 1 from pg_proc where proname = 'report_treasury_summary')),
  ('0027_hide_cost_profit',            to_regclass('public.sales_invoice_financials') is not null),
  ('0028_calculation_fixes',          exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sales_return_items' and column_name = 'tax_reversed')),
  ('0029_percent_discounts_manual_bonus', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sales_invoices' and column_name = 'cash_discount_pct'))
) as m(migration, present)
order by m.migration;

-- Was the FIRST-round fix file ("0022_calculation_fixes.sql") ever applied here?
-- 0028 cleans up its leftovers either way; this is only for your information.
select case when exists (select 1 from pg_proc where proname = 'cumulative_share')
            then 'the first-round 0022_calculation_fixes was applied on this database (0028 will clean up its leftovers)'
            else 'the first-round 0022_calculation_fixes was NOT applied here (nothing to clean up)' end as first_round_fix_file;
