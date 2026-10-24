-- Two reps, one product with exactly 100 units on hand (confirmed), invoices RESERVE (auto-confirm OFF).
\set ON_ERROR_STOP on
select t.as_owner();
insert into auth.users (id, email) values
  ('99000000-0000-0000-0000-000000000001', 'owner@ov.test'),
  ('99000000-0000-0000-0000-000000000002', 'rep1@ov.test'),
  ('99000000-0000-0000-0000-000000000003', 'rep2@ov.test'),
  ('99000000-0000-0000-0000-000000000004', 'keeper@ov.test');
select t.as_user('99000000-0000-0000-0000-000000000001');
select create_organization('شركة التزامن 2', 'تجارة', 'EG', 'EGP', 'ar', array['sales','customers','inventory','purchases','suppliers','representatives']) as id \gset org_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', u, r.id, 'active'
from (values ('99000000-0000-0000-0000-000000000002'::uuid, 'sales'), ('99000000-0000-0000-0000-000000000003', 'sales'), ('99000000-0000-0000-0000-000000000004', 'warehouse')) v(u, k)
join roles r on r.key = v.k and r.organization_id is null;
select t.as_user('99000000-0000-0000-0000-000000000001');
insert into warehouses (organization_id, name) values (:'org_id', 'الرئيسي') returning id as w1 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as sup \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'A', 'A', 'قطعة') returning id as pa \gset
insert into product_prices (organization_id, product_id, selling_price) values (:'org_id', :'pa', 100);
insert into product_costs (product_id, cost) values (:'pa', 5);
insert into sales_representatives (organization_id, name, user_id) values (:'org_id', 'مندوب 1', '99000000-0000-0000-0000-000000000002') returning id as r1 \gset
insert into sales_representatives (organization_id, name, user_id) values (:'org_id', 'مندوب 2', '99000000-0000-0000-0000-000000000003') returning id as r2 \gset
insert into customers (organization_id, name, sales_rep_id) values (:'org_id', 'عميل 1', :'r1') returning id as c1 \gset
insert into customers (organization_id, name, sales_rep_id) values (:'org_id', 'عميل 2', :'r2') returning id as c2 \gset
select t.as_owner();
select t.autoconfirm_on();
select t.as_user('99000000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'OV-P1', current_date,
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 100, 'unit_cost', 5, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset p1_
select t.as_owner();
select t.autoconfirm_off();
drop table if exists t.ov_ids;
create table t.ov_ids as select :'org_id'::uuid as org, :'w1'::uuid as w1, :'pa'::uuid as pa, :'c1'::uuid as c1, :'c2'::uuid as c2;
grant select on t.ov_ids to authenticated;
