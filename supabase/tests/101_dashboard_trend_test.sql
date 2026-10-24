-- 0055 + 0056: the home-page trend must add up to the KPI cards (dashboard_sales_totals) for any period —
-- including a return made THIS month against an invoice from LAST month, which the old chart got wrong.
-- Written alongside 0055 but not executed in the authoring environment: run it with the rest of the suite.

\set ON_ERROR_STOP on

select t.as_owner();
insert into auth.users (id, email) values ('9d000000-0000-0000-0000-000000000001', 'owner@tr101.test');
select t.as_user('9d000000-0000-0000-0000-000000000001');
select create_organization('شركة الاتجاه', 'تجارة', 'EG', 'EGP', 'ar',
  array['sales','customers','inventory','purchases','suppliers','expenses','treasury']) as id \gset org_
select cairo_today() as d0 \gset
select date_trunc('month', :'d0'::date)::date as m0 \gset
select (:'m0'::date - 10) as dprev \gset

insert into warehouses (organization_id, name) values (:'org_id', 'الرئيسي') returning id as w1 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as sup \gset
insert into customers (organization_id, name, price_tier) values (:'org_id', 'عميل', 'retail') returning id as ca \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'X', 'X', 'قطعة') returning id as px \gset
insert into product_prices (organization_id, product_id, selling_price) values (:'org_id', :'px', 100);
insert into expense_categories (organization_id, name) values (:'org_id', 'إيجار') returning id as cat_rent \gset
select t.as_owner();
select ensure_default_treasury_account(:'org_id') as acct \gset
select t.as_user('9d000000-0000-0000-0000-000000000001');

-- stock: 100 @ 40 → every unit sold costs 40
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'TR-P1', :'dprev'::date,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 100, 'unit_cost', 40, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset p1_

-- S1: last month, 10 × 100 (sales 1000, cost 400)   S2: this month, 20 × 100 (sales 2000, cost 800)
select create_sales_invoice(:'org_id', :'ca', :'w1', 'TR-S1', :'dprev'::date,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 10, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset s1_
select create_sales_invoice(:'org_id', :'ca', :'w1', 'TR-S2', :'m0'::date,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 20, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset s2_
-- this month's return of 2 units of LAST month's invoice (sales −200, cost −80)
select create_sales_return(:'org_id', :'s1_id', :'m0'::date,
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'s1_id'), 'quantity', 2, 'condition', 'resalable')), 0, null) as id \gset r1_
select create_expense(:'org_id', :'cat_rent', :'acct', 300, :'m0'::date, 'cash', 'إيجار', null) as id \gset e1_

-- 1. Hand-checked, this month: sales 2000 − 200 = 1800; profit (2000 − 800) − (200 − 80) − 300 = 780
select t.eq((select total_sales  from dashboard_sales_totals(:'org_id', :'m0'::date)), 1800, 'card: net sales this month = 1800');
select t.eq((select total_profit from dashboard_sales_totals(:'org_id', :'m0'::date)), 780,  'card: net profit this month = 780');

-- 2. The chart adds up to the cards (daily buckets, this month)
select t.eq((select sum(net_sales)  from dashboard_sales_trend(:'org_id', :'m0'::date, 'day')), (select total_sales  from dashboard_sales_totals(:'org_id', :'m0'::date)), 'daily bars sum to the net-sales card');
select t.eq((select sum(net_profit) from dashboard_sales_trend(:'org_id', :'m0'::date, 'day')), (select total_profit from dashboard_sales_totals(:'org_id', :'m0'::date)), 'daily profit sums to the net-profit card');

-- 3. The return lands on the day it was made (this month), not on last month's invoice date
select t.eq((select net_sales from dashboard_sales_trend(:'org_id', :'m0'::date, 'day') where bucket_date = :'m0'::date), 1800, 'the return is netted on its own date');

-- 4. Zero-filled: one row per day from the 1st to today
select t.eq((select count(*) from dashboard_sales_trend(:'org_id', :'m0'::date, 'day')), (:'d0'::date - :'m0'::date + 1)::bigint, 'one row per day, empty days included');

-- 5. All time, monthly buckets, still adds up
select t.eq((select sum(net_sales)  from dashboard_sales_trend(:'org_id', null, 'month')), (select total_sales  from dashboard_sales_totals(:'org_id', null)), 'all-time monthly sales sum to the card');
select t.eq((select sum(net_profit) from dashboard_sales_trend(:'org_id', null, 'month')), (select total_profit from dashboard_sales_totals(:'org_id', null)), 'all-time monthly profit sums to the card');

-- 6. Bad bucket is refused
select t.throws(format($q$select * from dashboard_sales_trend(%L, null, 'week')$q$, :'org_id'), 'تجميع غير مدعوم', 'only day / month buckets');

-- ===== 0056: a SPECIFIC past month (closed range p_from .. p_to) =====
-- LAST month = :dprev's month. S1 (1000 sales, cost 400) was invoiced then; the 200/80 return was made THIS month.
select date_trunc('month', :'dprev'::date)::date as pm0 \gset
select (date_trunc('month', :'dprev'::date) + interval '1 month - 1 day')::date as pm1 \gset

-- the past month's cards: the return is NOT in it (it was made later) → sales 1000, profit 1000 − 400 = 600
select t.eq((select total_sales  from dashboard_sales_totals(:'org_id', :'pm0'::date, :'pm1'::date)), 1000, 'past month: net sales ignore a return made later');
select t.eq((select total_profit from dashboard_sales_totals(:'org_id', :'pm0'::date, :'pm1'::date)), 600,  'past month: net profit ignores a return made later');

-- the chart for that month adds up to those cards and covers the whole month, empty days included
select t.eq((select sum(net_sales)  from dashboard_sales_trend(:'org_id', :'pm0'::date, :'pm1'::date, 'day')), 1000, 'past month: chart sales = card');
select t.eq((select sum(net_profit) from dashboard_sales_trend(:'org_id', :'pm0'::date, :'pm1'::date, 'day')), 600,  'past month: chart profit = card');
select t.eq((select count(*) from dashboard_sales_trend(:'org_id', :'pm0'::date, :'pm1'::date, 'day')), (:'pm1'::date - :'pm0'::date + 1)::bigint, 'past month: one row per day of THAT month');

-- the ranking cards follow the same rules: last month's customer total is 1000, this month's is 2000 − 200
select t.eq((select net_sales from dashboard_sales_rollups(:'org_id', :'pm0'::date, :'pm1'::date) where kind = 'customer' limit 1), 1000, 'past month: top customer = card');
select t.eq((select net_sales from dashboard_sales_rollups(:'org_id', :'m0'::date, null) where kind = 'customer' limit 1), 1800, 'this month: top customer nets the return made this month');

-- a whole past year, monthly buckets: 12 rows ending in December of that year
select (extract(year from :'dprev'::date)::int || '-01-01')::date as y0 \gset
select (extract(year from :'dprev'::date)::int || '-12-31')::date as y1 \gset
select t.eq((select count(*) from dashboard_sales_trend(:'org_id', :'y0'::date, :'y1'::date, 'month')), 12::bigint, 'past year: 12 monthly buckets');
select t.eq((select max(bucket_date) from dashboard_sales_trend(:'org_id', :'y0'::date, :'y1'::date, 'month')), (extract(year from :'dprev'::date)::int || '-12-01')::date, 'past year: axis ends in December, not today');
