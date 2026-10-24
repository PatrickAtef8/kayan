-- SRS §8, §50, §59: tenant isolation and privilege escalation.
-- "One company must never access another company's data" — through the UI,
-- the API, database queries, direct requests, or manipulated ids.

\set ON_ERROR_STOP on

select t.as_owner();
insert into auth.users (id, email) values
  ('c0000000-0000-0000-0000-00000000000a', 'alice@iso.test'),   -- owner of org A (the victim)
  ('c0000000-0000-0000-0000-00000000000b', 'bob@iso.test'),     -- owner of org B (the attacker)
  ('c0000000-0000-0000-0000-00000000000c', 'carol@iso.test'),   -- storekeeper in org A
  ('c0000000-0000-0000-0000-00000000000d', 'dave@iso.test');    -- sales rep in org A

select t.as_user('c0000000-0000-0000-0000-00000000000a');
select create_organization('الضحية', 'x', 'EG', 'EGP', 'ar', array['sales','customers','inventory','purchases','suppliers','expenses','treasury','partners']) as id \gset orga_
select t.as_user('c0000000-0000-0000-0000-00000000000b');
select create_organization('المهاجم', 'x', 'EG', 'EGP', 'ar', array['sales','customers','inventory','purchases','suppliers','expenses','treasury','partners']) as id \gset orgb_

select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'orga_id', 'c0000000-0000-0000-0000-00000000000c', id, 'active' from roles where key = 'warehouse' and organization_id is null;
insert into organization_users (organization_id, user_id, role_id, status)
select :'orga_id', 'c0000000-0000-0000-0000-00000000000d', id, 'active' from roles where key = 'sales' and organization_id is null;

-- Org A gets a full set of business data.
select t.as_user('c0000000-0000-0000-0000-00000000000a');
insert into warehouses (organization_id, name) values (:'orga_id', 'مخزن أ') returning id as wa \gset
insert into suppliers (organization_id, name) values (:'orga_id', 'مورد أ') returning id as sa \gset
insert into customers (organization_id, name) values (:'orga_id', 'عميل أ') returning id as ca \gset
insert into products (organization_id, name) values (:'orga_id', 'منتج أ') returning id as pa \gset
insert into product_prices (organization_id, product_id, selling_price) values (:'orga_id', :'pa', 20);
insert into product_costs (product_id, cost) values (:'pa', 10);
insert into partners (organization_id, name) values (:'orga_id', 'شريك أ') returning id as para \gset
select create_purchase_invoice(:'orga_id', :'sa', :'wa', 'PA-1', '2026-01-01', jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 50, 'unit_cost', 10, 'discount', 0)), 0, 0, 100, 'نقدًا', null) as id \gset pia_
select create_sales_invoice(:'orga_id', :'ca', :'wa', 'SA-1', '2026-01-02', jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 5, 'unit_price', 20, 'discount', 0)), 0, 0, 30, 'نقدًا', null, null) as id \gset sia_
select create_expense(:'orga_id', (select id from expense_categories where organization_id = :'orga_id' limit 1), null, 40, '2026-01-03', 'نقدًا', 'مصروف أ', null) as id \gset
select add_other_balance(:'orga_id', 'liability', 'التزام أ', 500, null) as id \gset
select id as accta from treasury_accounts where organization_id = :'orga_id' and is_default \gset
select id as cata from expense_categories where organization_id = :'orga_id' limit 1 \gset
select balance as casha_before from treasury_balances where organization_id = :'orga_id' \gset

-- ============================================================
-- 1. Reads: the attacker sees nothing that belongs to org A
-- ============================================================
select t.as_user('c0000000-0000-0000-0000-00000000000b');

select t.empty(format('select 1 from %I where organization_id = %L', tbl, :'orga_id'), 'org B cannot read org A rows in ' || tbl)
from unnest(array[
  'customers','suppliers','products','product_categories','product_prices','warehouses',
  'purchase_invoices','purchase_invoice_items','inventory_stock','inventory_movements','supplier_payments',
  'sales_invoices','sales_invoice_items','customer_collections',
  'treasury_accounts','treasury_movements','expense_categories','expenses',
  'partners','partner_withdrawals','sales_representatives',
  'organization_modules','organization_users','audit_logs','other_balances',
  'customer_balances','supplier_balances','treasury_balances'
]) as tbl;
select t.empty(format('select 1 from organizations where id = %L', :'orga_id'), 'org B cannot read the org A organization row');

-- ============================================================
-- 2. RPCs called with someone else's organization id
-- ============================================================
select t.throws(format('select report_summary(%L)', :'orga_id'), 'لست عضوًا', 'report_summary(org A) is refused');
select t.throws(format('select * from report_sales_breakdown(%L, null, null, ''customer'')', :'orga_id'), 'لست عضوًا', 'sales breakdown(org A) is refused');
select t.throws(format('select report_financial_position(%L)', :'orga_id'), 'لست عضوًا', 'financial position(org A) is refused');
select t.throws(format('select * from report_party_ledger(%L, ''customer'', %L)', :'orga_id', :'ca'), 'لست عضوًا', 'ledger(org A) is refused');
select t.throws(format('select create_expense(%L, null, null, 1, null, null, ''x'', null)', :'orga_id'), 'لست عضوًا', 'create_expense(org A) is refused');
select t.throws(format('select record_customer_collection(%L, %L, null, 1, null, null, null, null)', :'orga_id', :'ca'), 'لست عضوًا', 'record_customer_collection(org A) is refused');
select t.throws(format('select add_other_balance(%L, ''liability'', ''x'', 1, null)', :'orga_id'), 'لست عضوًا', 'add_other_balance(org A) is refused');
select t.throws(format('select adjust_inventory_stock(%L, %L, %L, 5, ''x'')', :'orga_id', :'pa', :'wa'), 'لست عضوًا', 'adjust_inventory_stock(org A) is refused');

-- ============================================================
-- 3. RPCs on the attacker's OWN org but with org A's record ids (IDOR)
-- ============================================================
select t.throws(format('select create_sales_invoice(%L, %L, %L, null, null, %L::jsonb, 0, 0, 0, null, null, null)', :'orgb_id', :'ca', :'wa',
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 1, 'unit_price', 1, 'discount', 0))::text), 'لا ينتمي', 'sale with org A customer/warehouse/product is refused');
select t.throws(format('select record_treasury_movement(%L, %L, ''out'', 777, null, ''attack'')', :'orgb_id', :'accta'), 'لا ينتمي', 'movement onto org A cashbox is refused');
select t.throws(format('select record_partner_withdrawal(%L, %L, %L, 1, null, null, null)', :'orgb_id', :'para', :'accta'), 'لا ينتمي', 'withdrawal with org A partner is refused');
select t.throws(format('select create_expense(%L, %L, null, 1, null, null, ''x'', null)', :'orgb_id', :'cata'), 'لا ينتمي', 'expense with org A category is refused');
select t.throws(format('select adjust_inventory_stock(%L, %L, %L, 5, ''x'')', :'orgb_id', :'pa', :'wa'), 'لا ينتمي', 'stock adjustment on org A product is refused');

select t.as_owner();
select t.eq((select balance from treasury_balances where organization_id = :'orga_id'), :'casha_before'::numeric, 'org A cash balance is untouched by all of the above');
select t.as_user('c0000000-0000-0000-0000-00000000000b');

-- ============================================================
-- 4. Direct writes with manipulated ids
-- ============================================================
select t.eq(t.affected(format('update customers set name = ''hacked'' where id = %L', :'ca')), 0, 'UPDATE of org A customer touches 0 rows');
select t.eq(t.affected(format('delete from customers where id = %L', :'ca')), 0, 'DELETE of org A customer touches 0 rows');
select t.eq(t.affected(format('update product_prices set selling_price = 1 where product_id = %L', :'pa')), 0, 'price change on org A product touches 0 rows');
select t.throws(format('insert into customers (organization_id, name) values (%L, ''plant'')', :'orga_id'), 'row-level security', 'INSERT into org A is refused by RLS');
select t.throws(format('insert into organization_users (organization_id, user_id, role_id) values (%L, %L, (select id from roles where key = ''owner'' and organization_id is null))', :'orga_id', 'c0000000-0000-0000-0000-00000000000b'), 'مالك', 'cannot add yourself to org A as owner (blocked before RLS is even reached)');
select t.throws('select ensure_default_treasury_account(''' || :'orga_id' || ''')', 'permission denied', 'internal helper is not callable by users');

select t.as_anon();
select t.throws('select * from customers', 'permission denied', 'anon cannot read customers');
select t.throws('select * from sales_invoices', 'permission denied', 'anon cannot read invoices');
select t.throws(format('select ensure_default_treasury_account(%L)', :'orga_id'), 'permission denied', 'anon cannot call the internal helper');
select t.throws(format('select create_expense(%L, null, null, 1, null, null, ''x'', null)', :'orga_id'), 'permission denied', 'anon cannot call RPCs');

-- ============================================================
-- 5. Privilege escalation inside an organization (§50)
--    carol = storekeeper, dave = sales rep, alice = owner.  Only an owner holds manage_settings, so a
--    non-owner cannot touch ANY membership row: RLS hides the rows (0 affected) or refuses the insert.
-- ============================================================
select t.as_user('c0000000-0000-0000-0000-00000000000c');
select t.eq(t.affected(format('delete from organization_users where organization_id = %L and user_id = %L', :'orga_id', 'c0000000-0000-0000-0000-00000000000a')), 0, 'a non-owner cannot remove the owner');
select t.eq(t.affected(format('update organization_users set role_id = (select id from roles where key = ''owner'' and organization_id is null) where organization_id = %L and user_id = %L', :'orga_id', 'c0000000-0000-0000-0000-00000000000c')), 0, 'a non-owner cannot promote themselves to owner');
select t.eq(t.affected(format('update organization_users set status = ''disabled'' where organization_id = %L and user_id = %L', :'orga_id', 'c0000000-0000-0000-0000-00000000000a')), 0, 'a non-owner cannot disable the owner');
select t.throws(format('insert into organization_users (organization_id, user_id, role_id) values (%L, %L, (select id from roles where key = ''owner'' and organization_id is null))', :'orga_id', 'c0000000-0000-0000-0000-00000000000b'), 'المالك', 'a non-owner cannot add a new owner');
select t.eq(t.affected(format('update organization_users set status = ''disabled'' where organization_id = %L and user_id = %L', :'orga_id', 'c0000000-0000-0000-0000-00000000000d')), 0, 'a non-owner cannot manage ordinary members either');

select t.as_user('c0000000-0000-0000-0000-00000000000a');
select t.throws(format('delete from organization_users where organization_id = %L and user_id = %L', :'orga_id', 'c0000000-0000-0000-0000-00000000000a'), 'بدون مالك', 'the last owner cannot remove themselves');
select t.throws(format('update organization_users set role_id = (select id from roles where key = ''sales'' and organization_id is null) where organization_id = %L and user_id = %L', :'orga_id', 'c0000000-0000-0000-0000-00000000000a'), 'بدون مالك', 'the last owner cannot demote themselves');
-- With a second owner in place, the first may step down.
select t.eq(t.affected(format('update organization_users set role_id = (select id from roles where key = ''owner'' and organization_id is null) where organization_id = %L and user_id = %L', :'orga_id', 'c0000000-0000-0000-0000-00000000000d')), 1, 'an owner can appoint another owner');
select t.eq(t.affected(format('update organization_users set role_id = (select id from roles where key = ''sales'' and organization_id is null) where organization_id = %L and user_id = %L', :'orga_id', 'c0000000-0000-0000-0000-00000000000a')), 1, 'an owner can step down once another owner exists');

select t.as_owner();
