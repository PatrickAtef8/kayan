-- two tenants, nine personas, products with a known cost (60) and list price (100)
\set ON_ERROR_STOP on
insert into auth.users(id, email) values
 ('aaaaaaaa-0000-0000-0000-000000000001','ownerA@a.test'),
 ('aaaaaaaa-0000-0000-0000-000000000002','rep@a.test'),         -- sales role, linked to rep_a
 ('aaaaaaaa-0000-0000-0000-000000000003','warehouse@a.test'),
 ('aaaaaaaa-0000-0000-0000-000000000004','owner2@a.test'),
 ('aaaaaaaa-0000-0000-0000-000000000005','plainsales@a.test'),  -- sales role, NOT linked to any rep
 ('aaaaaaaa-0000-0000-0000-000000000006','admin@a.test'),
 ('aaaaaaaa-0000-0000-0000-000000000007','rep2@a.test'),        -- sales role, linked to rep_b
 ('bbbbbbbb-0000-0000-0000-000000000001','ownerB@b.test'),
 ('cccccccc-0000-0000-0000-000000000001','attacker@evil.test'),
 ('dddddddd-0000-0000-0000-000000000001','innocent@victim.test');

select lab.as_user('aaaaaaaa-0000-0000-0000-000000000001') \gset
select create_organization('Org A','trading','EG','EGP','ar',array['products','warehouses','customers','suppliers','sales','purchases','inventory','expenses','treasury','representatives','partners','reports']) as org_a \gset
select lab.as_user('bbbbbbbb-0000-0000-0000-000000000001') \gset
select create_organization('Org B','trading','EG','EGP','ar',array['products','warehouses','customers','sales','reports']) as org_b \gset
select lab.as_owner() \gset

insert into organization_users(organization_id,user_id,role_id,status)
select :'org_a', u.id, r.id, 'active'
from (values ('aaaaaaaa-0000-0000-0000-000000000002'::uuid,'sales'),('aaaaaaaa-0000-0000-0000-000000000003','warehouse'),
             ('aaaaaaaa-0000-0000-0000-000000000004','owner'),('aaaaaaaa-0000-0000-0000-000000000005','sales'),
             ('aaaaaaaa-0000-0000-0000-000000000006','owner'),('aaaaaaaa-0000-0000-0000-000000000007','sales')) u(id,k)
join roles r on r.key = u.k and r.organization_id is null;

select lab.as_user('aaaaaaaa-0000-0000-0000-000000000001') \gset
insert into suppliers(organization_id,name) values (:'org_a','Supplier A') returning id as sup_a \gset
insert into warehouses(organization_id,name) values (:'org_a','WH A') returning id as wh_a \gset
insert into products(organization_id,name,sku) values (:'org_a','Widget','W1') returning id as prod_a \gset
insert into product_prices(organization_id,product_id,selling_price) values (:'org_a',:'prod_a',100);
insert into product_costs(product_id,cost) values (:'prod_a',60);   -- cost lives in the protected table (0034)
insert into sales_representatives(organization_id,name,commission_basis,commission_rate,user_id) values (:'org_a','Rep One','collected_amount',10,'aaaaaaaa-0000-0000-0000-000000000002') returning id as rep_a \gset
insert into sales_representatives(organization_id,name,commission_basis,commission_rate,user_id) values (:'org_a','Rep Two','collected_amount',10,'aaaaaaaa-0000-0000-0000-000000000007') returning id as rep_b \gset
insert into customers(organization_id,name,sales_rep_id) values (:'org_a','Cust of Rep One',:'rep_a') returning id as cust_a \gset
insert into customers(organization_id,name,sales_rep_id) values (:'org_a','Cust of Rep Two',:'rep_b') returning id as cust_b \gset
insert into customers(organization_id,name) values (:'org_a','Cust no rep') returning id as cust_n \gset
insert into partners(organization_id,name) values (:'org_a','Partner') returning id as partner_a \gset
-- stock: 1000 units @ cost 60
select create_purchase_invoice(org_id:=:'org_a',p_supplier_id:=:'sup_a',p_warehouse_id:=:'wh_a',p_invoice_number:='PI-1',p_invoice_date:=current_date,
  items:=jsonb_build_array(jsonb_build_object('product_id',:'prod_a','quantity',1000,'unit_cost',60)),p_discount_pct:=0,p_tax_total:=0,p_amount_paid:=0,p_payment_method:='cash',p_notes:=null) \gset
select record_partner_withdrawal(:'org_a',:'partner_a',null,5000,current_date,'owner draw','private') \gset
select create_expense(org_id:=:'org_a',p_category_id:=null,p_treasury_account_id:=null,p_amount:=1234,p_expense_date:=current_date,p_payment_method:='cash',p_description:='salary',p_responsible_user:=null) \gset
select lab.as_user('bbbbbbbb-0000-0000-0000-000000000001') \gset
insert into customers(organization_id,name) values (:'org_b','B customer') returning id as cust_bb \gset
select lab.as_owner() \gset

create table lab.ctx as select :'org_a'::uuid org_a, :'org_b'::uuid org_b, :'sup_a'::uuid sup_a, :'wh_a'::uuid wh_a, :'prod_a'::uuid prod_a,
  :'rep_a'::uuid rep_a, :'rep_b'::uuid rep_b, :'cust_a'::uuid cust_a, :'cust_b'::uuid cust_b, :'cust_n'::uuid cust_n, :'cust_bb'::uuid cust_bb;
grant select on lab.ctx to anon, authenticated;

-- persona ids as psql-friendly constants live in lab.u (so test files stay readable)
create table lab.u as select
 'aaaaaaaa-0000-0000-0000-000000000001'::uuid owner_a, 'aaaaaaaa-0000-0000-0000-000000000002'::uuid rep, 'aaaaaaaa-0000-0000-0000-000000000003'::uuid warehouse,
 'aaaaaaaa-0000-0000-0000-000000000004'::uuid accountant, 'aaaaaaaa-0000-0000-0000-000000000005'::uuid plain, 'aaaaaaaa-0000-0000-0000-000000000006'::uuid admin,
 'aaaaaaaa-0000-0000-0000-000000000007'::uuid rep2, 'bbbbbbbb-0000-0000-0000-000000000001'::uuid owner_b, 'cccccccc-0000-0000-0000-000000000001'::uuid attacker,
 'dddddddd-0000-0000-0000-000000000001'::uuid victim;
grant select on lab.u to anon, authenticated;

-- invoice helper: one line of Widget at an explicit price / discounts; returns 'ALLOWED' or 'denied: msg'
create or replace function lab.sale(p_user uuid, p_num text, p_customer uuid, p_price numeric, p_line_pct numeric default 0,
                                    p_inv_pct numeric default 0, p_rep uuid default null, p_qty numeric default 1,
                                    p_bonus jsonb default '[]') returns text language plpgsql as $$
declare c record; begin select * into c from lab.ctx;
  perform lab.as_user(p_user);
  perform create_sales_invoice(org_id:=c.org_a, p_customer_id:=p_customer, p_warehouse_id:=c.wh_a, p_invoice_number:=p_num, p_invoice_date:=current_date,
    items:=jsonb_build_array(jsonb_build_object('product_id',c.prod_a,'quantity',p_qty,'unit_price',p_price,'discount_pct',p_line_pct)),
    p_discount_pct:=p_inv_pct, p_tax_total:=0::numeric, p_amount_collected:=0::numeric, p_payment_method:='cash', p_notes:=null,
    p_sales_rep_id:=p_rep, p_bonus_items:=p_bonus);
  return 'ALLOWED';
exception when others then return 'denied: ' || sqlerrm; end $$;
grant execute on function lab.sale(uuid,text,uuid,numeric,numeric,numeric,uuid,numeric,jsonb) to authenticated;
