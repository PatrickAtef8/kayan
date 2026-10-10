-- customers/suppliers opening balance: protected READ and WRITE (0032)
select * from lab.ctx \gset
select * from lab.u \gset

-- setup (owner): a dedicated customer + supplier with balances
select lab.as_user(:'owner_a') \gset
insert into customers(organization_id,name) values (:'org_a','OB customer') returning id as c_ob \gset
insert into suppliers(organization_id,name) values (:'org_a','OB supplier') returning id as s_ob \gset
select lab.check('opening','owner can set a customer opening balance', lab.try(format($q$insert into customer_opening_balances(customer_id,amount) values (%L,750)$q$,:'c_ob'))='ALLOWED');
select lab.check('opening','owner can set a supplier opening balance', lab.try(format($q$insert into supplier_opening_balances(supplier_id,amount) values (%L,-120)$q$,:'s_ob'))='ALLOWED');
select lab.check('opening','balance view uses the new source (owner sees 750)', lab.val(format($q$select balance from customer_balances where customer_id=%L$q$,:'c_ob'))='750.00');
select lab.check('opening','supplier balance view uses the new source (-120)', lab.val(format($q$select balance from supplier_balances where supplier_id=%L$q$,:'s_ob'))='-120.00');
select lab.check('opening','report_customer_analysis still carries the opening balance', lab.val(format($q$select report_customer_analysis(%L,%L)::text like '%%750%%'$q$,:'org_a',:'c_ob'))='true');
select lab.check('opening','report_party_ledger runs for customer', lab.try(format($q$select * from report_party_ledger(%L,'customer',%L,null,null)$q$,:'org_a',:'c_ob'))='ALLOWED');
select lab.check('opening','report_customer_debts runs', lab.try(format($q$select * from report_customer_debts(%L,null,null,false,50,0)$q$,:'org_a'))='ALLOWED');
select lab.try(format($q$update customer_opening_balances set organization_id=%L where customer_id=%L$q$,:'org_b',:'c_ob')) as forge \gset
-- (separate statement so the check sees the result of the update)
select lab.check('opening','organization_id cannot be forged: it is always stamped from the customer', (select organization_id from customer_opening_balances where customer_id=:'c_ob')=:'org_a');
select lab.check('opening','NaN amount rejected', lab.try(format($q$update customer_opening_balances set amount='NaN' where customer_id=%L$q$,:'c_ob')) like 'denied%');
select lab.check('opening','the old column is gone (customers)', lab.try($q$select opening_balance from customers$q$) like 'denied%');
select lab.check('opening','the old column is gone (suppliers)', lab.try($q$select opening_balance from suppliers$q$) like 'denied%');

-- BLOCKED: roles with no balance permission, for every access path
select lab.as_owner() \gset
select lab.as_user(:'rep') \gset
select lab.check('opening','restricted rep reads 0 customer balances', (select count(*) from customer_opening_balances)=0);
select lab.check('opening','restricted rep cannot INSERT', lab.try(format($q$insert into customer_opening_balances(customer_id,amount) values (%L,1)$q$,:'cust_a')) like 'denied%');
select lab.check('opening','restricted rep cannot UPDATE', lab.val(format($q$with u as (update customer_opening_balances set amount=0 where customer_id=%L returning 1) select count(*) from u$q$,:'c_ob'))='0');
select lab.check('opening','restricted rep cannot DELETE', lab.val(format($q$with d as (delete from customer_opening_balances where customer_id=%L returning 1) select count(*) from d$q$,:'c_ob'))='0');
select lab.as_user(:'plain') \gset
select lab.check('opening','plain sales reads 0 customer balances', (select count(*) from customer_opening_balances)=0);
select lab.check('opening','plain sales sees the customer but a NULL balance', lab.val(format($q$select balance from customer_balances where customer_id=%L$q$,:'c_ob'))='<null>');
select lab.check('opening','plain sales cannot INSERT (new customer)', lab.try(format($q$insert into customer_opening_balances(customer_id,amount) values (%L,5)$q$,:'cust_n')) like 'denied%');
select lab.check('opening','plain sales cannot UPDATE', lab.val(format($q$with u as (update customer_opening_balances set amount=0 where customer_id=%L returning 1) select count(*) from u$q$,:'c_ob'))='0');
select lab.as_user(:'warehouse') \gset
select lab.check('opening','warehouse reads 0 customer balances', (select count(*) from customer_opening_balances)=0);
select lab.check('opening','warehouse reads 0 supplier balances', (select count(*) from supplier_opening_balances)=0);
select lab.check('opening','warehouse cannot INSERT supplier balance', lab.try(format($q$insert into supplier_opening_balances(supplier_id,amount) values (%L,9)$q$,:'s_ob')) like 'denied%');
select lab.check('opening','warehouse cannot UPDATE customer balance', lab.val(format($q$with u as (update customer_opening_balances set amount=0 where customer_id=%L returning 1) select count(*) from u$q$,:'c_ob'))='0');

-- cross tenant
select lab.as_user(:'owner_b') \gset
select lab.check('opening','other tenant reads 0 balances', (select count(*) from customer_opening_balances)=0 and (select count(*) from supplier_opening_balances)=0);
select lab.check('opening','other tenant cannot write a balance onto Org A customer', lab.try(format($q$insert into customer_opening_balances(customer_id,amount) values (%L,1)$q$,:'cust_a')) like 'denied%');

-- ALLOWED: finance roles
select lab.as_user(:'accountant') \gset
select lab.check('opening','accountant reads the customer balance', (select count(*) from customer_opening_balances where customer_id=:'c_ob')=1);
select lab.check('opening','accountant can update it', lab.val(format($q$with u as (update customer_opening_balances set amount=800 where customer_id=%L returning 1) select count(*) from u$q$,:'c_ob'))='1');
select lab.as_user(:'admin') \gset
select lab.check('opening','admin can update a supplier balance', lab.val(format($q$with u as (update supplier_opening_balances set amount=-100 where supplier_id=%L returning 1) select count(*) from u$q$,:'s_ob'))='1');

-- view-only permission: can READ (scoped) but not WRITE
select lab.as_owner() \gset
insert into customer_opening_balances(customer_id,amount) values (:'cust_a',111),(:'cust_b',222);
insert into role_permissions values ((select id from roles where key='sales' and organization_id is null),'customers.view_balance');
select lab.as_user(:'rep') \gset
select lab.check('opening','view_balance: restricted rep reads ONLY own customer (1 row)', (select count(*) from customer_opening_balances)=1 and (select amount from customer_opening_balances)=111);
select lab.check('opening','view_balance: still cannot write', lab.val(format($q$with u as (update customer_opening_balances set amount=0 where customer_id=%L returning 1) select count(*) from u$q$,:'cust_a'))='0');
select lab.check('opening','view_balance: balance now visible for own customer', lab.val(format($q$select balance from customer_balances where customer_id=%L$q$,:'cust_a')) <> '<null>');
select lab.as_owner() \gset
delete from role_permissions where permission_key='customers.view_balance' and role_id=(select id from roles where key='sales' and organization_id is null);
select lab.as_user(:'rep') \gset
select lab.check('opening','permission removed -> hidden again', (select count(*) from customer_opening_balances)=0);

-- audit trail
select lab.as_owner() \gset
select lab.check('opening','changes are audited', (select count(*) from audit_logs where entity='customer_opening_balance')>=2 and (select count(*) from audit_logs where entity='supplier_opening_balance')>=1);
