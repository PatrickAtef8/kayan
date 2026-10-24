-- Realistic data created with the PRE-batch (≤ 0036) functions: multiple costs, sales, both kinds of
-- returns, a transfer, adjustments both ways and a purchase return. Used by upgrade_check.sh.
\set ON_ERROR_STOP on
select t.as_owner();
insert into auth.users (id, email) values ('99000000-0000-0000-0000-000000000001', 'owner@upg.test');
select t.as_user('99000000-0000-0000-0000-000000000001');
select create_organization('شركة الترقية', 'تجارة', 'EG', 'EGP', 'ar',
  array['sales','customers','inventory','purchases','suppliers','expenses','treasury']) as id \gset org_
insert into warehouses (organization_id, name) values (:'org_id', 'الرئيسي') returning id as w1 \gset
insert into warehouses (organization_id, name) values (:'org_id', 'الفرعي') returning id as w2 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as sup \gset
insert into customers (organization_id, name) values (:'org_id', 'عميل') returning id as cus \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'أ', 'A', 'قطعة') returning id as pa \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'ب', 'B', 'قطعة') returning id as pb \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'ج', 'C', 'قطعة') returning id as pc \gset
insert into product_prices (organization_id, product_id, selling_price) select :'org_id', id, 100 from products where organization_id = :'org_id';

-- two purchases of A at different costs (weighted average), one of B and C
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'U-P1', current_date,
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 100, 'unit_cost', 40, 'discount_pct', 0),
                    jsonb_build_object('product_id', :'pb', 'quantity', 50, 'unit_cost', 10, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset p1_
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'U-P2', current_date,
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 60, 'unit_cost', 46, 'discount_pct', 5),
                    jsonb_build_object('product_id', :'pc', 'quantity', 25, 'unit_cost', 7, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset p2_
select create_sales_invoice(:'org_id', :'cus', :'w1', 'U-S1', current_date,
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 70, 'unit_price', 100, 'discount_pct', 0),
                    jsonb_build_object('product_id', :'pb', 'quantity', 12, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset s1_
select create_stock_transfer(:'org_id', :'w1', :'w2', current_date, jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 30), jsonb_build_object('product_id', :'pc', 'quantity', 5)), null) as id \gset tr_
select adjust_inventory_stock(:'org_id', :'pb', :'w1', 7, 'جرد زيادة') as id \gset adj1_
select adjust_inventory_stock(:'org_id', :'pa', :'w1', -3, 'جرد عجز') as id \gset adj2_
select create_sales_return(:'org_id', :'s1_id', current_date,
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'s1_id' and product_id = :'pa'), 'quantity', 4, 'condition', 'resalable')), 0, null) as id \gset r1_
select pg_sleep(5.5);
select create_sales_return(:'org_id', :'s1_id', current_date,
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'s1_id' and product_id = :'pb'), 'quantity', 2, 'condition', 'damaged')), 0, null) as id \gset r2_
select create_purchase_return(:'org_id', :'p2_id', current_date,
  jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', (select id from purchase_invoice_items where purchase_invoice_id = :'p2_id' and product_id = :'pc'), 'quantity', 3)), 0, null) as id \gset pr_
-- a product that is out of stock and one that was never stocked
select create_sales_invoice(:'org_id', :'cus', :'w1', 'U-S2', current_date,
  jsonb_build_array(jsonb_build_object('product_id', :'pc', 'quantity', 17, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset s2_
select t.as_owner();
drop table if exists t.upg_ids;
create table t.upg_ids as select :'org_id'::uuid as org, :'w1'::uuid as w1, :'w2'::uuid as w2, :'cus'::uuid as cus, :'pa'::uuid as pa, :'s1_id'::uuid as s1;
grant select on t.upg_ids to authenticated;
