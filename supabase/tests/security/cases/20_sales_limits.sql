-- Per-role discount / bonus limits (0031)
select * from lab.ctx \gset
select * from lab.u \gset
select id as sales_role from roles where key='sales' and organization_id is null \gset
select lab.as_owner() \gset
delete from role_sales_limits;

-- defaults: nothing configured -> non owner/admin: 0% and no manual bonus
select lab.check('limits','default: rep sells at list price', lab.sale(:'rep','L-A1',:'cust_a',100)='ALLOWED');
select lab.check('limits','default: rep 5% discount blocked', lab.sale(:'rep','L-A2',:'cust_a',100,5) like 'denied%');
select lab.check('limits','default: rep price below list blocked', lab.sale(:'rep','L-A3',:'cust_a',95) like 'denied%');
select lab.check('limits','default: rep price above list allowed', lab.sale(:'rep','L-A4',:'cust_a',120)='ALLOWED');
select lab.check('limits','default: rep manual bonus blocked', lab.sale(:'rep','L-A5',:'cust_a',100,0,0,null,1,jsonb_build_array(jsonb_build_object('product_id',:'prod_a','quantity',3))) like 'denied%');
select lab.check('limits','default: owner 30% discount allowed', lab.sale(:'owner_a','L-A6',:'cust_a',100,30)='ALLOWED');
select lab.check('limits','default: admin 30% discount allowed', lab.sale(:'admin','L-A7',:'cust_a',100,30)='ALLOWED');

-- who may configure
select lab.as_user(:'rep') \gset
select lab.check('limits','rep cannot write limits', lab.try(format($q$insert into role_sales_limits(organization_id,role_id,max_discount_pct) values (%L,%L,NULL)$q$,:'org_a',:'sales_role')) like 'denied%');
select lab.check('limits','rep cannot read the limits table', (select count(*) from role_sales_limits)=0);
select lab.as_user(:'owner_b') \gset
select lab.check('limits','other tenant owner cannot set limits for Org A', lab.try(format($q$insert into role_sales_limits(organization_id,role_id,max_discount_pct) values (%L,%L,NULL)$q$,:'org_a',:'sales_role')) like 'denied%');
select lab.as_user(:'owner_a') \gset
select lab.check('limits','owner sets sales role to 10%', lab.try(format($q$insert into role_sales_limits(organization_id,role_id,max_discount_pct,can_give_manual_bonus) values (%L,%L,10,false)$q$,:'org_a',:'sales_role'))='ALLOWED');
select lab.check('limits','limit > 100 rejected', lab.try(format($q$update role_sales_limits set max_discount_pct=150 where organization_id=%L$q$,:'org_a')) like 'denied%');

-- 10% cap
select lab.check('limits','10%: line 10% allowed', lab.sale(:'rep','L-B1',:'cust_a',100,10)='ALLOWED');
select lab.check('limits','10%: line 10.5% blocked', lab.sale(:'rep','L-B2',:'cust_a',100,10.5) like 'denied%');
select lab.check('limits','10%: 5% line + 6% invoice combine and block', lab.sale(:'rep','L-B3',:'cust_a',100,5,6) like 'denied%');
select lab.check('limits','10%: price 91 allowed', lab.sale(:'rep','L-B4',:'cust_a',91)='ALLOWED');
select lab.check('limits','10%: price 89 blocked', lab.sale(:'rep','L-B5',:'cust_a',89) like 'denied%');
select lab.check('limits','10%: bonus still blocked (flag off)', lab.sale(:'rep','L-B6',:'cust_a',100,0,0,null,1,jsonb_build_array(jsonb_build_object('product_id',:'prod_a','quantity',2))) like 'denied%');
select lab.as_user(:'rep') \gset
select lab.check('limits','live preview blocks 20% too', lab.try(format($q$select pricing_preview(%L,'sales','[{"product_id":"%s","quantity":1,"unit_price":100,"discount_pct":20}]'::jsonb,0,0,0,0)$q$,:'org_a',:'prod_a')) like 'denied%');
select lab.check('limits','my_sales_limits reports 10', (my_sales_limits(:'org_a')->>'max_discount_pct')::numeric = 10);

-- unlimited + bonus
select lab.as_user(:'owner_a') \gset
select lab.check('limits','owner switches role to UNLIMITED + bonus', lab.try(format($q$update role_sales_limits set max_discount_pct=NULL, can_give_manual_bonus=true where organization_id=%L$q$,:'org_a'))='ALLOWED');
select lab.check('limits','unlimited: 35% allowed (still above cost)', lab.sale(:'rep','L-C1',:'cust_a',100,35)='ALLOWED');
select lab.check('limits','unlimited: manual bonus allowed', lab.sale(:'rep','L-C2',:'cust_a',100,0,0,null,1,jsonb_build_array(jsonb_build_object('product_id',:'prod_a','quantity',2)))='ALLOWED');
select lab.as_owner() \gset
select lab.check('limits','limit changes are audited', (select count(*) from audit_logs where entity='role_sales_limit')>=2);
-- balances hidden by default
select lab.as_user(:'plain') \gset
select lab.check('limits','plain sales sees NULL customer balance', lab.val(format($q$select balance from customer_balances where customer_id=%L$q$,:'cust_a'))='<null>');
select lab.as_user(:'owner_a') \gset
select lab.check('limits','owner sees a customer balance', lab.val(format($q$select balance from customer_balances where customer_id=%L$q$,:'cust_a')) <> '<null>');
select lab.as_user(:'warehouse') \gset
select lab.check('limits','warehouse cannot read suppliers', (select count(*) from suppliers)=0);
select lab.as_owner() \gset
