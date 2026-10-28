-- 0059: the new SQL aggregates must equal what the old code computed (JS sums over the views) and what the
-- views return row for row, and must keep the visibility rules (no balances / costs for roles without access).

\set ON_ERROR_STOP on

select t.as_owner();
insert into auth.users (id, email) values
  ('f1000000-0000-0000-0000-00000000000a', 'b-owner@bal.test'),
  ('f1000000-0000-0000-0000-00000000000b', 'b-store@bal.test');

select t.as_user('f1000000-0000-0000-0000-00000000000a');
select create_organization('أرصدة', 'x', 'EG', 'EGP', 'ar', array['sales','customers','inventory','purchases','suppliers','expenses','treasury']) as id \gset org_

select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', 'f1000000-0000-0000-0000-00000000000b', id, 'active' from roles where key = 'warehouse' and organization_id is null;

select t.as_owner(); select t.autoconfirm_on(); select t.as_user('f1000000-0000-0000-0000-00000000000a');
insert into warehouses (organization_id, name) values (:'org_id', 'م') returning id as w \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد 1') returning id as s1 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد 2') returning id as s2 \gset
insert into customers (organization_id, name) values (:'org_id', 'عميل 1') returning id as c1 \gset
insert into customers (organization_id, name) values (:'org_id', 'عميل 2') returning id as c2 \gset
insert into products (organization_id, name) values (:'org_id', 'منتج') returning id as p \gset
insert into product_prices (organization_id, product_id, selling_price) values (:'org_id', :'p', 20);
insert into product_costs (product_id, cost) values (:'p', 10);
select create_purchase_invoice(:'org_id', :'s1', :'w', 'P-1', '2026-01-01', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 100, 'unit_cost', 10, 'discount', 0)), 0, 0, 0, 'نقدًا', null) as id \gset
select create_purchase_invoice(:'org_id', :'s2', :'w', 'P-2', '2026-01-02', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 20, 'unit_cost', 12, 'discount', 0)), 0, 0, 0, 'نقدًا', null) as id \gset
select create_sales_invoice(:'org_id', :'c1', :'w', 'S-1', '2026-01-03', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 5, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset
select create_sales_invoice(:'org_id', :'c2', :'w', 'S-2', '2026-03-02', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 10, 'unit_price', 30, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset

-- 1. totals = the sums the dashboard used to compute in JS
select t.eq((select customer_receivable from dashboard_balance_totals(:'org_id')), (select sum(balance) from customer_balances where organization_id = :'org_id'), 'receivable = sum(customer_balances.balance)');
select t.eq((select supplier_payable from dashboard_balance_totals(:'org_id')), (select sum(balance) from supplier_balances where organization_id = :'org_id'), 'payable = sum(supplier_balances.balance)');
select t.eq((select treasury_balance from dashboard_balance_totals(:'org_id')), (select coalesce(sum(balance), 0) from treasury_balances where organization_id = :'org_id'), 'treasury = sum(treasury_balances.balance)');
select t.eq((select inventory_value from dashboard_balance_totals(:'org_id')),
  (select coalesce(sum(s.quantity * coalesce((select avg_cost from stock_costs c where c.stock_id = s.id), 0)), 0) from inventory_stock s where s.organization_id = :'org_id'),
  'inventory value = sum(quantity x avg_cost)');
select t.ok((select inventory_value from dashboard_balance_totals(:'org_id')) > 0, 'inventory value is positive for the owner');
select t.eq((select inventory_value_total(:'org_id')), (select inventory_value from dashboard_balance_totals(:'org_id')), 'inventory_value_total = the dashboard figure');

-- 2. the per-party functions equal the views, row for row
select t.ok(not exists (
  (select customer_id, total_sales, total_collected, balance from customer_balances where organization_id = :'org_id'
   except select customer_id, total_sales, total_collected, balance from customer_balances_for(array[:'c1'::uuid, :'c2'::uuid]))
  union all
  (select customer_id, total_sales, total_collected, balance from customer_balances_for(array[:'c1'::uuid, :'c2'::uuid])
   except select customer_id, total_sales, total_collected, balance from customer_balances where organization_id = :'org_id')), 'customer_balances_for = customer_balances (all customers)');
select t.ok(not exists (
  (select supplier_id, total_purchases, total_paid, balance from supplier_balances where organization_id = :'org_id'
   except select supplier_id, total_purchases, total_paid, balance from supplier_balances_for(array[:'s1'::uuid, :'s2'::uuid]))
  union all
  (select supplier_id, total_purchases, total_paid, balance from supplier_balances_for(array[:'s1'::uuid, :'s2'::uuid])
   except select supplier_id, total_purchases, total_paid, balance from supplier_balances where organization_id = :'org_id')), 'supplier_balances_for = supplier_balances (all suppliers)');

-- 3. only the requested parties come back
select t.eq((select count(*) from customer_balances_for(array[:'c1'::uuid])), 1, 'one requested customer -> one row');
select t.eq((select total_sales from customer_balances_for(array[:'c2'::uuid])), 300, 'customer 2 total sales (10 x 30)');
select t.eq((select count(*) from supplier_balances_for('{}'::uuid[])), 0, 'empty id list -> no rows');

-- 4. visibility: the storekeeper gets no balances and no inventory value
select t.as_user('f1000000-0000-0000-0000-00000000000b');
select t.eq((select customer_receivable from dashboard_balance_totals(:'org_id')), 0, 'storekeeper: receivable total is 0');
select t.eq((select supplier_payable from dashboard_balance_totals(:'org_id')), 0, 'storekeeper: payable total is 0');
select t.eq((select inventory_value from dashboard_balance_totals(:'org_id')), 0, 'storekeeper: inventory value is 0 (no cost access)');
select t.eq((select inventory_value_total(:'org_id')), 0, 'storekeeper: inventory_value_total is 0 (no cost access)');
select t.ok((select coalesce(bool_and(balance is null), true) from customer_balances_for(array[:'c1'::uuid, :'c2'::uuid])), 'storekeeper: per-customer balances are NULL/hidden like the view');

-- 5. anonymous callers cannot execute them
select t.as_anon();
select t.throws($$select * from dashboard_balance_totals('00000000-0000-0000-0000-000000000000')$$, 'permission denied', 'anon cannot call dashboard_balance_totals');
select t.throws($$select * from customer_balances_for('{}'::uuid[])$$, 'permission denied', 'anon cannot call customer_balances_for');
select t.throws($$select inventory_value_total('00000000-0000-0000-0000-000000000000')$$, 'permission denied', 'anon cannot call inventory_value_total');
select t.as_owner();
