-- A restricted rep who names ANOTHER rep gets a clear error and nothing is created (0035)
select * from lab.ctx \gset
select * from lab.u \gset
select id as sales_role from roles where key='sales' and organization_id is null \gset
select lab.as_owner() \gset
delete from role_permissions where permission_key='sales.assign_any_rep' and role_id=:'sales_role';
delete from role_sales_limits;
insert into role_sales_limits(organization_id,role_id,max_discount_pct,can_give_manual_bonus) values (:'org_a',:'sales_role',NULL,true);

select lab.sale(:'rep','EE-1',:'cust_a',100,0,0,:'rep_b') as e1 \gset
select lab.check('repexplicit','rep naming ANOTHER rep is REFUSED', :'e1' like 'denied%');
select lab.check('repexplicit','... with the clear message ("only in your own name")', :'e1' like '%باسمك فقط%');
select lab.sale(:'rep2','EE-2',:'cust_b',100,0,0,:'rep_a') as e2 \gset
select lab.check('repexplicit','rep2 naming rep_a is REFUSED with the same message', :'e2' like 'denied%' and :'e2' like '%باسمك فقط%');
select lab.sale(:'rep','EE-3',:'cust_b',100,0,0,:'rep_b') as e3 \gset
select lab.check('repexplicit','rep naming another rep on another rep''s customer is refused', :'e3' like 'denied%');
select lab.as_owner() \gset
select lab.check('repexplicit','NOTHING was created by the refused attempts', (select count(*) from sales_invoices where invoice_number in ('EE-1','EE-2','EE-3'))=0);

select lab.check('repexplicit','rep naming THEMSELVES is allowed', lab.sale(:'rep','EE-4',:'cust_a',100,0,0,:'rep_a')='ALLOWED');
select lab.check('repexplicit','rep naming nobody is allowed', lab.sale(:'rep','EE-5',:'cust_a',100)='ALLOWED');
select lab.as_owner() \gset
select lab.check('repexplicit','... both recorded under the rep', (select count(*) from sales_invoices where invoice_number in ('EE-4','EE-5') and sales_rep_id=:'rep_a')=2);

-- override holders are unaffected
insert into role_permissions values (:'sales_role','sales.assign_any_rep');
select lab.check('repexplicit','with the override a rep CAN name another rep', lab.sale(:'rep','EE-6',:'cust_a',100,0,0,:'rep_b')='ALLOWED');
select lab.as_owner() \gset
select lab.check('repexplicit','... recorded under the requested rep', (select sales_rep_id from sales_invoices where invoice_number='EE-6')=:'rep_b');
delete from role_permissions where permission_key='sales.assign_any_rep' and role_id=:'sales_role';
select lab.sale(:'rep','EE-7',:'cust_a',100,0,0,:'rep_b') as e7 \gset
select lab.check('repexplicit','override removed -> refused again', :'e7' like 'denied%' and :'e7' like '%باسمك فقط%');
select lab.check('repexplicit','owner and admin can still assign any rep', lab.sale(:'owner_a','EE-8',:'cust_a',100,0,0,:'rep_b')='ALLOWED' and lab.sale(:'admin','EE-9',:'cust_a',100,0,0,:'rep_b')='ALLOWED');
select lab.as_owner() \gset
