\set ON_ERROR_STOP on
select t.as_owner();
insert into auth.users (id, email) values ('98000000-0000-0000-0000-000000000001', 'owner@cc.test');
select t.as_user('98000000-0000-0000-0000-000000000001');
select create_organization('شركة التزامن', 'تجارة', 'EG', 'EGP', 'ar',
  array['sales','customers','inventory','purchases','suppliers','expenses','treasury']) as id \gset org_
insert into warehouses (organization_id, name) values (:'org_id', 'الرئيسي') returning id as w1 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as sup \gset
insert into customers (organization_id, name) values (:'org_id', 'عميل') returning id as cus \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'A', 'A', 'قطعة') returning id as pa \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'B', 'B', 'قطعة') returning id as pb \gset
insert into product_prices (organization_id, product_id, selling_price) select :'org_id', id, 100 from products where organization_id = :'org_id';
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'CC-P1', current_date,
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 20, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (current_date + 30)::text),
                    jsonb_build_object('product_id', :'pb', 'quantity', 10, 'unit_cost', 5, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset p1_
select start_stocktake(:'org_id', :'w1') as id \gset st1_
select save_stocktake_counts(:'org_id', :'st1_id', jsonb_build_array(
  jsonb_build_object('line_id', (select id from stocktake_lines where stocktake_id = :'st1_id' and product_id = :'pa'), 'counted_qty', 18),
  jsonb_build_object('line_id', (select id from stocktake_lines where stocktake_id = :'st1_id' and product_id = :'pb'), 'counted_qty', 9))) as n \gset
select t.as_owner();
drop table if exists t.cc_ids;
create table t.cc_ids as select :'org_id'::uuid as org, :'w1'::uuid as w1, :'cus'::uuid as cus, :'pa'::uuid as pa, :'pb'::uuid as pb, :'st1_id'::uuid as st1;
grant select on t.cc_ids to authenticated;
