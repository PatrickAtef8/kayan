-- A rep can only create / assign invoices to themselves unless they hold sales.assign_any_rep (0033)
select * from lab.ctx \gset
select * from lab.u \gset
select id as sales_role from roles where key='sales' and organization_id is null \gset
select lab.as_owner() \gset
delete from role_permissions where permission_key='sales.assign_any_rep' and role_id=:'sales_role';
delete from role_sales_limits;
insert into role_sales_limits(organization_id,role_id,max_discount_pct,can_give_manual_bonus) values (:'org_a',:'sales_role',NULL,true);

create or replace function lab.rep_of(p_num text) returns uuid language sql security definer as
  $$ select sales_rep_id from sales_invoices where invoice_number = p_num $$;
-- "never ends up on someone else": either refused, or recorded under the caller's own rep
create or replace function lab.not_on(p_res text, p_num text, p_other uuid) returns boolean language sql security definer as
  $$ select p_res like 'denied%' or coalesce((select sales_rep_id from sales_invoices where invoice_number = p_num) is distinct from p_other, true) $$;
grant execute on function lab.rep_of(text), lab.not_on(text, text, uuid) to authenticated;
-- linked reps
select lab.check('repassign','rep: own customer, no explicit rep -> allowed', lab.sale(:'rep','RA-1',:'cust_a',100)='ALLOWED');
select lab.as_owner() \gset
select lab.check('repassign','... and it is recorded under the rep', (select sales_rep_id from sales_invoices where invoice_number='RA-1')=:'rep_a');
select lab.check('repassign','rep: explicit OWN rep -> allowed', lab.sale(:'rep','RA-2',:'cust_a',100,0,0,:'rep_a')='ALLOWED');
select lab.check('repassign','rep: assigning to ANOTHER rep is REFUSED', lab.sale(:'rep','RA-3',:'cust_a',100,0,0,:'rep_b') like 'denied%');
select lab.check('repassign','... and no invoice was created', lab.rep_of('RA-3') is null);
select lab.check('repassign','rep: invoicing ANOTHER rep''s customer BLOCKED', lab.sale(:'rep','RA-4',:'cust_b',100) like 'denied%');
select lab.check('repassign','rep2: own customer allowed', lab.sale(:'rep2','RA-5',:'cust_b',100)='ALLOWED');
select lab.check('repassign','rep2: assigning to rep_a is REFUSED', lab.sale(:'rep2','RA-6',:'cust_b',100,0,0,:'rep_a') like 'denied%');

-- unlinked sales user (no override)
select lab.check('repassign','unlinked sales user (no rep record): cannot invoice at all', lab.sale(:'plain','RA-7',:'cust_a',100) like 'denied%');
select lab.as_owner() \gset
select lab.check('repassign','... and no invoice was left behind', (select count(*) from sales_invoices where invoice_number='RA-7')=0);
select lab.check('repassign','unlinked: explicit rep equal to default BLOCKED too', lab.sale(:'plain','RA-8',:'cust_a',100,0,0,:'rep_a') like 'denied%');
select lab.check('repassign','unlinked: a DIFFERENT rep BLOCKED', lab.sale(:'plain','RA-9',:'cust_a',100,0,0,:'rep_b') like 'denied%');
select lab.check('repassign','unlinked: rep on a customer with no rep BLOCKED', lab.sale(:'plain','RA-10',:'cust_n',100,0,0,:'rep_a') like 'denied%');
select lab.check('repassign','unlinked: customer with no rep BLOCKED (no longer an open door)', lab.sale(:'plain','RA-11',:'cust_n',100) like 'denied%');

-- override holders (owner/admin by default)
select lab.check('repassign','admin (override by default) can assign any rep', lab.sale(:'admin','RA-12',:'cust_a',100,0,0,:'rep_b')='ALLOWED');
select lab.check('repassign','owner can assign any rep', lab.sale(:'owner_a','RA-13',:'cust_a',100,0,0,:'rep_b')='ALLOWED');
select lab.as_owner() \gset
select lab.check('repassign','... assignment recorded as requested', (select sales_rep_id from sales_invoices where invoice_number='RA-12')=:'rep_b');

-- grant the explicit override to the sales role, then take it away again
select lab.as_owner() \gset
insert into role_permissions values ((select id from roles where key='sales' and organization_id is null),'sales.assign_any_rep');
select lab.check('repassign','OVERRIDE granted: restricted rep can assign another rep', lab.sale(:'rep','RA-14',:'cust_a',100,0,0,:'rep_b')='ALLOWED');
select lab.as_owner() \gset
select lab.check('repassign','... recorded under the other rep', (select sales_rep_id from sales_invoices where invoice_number='RA-14')=:'rep_b');
select lab.check('repassign','OVERRIDE granted: unlinked user can assign any rep', lab.sale(:'plain','RA-15',:'cust_n',100,0,0,:'rep_a')='ALLOWED');
select lab.as_owner() \gset
delete from role_permissions where permission_key='sales.assign_any_rep' and role_id=(select id from roles where key='sales' and organization_id is null);
select lab.check('repassign','OVERRIDE actually removed', (select count(*) from role_permissions where permission_key='sales.assign_any_rep' and role_id=:'sales_role')=0);
select lab.check('repassign','OVERRIDE removed: rep back to own rep only', lab.not_on(lab.sale(:'rep','RA-16',:'cust_a',100,0,0,:'rep_b'),'RA-16',:'rep_b'));
select lab.check('repassign','OVERRIDE removed: unlinked blocked again', lab.sale(:'plain','RA-17',:'cust_n',100,0,0,:'rep_a') like 'denied%');

-- customers.sales_rep_id (who owns the customer)
select lab.as_user(:'rep') \gset
select lab.check('repassign','rep cannot hand their customer to another rep', lab.try(format($q$update customers set sales_rep_id=%L where id=%L$q$,:'rep_b',:'cust_a')) like 'denied%' or (select sales_rep_id from customers where id=:'cust_a')=:'rep_a');
select lab.as_owner() \gset
select lab.check('repassign','... customer still belongs to rep_a', (select sales_rep_id from customers where id=:'cust_a')=:'rep_a');
select lab.as_user(:'plain') \gset
select lab.check('repassign','unlinked user cannot assign a customer to a rep (the row is not even visible: 0 rows touched)', lab.val(format($q$with u as (update customers set sales_rep_id=%L where id=%L returning 1) select count(*) from u$q$,:'rep_a',:'cust_n'))='0');
select lab.check('repassign','unlinked user cannot create a customer already assigned to a rep', lab.try(format($q$insert into customers(organization_id,name,sales_rep_id) values (%L,'RA-new-1',%L)$q$,:'org_a',:'rep_a')) like 'denied%');
select lab.check('repassign','unlinked user cannot create a customer either', lab.try(format($q$insert into customers(organization_id,name) values (%L,'RA-new-2')$q$,:'org_a')) like 'denied%');
select lab.as_user(:'admin') \gset
select lab.check('repassign','admin can reassign a customer', lab.val(format($q$with u as (update customers set sales_rep_id=%L where id=%L returning 1) select count(*) from u$q$,:'rep_b',:'cust_n'))='1');
select lab.as_user(:'owner_a') \gset
select lab.check('repassign','owner can reassign a customer', lab.val(format($q$with u as (update customers set sales_rep_id=NULL where id=%L returning 1) select count(*) from u$q$,:'cust_n'))='1');
select lab.as_user(:'rep') \gset
select lab.try(format($q$insert into customers(organization_id,name) values (%L,'RA-new-rep')$q$,:'org_a')) as ins1 \gset
select lab.try(format($q$insert into customers(organization_id,name,sales_rep_id) values (%L,'RA-new-rep2',%L)$q$,:'org_a',:'rep_b')) as ins2 \gset
select lab.as_owner() \gset
-- (separate statements: one SQL statement cannot see rows it inserted itself)
select lab.check('repassign','rep creating a customer: BLOCKED (customers are created by the owner only)', :'ins1' like 'denied%');
select lab.check('repassign','... and no customer row appeared', (select count(*) from customers where name='RA-new-rep')=0);
select lab.check('repassign','rep cannot create a customer for another rep (refused, or forced to own rep)', :'ins2' like 'denied%' or (select sales_rep_id from customers where name='RA-new-rep2') is distinct from :'rep_b');
select lab.check('repassign','... never ends up on rep_b', (select count(*) from customers where name='RA-new-rep2' and sales_rep_id=:'rep_b')=0);
-- direct tampering with an existing invoice
select lab.as_user(:'rep') \gset
select lab.check('repassign','rep cannot re-assign an existing invoice directly', lab.val(format($q$with u as (update sales_invoices set sales_rep_id=%L where invoice_number='RA-1' returning 1) select count(*) from u$q$,:'rep_b')) in ('0') or lab.try(format($q$update sales_invoices set sales_rep_id=%L where invoice_number='RA-1'$q$,:'rep_b')) like 'denied%');
select lab.as_owner() \gset
select lab.check('repassign','... invoice RA-1 still belongs to rep_a', (select sales_rep_id from sales_invoices where invoice_number='RA-1')=:'rep_a');
