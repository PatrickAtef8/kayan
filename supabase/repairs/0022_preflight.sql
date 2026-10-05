-- READ-ONLY. Run this on your real database BEFORE 0022.
-- It shows which earlier migrations are applied. Every row must say 'applied'
-- (0020 has no object to detect: it only rewrites RLS policies, so apply it in
-- order too — it sits between 0019 and 0021).
select m.migration,
       case when m.present then 'applied' else 'MISSING - apply this first' end as status
from (values
  ('0011_returns_and_team',    to_regclass('public.sales_returns') is not null),
  ('0012_purchase_returns',    to_regclass('public.purchase_returns') is not null),
  ('0013_custom_roles',        exists (select 1 from pg_proc where proname = 'create_custom_role')),
  ('0014_price_tiers',         exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'price_tier')),
  ('0015_warehouse_transfers', to_regclass('public.stock_transfer_items') is not null),
  ('0016_attachments',         to_regclass('public.attachments') is not null),
  ('0017_global_search',       exists (select 1 from pg_proc where proname = 'global_search')),
  ('0018_opening_balances',    exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'opening_balance')),
  ('0019_alert_queries',       exists (select 1 from pg_proc where proname = 'report_overdue_collections')),
  ('0021_dashboard_totals',    exists (select 1 from pg_proc where proname = 'dashboard_sales_totals'))
) as m(migration, present)
order by m.migration;
