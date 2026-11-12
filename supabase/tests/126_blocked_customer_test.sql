-- 0076: a customer whose credit status is «blocked» cannot be given a NEW sales invoice — by any route —
-- while his existing debt can still be collected and his returns recorded. «watch» is only a warning.
\set ON_ERROR_STOP on
select t.autoconfirm_on();

select t.as_owner();
insert into auth.users (id, email) values ('12600000-0000-0000-0000-000000000001', 'blk-owner@blk.test');
select t.as_user('12600000-0000-0000-0000-000000000001');
select create_organization('شركة الحظر', 'x', 'EG', 'EGP', 'ar', array['sales','customers','inventory','purchases','suppliers','treasury']) as id \gset org_

insert into warehouses (organization_id, name) values (:'org_id', 'المخزن') returning id as wh \gset
insert into suppliers  (organization_id, name) values (:'org_id', 'مورد')  returning id as sup \gset
insert into products   (organization_id, name) values (:'org_id', 'منتج')  returning id as prod \gset
insert into customers (organization_id, name, credit_status) values (:'org_id', 'عميل جيد',     'good')    returning id as c_good \gset
insert into customers (organization_id, name, credit_status) values (:'org_id', 'عميل مراقب',   'watch')   returning id as c_watch \gset
insert into customers (organization_id, name, credit_status) values (:'org_id', 'عميل محظور',   'blocked') returning id as c_block \gset
insert into customers (organization_id, name, credit_status) values (:'org_id', 'عميل سيُحظر',  'good')    returning id as c_later \gset

select create_purchase_invoice(:'org_id', :'sup', :'wh', 'P-1', '2026-03-01',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 100, 'unit_cost', 100, 'discount', 0)), 0, 0, 10000, 'نقدًا', null) as id \gset

-- ---- good and watch customers are invoiced as before
select create_sales_invoice(:'org_id', :'c_good',  :'wh', 'S-1', '2026-03-10',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 2, 'unit_price', 200, 'discount', 0)), 0, 0, 0, null, null, null) as id \gset s1_
select t.eq((select count(*) from sales_invoices where id = :'s1_id'), 1, 'a good customer is invoiced');
select create_sales_invoice(:'org_id', :'c_watch', :'wh', 'S-2', '2026-03-10',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 2, 'unit_price', 200, 'discount', 0)), 0, 0, 0, null, null, null) as id \gset s2_
select t.eq((select count(*) from sales_invoices where id = :'s2_id'), 1, 'a customer on «watch» is still invoiced (warning only)');

-- ---- blocked: refused through the RPC (what both sales forms call)
select t.throws(
  format($q$select create_sales_invoice(%L, %L, %L, 'S-3', '2026-03-11', %L::jsonb, 0, 0, 0, null, null, null)$q$, :'org_id', :'c_block', :'wh',
         jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 1, 'unit_price', 200, 'discount', 0))::text),
  'محظور', 'a blocked customer cannot be invoiced through create_sales_invoice');
select t.throws(
  format($q$select create_sales_invoice(%L, %L, %L, null, '2026-03-11', %L::jsonb, 0, 0, 500, 'نقدًا', null, null)$q$, :'org_id', :'c_block', :'wh',
         jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 1, 'unit_price', 200, 'discount', 0))::text),
  'محظور', 'not even a cash sale (paid on the spot) to a blocked customer');

-- ---- and through a direct INSERT, as the table owner (nothing can route around the rule)
select t.as_owner();
select t.throws(
  format($q$insert into sales_invoices (organization_id, customer_id, warehouse_id, invoice_date) values (%L, %L, %L, '2026-03-11')$q$, :'org_id', :'c_block', :'wh'),
  'محظور', 'a direct INSERT for a blocked customer is refused too');
select t.as_user('12600000-0000-0000-0000-000000000001');

select t.eq((select count(*) from sales_invoices where customer_id = :'c_block'), 0, 'no invoice exists for the blocked customer');
select t.eq((select quantity from inventory_stock where product_id = :'prod'), 96, 'and no stock left for him (100 − 2 − 2)');

-- ---- an existing debt can still be collected and goods can still come back after the customer is blocked
select create_sales_invoice(:'org_id', :'c_later', :'wh', 'S-4', '2026-03-12',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 5, 'unit_price', 200, 'discount', 0)), 0, 0, 0, null, null, null) as id \gset s4_
select id as s4_item from sales_invoice_items where sales_invoice_id = :'s4_id' \gset
update customers set credit_status = 'blocked' where id = :'c_later';

select t.throws(
  format($q$select create_sales_invoice(%L, %L, %L, null, '2026-03-13', %L::jsonb, 0, 0, 0, null, null, null)$q$, :'org_id', :'c_later', :'wh',
         jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 1, 'unit_price', 200, 'discount', 0))::text),
  'محظور', 'once blocked, he gets no new invoice');
select record_customer_collection(:'org_id', :'c_later', :'s4_id', 300, '2026-03-14', 'نقدًا', null, null) as id \gset
select t.eq((select amount_paid from sales_invoices where id = :'s4_id'), 300, 'but a blocked customer can still pay what he owes');
select create_sales_return(:'org_id', :'s4_id', '2026-03-15',
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'s4_item', 'quantity', 1, 'condition', 'resalable')), 0, null) as id \gset
select t.eq((select count(*) from sales_returns where sales_invoice_id = :'s4_id'), 1, 'and his return is still recorded');

-- ---- unblocking restores invoicing
update customers set credit_status = 'good' where id = :'c_later';
select create_sales_invoice(:'org_id', :'c_later', :'wh', 'S-5', '2026-03-16',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 1, 'unit_price', 200, 'discount', 0)), 0, 0, 0, null, null, null) as id \gset s5_
select t.eq((select count(*) from sales_invoices where id = :'s5_id'), 1, 'after the status is changed back, he is invoiced again');
