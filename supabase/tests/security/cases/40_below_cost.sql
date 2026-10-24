-- Only the Owner may sell below cost (0033). Cost of Widget = 60, list price = 100.
select * from lab.ctx \gset
select * from lab.u \gset
select id as sales_role from roles where key='sales' and organization_id is null \gset
-- remove the discount-limit barrier so ONLY the cost rule is being tested
select lab.as_owner() \gset
delete from role_sales_limits;
insert into role_sales_limits(organization_id,role_id,max_discount_pct,can_give_manual_bonus) values (:'org_a',:'sales_role',NULL,true);
select count(*) as inv_before from sales_invoices \gset

select lab.check('belowcost','rep at cost (60.00) allowed', lab.sale(:'rep','BC-1',:'cust_a',60)='ALLOWED');
select lab.check('belowcost','rep above cost (61) allowed', lab.sale(:'rep','BC-2',:'cust_a',61)='ALLOWED');
select lab.check('belowcost','rep list price allowed', lab.sale(:'rep','BC-3',:'cust_a',100)='ALLOWED');
select lab.check('belowcost','rep 40% discount (net 60) allowed', lab.sale(:'rep','BC-4',:'cust_a',100,40)='ALLOWED');
select lab.check('belowcost','rep price 59 BLOCKED', lab.sale(:'rep','BC-5',:'cust_a',59) like 'denied%التكلفة%');
select lab.check('belowcost','rep price 59.98 blocked (outside 1-cent tolerance)', lab.sale(:'rep','BC-6',:'cust_a',59.98) like 'denied%');
select lab.check('belowcost','rep 41% line discount (net 59) BLOCKED', lab.sale(:'rep','BC-7',:'cust_a',100,41) like 'denied%');
select lab.check('belowcost','rep 41% invoice discount BLOCKED', lab.sale(:'rep','BC-8',:'cust_a',100,0,41) like 'denied%');
select lab.check('belowcost','rep qty 3 @59 (net 177 < 180) BLOCKED', lab.sale(:'rep','BC-9',:'cust_a',59,0,0,null,3) like 'denied%');
select lab.check('belowcost','rep qty 3 @60 allowed', lab.sale(:'rep','BC-10',:'cust_a',60,0,0,null,3)='ALLOWED');
select lab.check('belowcost','rep price 0 BLOCKED', lab.sale(:'rep','BC-11',:'cust_a',0) like 'denied%');
select lab.check('belowcost','manual bonus lines are not treated as below-cost', lab.sale(:'rep','BC-12',:'cust_a',100,0,0,null,1,jsonb_build_array(jsonb_build_object('product_id',:'prod_a','quantity',2)))='ALLOWED');
select lab.check('belowcost','plain (unlinked) sales also blocked', lab.sale(:'plain','BC-13',:'cust_a',50) like 'denied%');
select lab.check('belowcost','a second OWNER (the old admin persona) is exempt like any owner', lab.sale(:'admin','BC-14',:'cust_a',10)='ALLOWED');
select lab.check('belowcost','admin at cost allowed', lab.sale(:'admin','BC-15',:'cust_a',60)='ALLOWED');
select lab.check('belowcost','OWNER can sell below cost', lab.sale(:'owner_a','BC-16',:'cust_a',10)='ALLOWED');
select lab.check('belowcost','OWNER can sell at 0', lab.sale(:'owner_a','BC-17',:'cust_a',0)='ALLOWED');
select lab.as_user(:'rep') \gset
select lab.check('belowcost','error message does not reveal the cost', lab.sale(:'rep','BC-18',:'cust_a',59) not like '%60%');
select lab.as_owner() \gset
select lab.check('belowcost','blocked attempts left no invoice behind', (select count(*) from sales_invoices where invoice_number in ('BC-5','BC-6','BC-7','BC-8','BC-9','BC-11','BC-13','BC-18'))=0);
select lab.check('belowcost','allowed attempts did create invoices', (select count(*) from sales_invoices where invoice_number in ('BC-1','BC-2','BC-3','BC-4','BC-10','BC-12','BC-15','BC-16','BC-17'))=9);
-- a user cannot bypass the rule by writing the cost row directly
select lab.as_user(:'rep') \gset
select lab.check('belowcost','rep cannot write sales_item_financials directly', lab.try($q$insert into sales_item_financials(sales_invoice_item_id,organization_id,unit_cost,cost_total,profit) select id, organization_id, 1,1,1 from sales_invoice_items limit 1$q$) like 'denied%');
select lab.as_owner() \gset
