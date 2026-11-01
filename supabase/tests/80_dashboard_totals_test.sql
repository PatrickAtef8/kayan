-- 0021: dashboard_sales_totals / dashboard_sales_rollups must equal what the old client-side reduce
-- produced (sum of total / profit_total), and must not leak profit to members
-- without view_financial or data to non-members.

\set ON_ERROR_STOP on

select t.as_owner();
insert into auth.users (id, email) values
  ('f0000000-0000-0000-0000-00000000000a', 'd-owner@dash.test'),
  ('f0000000-0000-0000-0000-00000000000b', 'd-sales@dash.test'),
  ('f0000000-0000-0000-0000-00000000000c', 'd-outsider@dash.test');

select t.as_user('f0000000-0000-0000-0000-00000000000a');
select create_organization('لوحة', 'x', 'EG', 'EGP', 'ar', array['sales','customers','inventory','purchases','suppliers','expenses','treasury']) as id \gset org_

select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', 'f0000000-0000-0000-0000-00000000000b', id, 'active' from roles where key = 'sales' and organization_id is null;

select t.as_user('f0000000-0000-0000-0000-00000000000a');
insert into warehouses (organization_id, name) values (:'org_id', 'م') returning id as w \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as s \gset
insert into customers (organization_id, name) values (:'org_id', 'عميل') returning id as c \gset
insert into products (organization_id, name) values (:'org_id', 'منتج') returning id as p \gset
insert into product_prices (organization_id, product_id, selling_price) values (:'org_id', :'p', 20);
insert into product_costs (product_id, cost) values (:'p', 10);
select create_purchase_invoice(:'org_id', :'s', :'w', 'P-1', '2026-01-01', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 100, 'unit_cost', 10, 'discount', 0)), 0, 0, 0, 'نقدًا', null) as id \gset
select create_sales_invoice(:'org_id', :'c', :'w', 'S-1', '2026-01-02', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 5, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset
select create_sales_invoice(:'org_id', :'c', :'w', 'S-2', '2026-03-02', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 10, 'unit_price', 30, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset

-- 1. Matches the plain sums the page used to compute in JS.
select t.eq((select total_sales  from dashboard_sales_totals(:'org_id', null)), (select sum(total)        from sales_invoices where organization_id = :'org_id'), 'all-time total = sum(total) (= 400)');
select t.eq((select total_profit from dashboard_sales_totals(:'org_id', null)), (select sum(profit_total) from v_sales_invoices where organization_id = :'org_id'), 'all-time profit = sum(profit_total) (= 250)');
select t.eq((select total_sales from dashboard_sales_totals(:'org_id', null)), 400, 'hand-checked total: 5x20 + 10x30');
select t.eq((select total_profit from dashboard_sales_totals(:'org_id', null)), 250, 'hand-checked profit: 50 + 200');

-- 2. Period filter is inclusive on invoice_date, null = all time.
select t.eq((select total_sales from dashboard_sales_totals(:'org_id', '2026-03-02')), 300, 'from the exact date of the later invoice: inclusive');
select t.eq((select total_sales from dashboard_sales_totals(:'org_id', '2026-03-03')), 0, 'a period with no invoices returns 0, not NULL');

-- 3. A member without view_financial sees sales totals but never profit.
select t.as_owner();
select t.make_rep(:'org_id', 'f0000000-0000-0000-0000-00000000000b');
select t.as_user('f0000000-0000-0000-0000-00000000000b');
select t.eq((select total_sales  from dashboard_sales_totals(:'org_id', null)), 400, 'sales-role member still gets the sales total');
select t.eq((select total_profit from dashboard_sales_totals(:'org_id', null)), 0, 'but profit is withheld (= 0)');
select t.ok((select bool_and(gross_profit is null) from dashboard_sales_rollups(:'org_id', null)), 'and rollups return NULL profit for a member without view_financial');

-- 3b. dashboard_sales_rollups equals report_sales_breakdown for the widgets it replaces. (Since 0055/0056 the chart is
--     dashboard_sales_trend — covered by 101 — so the rollups no longer carry 'trend' rows.)
select t.eq((select count(*) from dashboard_sales_rollups(:'org_id', null) where kind = 'trend'), 0, 'the rollups no longer carry trend rows (the chart has its own function)');
select t.ok(not exists (
  (select group_key, group_label, invoices, net_sales, gross_profit from report_sales_breakdown(:'org_id', null, null, 'customer', 5, 0)
   except select group_key, group_label, invoices, net_sales, gross_profit from dashboard_sales_rollups(:'org_id', null) where kind = 'customer')), 'top customers match report_sales_breakdown');
select t.eq((select net_sales from dashboard_sales_rollups(:'org_id', null) where kind = 'customer'), 400, 'customer net sales = 400');
select t.eq((select count(*) from dashboard_sales_rollups(:'org_id', null) where kind = 'representative'), 1, 'one representative group: the member''s own rep');

-- 4. Non-members and anonymous callers are refused.
select t.as_user('f0000000-0000-0000-0000-00000000000c');
select t.throws(format('select * from dashboard_sales_totals(%L, null)', :'org_id'), 'لست عضوًا', 'a non-member cannot read another org''s totals');
select t.as_anon();
select t.throws(format('select * from dashboard_sales_totals(%L, null)', :'org_id'), 'permission denied', 'anon cannot execute it');
select t.as_owner();
