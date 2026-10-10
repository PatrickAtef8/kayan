-- Regression tests for the earlier critical/high findings (0030/0031)
select * from lab.ctx \gset
select * from lab.u \gset

-- H1: unauthenticated user enumeration
select lab.as_anon() \gset
select lab.check('regress','anon cannot call find_user_id_by_email', lab.try($q$select find_user_id_by_email('ownerA@a.test')$q$) like 'denied%');
select lab.as_user(:'attacker') \gset
select lab.check('regress','signed-in user cannot call find_user_id_by_email', lab.try($q$select find_user_id_by_email('ownerA@a.test')$q$) like 'denied%');

-- C1: permission catalog must not be writable
select id as sales_tpl from roles where organization_id is null and key='sales' \gset
select lab.check('regress','stranger cannot INSERT role_permissions', lab.try(format($q$insert into role_permissions(role_id,permission_key) values (%L,'manage_settings')$q$,:'sales_tpl')) like 'denied%');
select lab.check('regress','stranger cannot DELETE role_permissions', lab.val(format($q$with d as (delete from role_permissions where role_id=%L returning 1) select count(*) from d$q$,:'sales_tpl')) in ('0') or lab.try(format($q$delete from role_permissions where role_id=%L$q$,:'sales_tpl')) like 'denied%');
select lab.as_anon() \gset
select lab.check('regress','anon cannot INSERT role_permissions', lab.try(format($q$insert into role_permissions(role_id,permission_key) values (%L,'manage_settings')$q$,:'sales_tpl')) like 'denied%');
select lab.as_user(:'plain') \gset
select lab.check('regress','plain sales user did not gain manage_settings', not has_permission(:'org_a','manage_settings'));

-- H2: forced enrolment
select lab.as_user(:'attacker') \gset
select create_organization('Evil','x','EG','EGP','ar',array['sales']) as evil \gset
select lab.check('regress','add_team_member only INVITES an existing user', (add_team_member(:'evil','innocent@victim.test',(select id from roles where key='sales' and organization_id is null)))->>'status' = 'added');
select lab.as_owner() \gset
select lab.check('regress','victim has 0 ACTIVE memberships after enrolment', (select count(*) from organization_users where user_id=:'victim' and status='active')=0);
select lab.check('regress','victim has 1 pending invitation', (select count(*) from organization_users where user_id=:'victim' and status='invited')=1);
select lab.as_user(:'attacker') \gset
select lab.check('regress','complete_team_invite with raw user id only invites', lab.try(format($q$select complete_team_invite(%L,%L,(select id from roles where key='sales' and organization_id is null))$q$,:'evil',:'owner_a'))='ALLOWED');
select lab.as_owner() \gset
select lab.check('regress','real owner NOT made active in attacker org', (select count(*) from organization_users where user_id=:'owner_a' and status='active')=1);
select lab.as_user(:'victim') \gset
select lab.check('regress','victim can accept the invite', lab.try(format($q$select accept_org_invite(%L)$q$,:'evil'))='ALLOWED');
select lab.check('regress','victim can leave again', lab.val(format($q$with d as (delete from organization_users where user_id=%L and organization_id=%L returning 1) select count(*) from d$q$,:'victim',:'evil'))='1');

-- H3: NaN / Infinity poisoning (owner is unlimited, so only the NaN guard can stop it)
select lab.check('regress','NaN unit price rejected', lab.sale(:'owner_a','R-NAN1',:'cust_n','NaN') like 'denied%');
select lab.check('regress','NaN quantity rejected', lab.sale(:'owner_a','R-NAN2',:'cust_n',100,0,0,null,'NaN') like 'denied%');
select lab.check('regress','Infinity price rejected', lab.sale(:'owner_a','R-INF',:'cust_n','Infinity') like 'denied%');
select lab.as_owner() \gset
select lab.check('regress','no NaN reached the tenant totals', (select count(*) from sales_invoices where total = 'NaN'::numeric)=0);

-- H4: finance tables are not readable by roles without finance permissions
create or replace function lab.fin_rows() returns bigint language sql as
 $$ select (select count(*) from partner_withdrawals)+(select count(*) from expenses)+(select count(*) from treasury_movements)+(select count(*) from purchase_invoices) $$;
grant execute on function lab.fin_rows() to authenticated;
select lab.as_user(:'warehouse') \gset
select lab.check('regress','warehouse reads 0 finance rows', lab.fin_rows()=0);
select lab.as_user(:'plain') \gset
select lab.check('regress','plain sales reads 0 finance rows', lab.fin_rows()=0);
select lab.as_user(:'rep') \gset
select lab.check('regress','restricted rep reads 0 finance rows', lab.fin_rows()=0);
select lab.as_user(:'accountant') \gset
select lab.check('regress','accountant still reads finance rows', lab.fin_rows()>0);
select lab.as_user(:'owner_a') \gset
select lab.check('regress','owner still reads finance rows', lab.fin_rows()>0);
select lab.as_user(:'warehouse') \gset
select lab.check('regress','warehouse cannot change product prices', lab.val(format($q$with u as (update product_prices set selling_price=1 where organization_id=%L returning 1) select count(*) from u$q$,:'org_a'))='0');

-- cross-tenant
select lab.as_user(:'owner_b') \gset
select lab.check('regress','tenant B reads nothing of tenant A', (select count(*) from customers where organization_id=:'org_a')=0 and (select count(*) from sales_invoices where organization_id=:'org_a')=0);
select lab.check('regress','tenant B cannot invoice A customer', lab.try(format($q$select create_sales_invoice(org_id:=%L,p_customer_id:=%L,p_warehouse_id:=(select id from warehouses where organization_id=%L limit 1),p_invoice_number:='X',p_invoice_date:=current_date,items:='[]'::jsonb,p_discount_pct:=0,p_tax_total:=0,p_amount_collected:=0,p_payment_method:='c',p_notes:=null)$q$,:'org_b',:'cust_a',:'org_b')) like 'denied%');
select lab.as_owner() \gset
