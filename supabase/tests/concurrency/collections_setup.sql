-- Owner, two reps (one customer each), two storekeepers, product A with 100 on hand, a PENDING purchase invoice of 50 units
-- (waiting for the storekeeper), and one unpaid 1 000 EGP sales invoice for rep 1's customer. Test-only auto-confirm is OFF.
\set ON_ERROR_STOP on
select t.as_owner();
insert into auth.users (id, email) values
  ('98000000-0000-0000-0000-000000000001', 'owner@cl.test'),
  ('98000000-0000-0000-0000-000000000002', 'rep1@cl.test'),
  ('98000000-0000-0000-0000-000000000003', 'rep2@cl.test'),
  ('98000000-0000-0000-0000-000000000004', 'keeper1@cl.test'),
  ('98000000-0000-0000-0000-000000000005', 'keeper2@cl.test');
select t.as_user('98000000-0000-0000-0000-000000000001');
select create_organization('شركة التحصيل المتزامن', 'تجارة', 'EG', 'EGP', 'ar', array['sales','customers','inventory','purchases','suppliers','representatives','treasury']) as id \gset org_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', u, r.id, 'active'
from (values ('98000000-0000-0000-0000-000000000002'::uuid, 'sales'), ('98000000-0000-0000-0000-000000000003', 'sales'),
             ('98000000-0000-0000-0000-000000000004', 'warehouse'), ('98000000-0000-0000-0000-000000000005', 'warehouse')) v(u, k)
join roles r on r.key = v.k and r.organization_id is null;
select t.as_user('98000000-0000-0000-0000-000000000001');
insert into warehouses (organization_id, name) values (:'org_id', 'الرئيسي') returning id as w1 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as sup \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'A', 'A', 'قطعة') returning id as pa \gset
insert into product_prices (organization_id, product_id, selling_price) values (:'org_id', :'pa', 100);
insert into product_costs (product_id, cost) values (:'pa', 5);
insert into sales_representatives (organization_id, name, user_id, commission_basis, commission_rate) values (:'org_id', 'مندوب 1', '98000000-0000-0000-0000-000000000002', 'collected_amount', 10) returning id as r1 \gset
insert into sales_representatives (organization_id, name, user_id) values (:'org_id', 'مندوب 2', '98000000-0000-0000-0000-000000000003') returning id as r2 \gset
insert into customers (organization_id, name, sales_rep_id) values (:'org_id', 'عميل 1', :'r1') returning id as c1 \gset
insert into customers (organization_id, name, sales_rep_id) values (:'org_id', 'عميل 2', :'r2') returning id as c2 \gset

select t.as_owner();
select t.autoconfirm_on();
select t.as_user('98000000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'CL-P0', current_date,
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 100, 'unit_cost', 5, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset p0_
select t.as_owner();
select t.autoconfirm_off();

-- a purchase invoice that is still waiting for the storekeeper
select t.as_user('98000000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'CL-P1', current_date,
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 50, 'unit_cost', 5, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset p1_

-- the unpaid sales invoice (1 000)
select t.as_user('98000000-0000-0000-0000-000000000002');
select create_sales_invoice(:'org_id', :'c1', :'w1', 'CL-S1', current_date,
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 10, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset s1_
select t.as_owner();
drop table if exists t.cl_ids;
create table t.cl_ids as select :'org_id'::uuid as org, :'w1'::uuid as w1, :'pa'::uuid as pa, :'c1'::uuid as c1, :'c2'::uuid as c2,
  :'s1_id'::uuid as s1, :'p1_id'::uuid as p1, :'sup'::uuid as sup, :'r1'::uuid as r1;
grant select on t.cl_ids to authenticated;
