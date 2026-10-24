\set ON_ERROR_STOP on
select t.as_owner();
insert into auth.users (id, email) values
 ('20000000-0000-0000-0000-000000000001','owner@ui.test'),('20000000-0000-0000-0000-000000000002','keeper@ui.test'),
 ('20000000-0000-0000-0000-000000000003','rep@ui.test'),('20000000-0000-0000-0000-000000000004','rep2@ui.test');
select t.as_user('20000000-0000-0000-0000-000000000001');
select create_organization('شركة التجربة','trading','EG','EGP','ar',array['products','warehouses','customers','suppliers','sales','purchases','inventory','representatives','treasury','reports']) as org \gset
select t.as_owner();
insert into organization_users(organization_id,user_id,role_id,status)
select :'org', u.id, r.id, 'active' from (values ('20000000-0000-0000-0000-000000000002'::uuid,'warehouse'),('20000000-0000-0000-0000-000000000003','sales'),('20000000-0000-0000-0000-000000000004','sales')) u(id,k) join roles r on r.key=u.k and r.organization_id is null;
select t.as_user('20000000-0000-0000-0000-000000000001');
insert into warehouses(organization_id,name) values (:'org','المخزن الرئيسي') returning id as w \gset
insert into suppliers(organization_id,name) values (:'org','مورد النيل') returning id as s \gset
insert into products(organization_id,name,unit) values (:'org','زيت عباد الشمس','كرتونة') returning id as p1 \gset
insert into products(organization_id,name,unit) values (:'org','سكر','كيس') returning id as p2 \gset
insert into product_prices(organization_id,product_id,selling_price) values (:'org',:'p1',250),(:'org',:'p2',40);
insert into product_costs(product_id,cost) values (:'p1',200),(:'p2',30);
insert into sales_representatives(organization_id,name,user_id,commission_basis,commission_rate) values (:'org','أحمد المندوب','20000000-0000-0000-0000-000000000003','net_sales',5) returning id as rep1 \gset
insert into sales_representatives(organization_id,name,user_id,commission_basis,commission_rate) values (:'org','سعيد المندوب','20000000-0000-0000-0000-000000000004','net_sales',5) returning id as rep2 \gset
insert into customers(organization_id,name,sales_rep_id) values (:'org','مطعم الأمل',:'rep1') returning id as c1 \gset
insert into customers(organization_id,name,sales_rep_id) values (:'org','بقالة النور',:'rep2') returning id as c2 \gset
select t.as_owner();
select t.autoconfirm_on();
select t.as_user('20000000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org',:'s',:'w','OPEN-1','2026-01-01',jsonb_build_array(jsonb_build_object('product_id',:'p1','quantity',500,'unit_cost',200,'discount',0),jsonb_build_object('product_id',:'p2','quantity',500,'unit_cost',30,'discount',0)),0,0,0,'نقدًا',null) \gset
select t.as_owner();
select t.autoconfirm_off();
delete from notifications;
create table ui_ctx as select :'org'::uuid org, :'w'::uuid w, :'p1'::uuid p1, :'p2'::uuid p2, :'c1'::uuid c1, :'c2'::uuid c2, :'rep1'::uuid rep1, :'s'::uuid s;
grant select on ui_ctx to public;
-- TEST-ONLY bridge standing in for Supabase Realtime's WAL reader: announces every notifications change
create or replace function ui_notify() returns trigger language plpgsql as $$
begin perform pg_notify('ntf', json_build_object('id', NEW.id, 'op', TG_OP)::text); return null; end $$;
create trigger ui_notify after insert or update on notifications for each row execute function ui_notify();
create role authenticator login password 'auth' noinherit;
grant anon, authenticated to authenticator;
