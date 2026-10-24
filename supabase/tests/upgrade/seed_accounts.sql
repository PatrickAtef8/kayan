-- Accounting data created with the PRE-0037 functions (old call shapes, no return reasons): reps with
-- different commission bases, sales, collections, both kinds of return, expenses of every type,
-- supplier payment, a manual treasury movement and an account opening balance. A separate organization
-- so the checks of the stock/partner seed are untouched. Used by upgrade_check.sh.
\set ON_ERROR_STOP on
select t.as_owner();
insert into auth.users (id, email) values ('99000000-0000-0000-0000-000000000002', 'owner2@upg.test');
select t.as_user('99000000-0000-0000-0000-000000000002');
select create_organization('شركة الترقية المحاسبية', 'تجارة', 'EG', 'EGP', 'ar',
  array['sales','customers','inventory','purchases','suppliers','expenses','treasury','representatives','partners']) as id \gset org_
insert into warehouses (organization_id, name) values (:'org_id', 'الرئيسي') returning id as w1 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as sup \gset
insert into sales_representatives (organization_id, name, fixed_salary, transportation_allowance, commission_basis, commission_rate, min_target_for_commission)
  values (:'org_id', 'مندوب أ', 3000, 400, 'net_sales', 5, 0) returning id as repa \gset
insert into sales_representatives (organization_id, name, fixed_salary, transportation_allowance, commission_basis, commission_rate, min_target_for_commission)
  values (:'org_id', 'مندوب ب', 2000, 0, 'collected_amount', 10, 0) returning id as repb \gset
insert into customers (organization_id, name, price_tier, sales_rep_id) values (:'org_id', 'عميل أ', 'retail', :'repa') returning id as ca \gset
insert into customers (organization_id, name, price_tier, sales_rep_id) values (:'org_id', 'عميل ب', 'wholesale', :'repb') returning id as cb \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'X', 'X', 'قطعة') returning id as px \gset
insert into product_prices (organization_id, product_id, selling_price) values (:'org_id', :'px', 100);
insert into expense_categories (organization_id, name) values (:'org_id', 'إيجار') returning id as cat \gset
select t.as_owner();
select ensure_default_treasury_account(:'org_id') as acct \gset
update treasury_accounts set opening_balance = 500 where id = :'acct';
select t.as_user('99000000-0000-0000-0000-000000000002');

select create_purchase_invoice(:'org_id', :'sup', :'w1', 'UA-P1', current_date,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 100, 'unit_cost', 40, 'discount_pct', 0)), 0, 0, 500, null, null, 0) as id \gset p1_
select create_sales_invoice(:'org_id', :'ca', :'w1', 'UA-S1', current_date,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 10, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset s1_
select create_sales_invoice(:'org_id', :'cb', :'w1', 'UA-S2', current_date,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 10, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 300, null, null, null, 0) as id \gset s2_
select record_customer_collection(:'org_id', :'cb', :'s2_id', 200, current_date, 'cash', 'UA-COL', null) as id \gset col_
select create_sales_return(:'org_id', :'s1_id', current_date,
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'s1_id'), 'quantity', 2, 'condition', 'resalable')), 0, null) as id \gset r1_
select create_sales_return(:'org_id', :'s2_id', current_date,
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'s2_id'), 'quantity', 1, 'condition', 'damaged')), 20, null) as id \gset r2_
select create_expense(:'org_id', :'cat', :'acct', 200, current_date, 'cash', 'إيجار', null) as id \gset e1_
select create_expense(:'org_id', null, :'acct', 50, current_date, 'cash', 'بلا تصنيف', null) as id \gset e2_
select create_expense(:'org_id', null, :'acct', 1000, current_date, 'bank', 'راتب', null, 'salary', :'repa') as id \gset e3_
select create_expense(:'org_id', null, :'acct', 20, current_date, 'cash', 'دفعة عمولة', null, 'commission_payout', :'repa') as id \gset e4_
select record_supplier_payment(:'org_id', :'sup', null, 100, current_date, 'cash', 'UA-SP', null) as id \gset sp_
select record_treasury_movement(:'org_id', :'acct', 'in', 80, current_date, 'إيداع يدوي') as id \gset tm_
select t.as_owner();
drop table if exists t.upg2_ids;
create table t.upg2_ids as select :'org_id'::uuid as org, :'repa'::uuid as repa, :'repb'::uuid as repb, :'s1_id'::uuid as s1, :'w1'::uuid as w1;
grant select on t.upg2_ids to authenticated;
