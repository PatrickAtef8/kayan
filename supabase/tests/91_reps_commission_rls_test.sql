-- Rep monthly target / commission gate, expense types, notes, and rep data isolation.
\set ON_ERROR_STOP on
select t.as_owner();
insert into auth.users (id, email) values
  ('91000000-0000-0000-0000-000000000001', 'owner@rep.test'),
  ('91000000-0000-0000-0000-000000000002', 'rep1@rep.test'),
  ('91000000-0000-0000-0000-000000000003', 'rep2@rep.test');
select t.as_user('91000000-0000-0000-0000-000000000001');
select create_organization('شركة المناديب', 'تجارة', 'EG', 'EGP', 'ar',
  array['sales','customers','inventory','purchases','suppliers','expenses','treasury','representatives','partners']) as id \gset org_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', u, r.id, 'active' from (values ('91000000-0000-0000-0000-000000000002'::uuid), ('91000000-0000-0000-0000-000000000003'::uuid)) v(u), roles r
where r.key = 'sales' and r.organization_id is null;

select t.as_user('91000000-0000-0000-0000-000000000001');
insert into warehouses (organization_id, name) values (:'org_id', 'الرئيسي') returning id as wh \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as sup \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'أ', 'A', 'قطعة') returning id as pa \gset
insert into product_prices (organization_id, product_id, selling_price) values (:'org_id', :'pa', 100);
insert into sales_representatives (organization_id, name, commission_basis, commission_rate, monthly_target, min_target_for_commission, user_id)
values (:'org_id', 'مندوب 1', 'net_sales', 10, 5000, 1000, '91000000-0000-0000-0000-000000000002') returning id as r1 \gset
insert into sales_representatives (organization_id, name, commission_basis, commission_rate, user_id)
values (:'org_id', 'مندوب 2', 'net_sales', 10, '91000000-0000-0000-0000-000000000003') returning id as r2 \gset
insert into customers (organization_id, name, sales_rep_id) values (:'org_id', 'عميل 1', :'r1') returning id as c1 \gset
insert into customers (organization_id, name, sales_rep_id) values (:'org_id', 'عميل 2', :'r2') returning id as c2 \gset

select create_purchase_invoice(:'org_id', :'sup', :'wh', 'P-1', '2026-06-01',
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 100, 'unit_cost', 40, 'discount', 0)), 0, 0, 4000, 'نقدًا', null) as id \gset p_

-- ------------------------------------------------------------
-- Commission gate: min 1,000 net sales per month
-- ------------------------------------------------------------
select create_sales_invoice(:'org_id', :'c1', :'wh', 'S-1', '2026-06-05',
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 6, 'unit_price', 100, 'discount', 0)), 0, 0, 0, null, null) as id \gset s1_
select t.eq((select sales_rep_id = :'r1'::uuid from sales_invoices where id = :'s1_id')::int, 1, 'invoice takes the customer''s rep by default');
select t.eq((select commission_amount from sales_invoices where id = :'s1_id'), 60, 'potential commission 10% of 600');
select t.eq((select earned_commission from invoice_commissions where sales_invoice_id = :'s1_id'), 0, 'below the minimum target (600 < 1,000): nothing earned');
select t.eq((select (financial->>'commissions')::numeric from (select report_summary(:'org_id', '2026-06-01', '2026-06-30')->'financial' as financial) q), 0, 'P&L commissions = 0 below target');

select create_sales_invoice(:'org_id', :'c1', :'wh', 'S-2', '2026-06-20',
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 6, 'unit_price', 100, 'discount', 0)), 0, 0, 0, null, null) as id \gset s2_
select t.eq((select sum(earned_commission) from invoice_commissions where sales_rep_id = :'r1'), 120, 'reached 1,200 ≥ 1,000: both invoices now earn (60 + 60)');
select t.eq((select (report_summary(:'org_id', '2026-06-01', '2026-06-30')->'financial'->>'commissions')::numeric), 120, 'P&L commissions = 120, same number');
select t.eq((select earned from rep_commission_balances where rep_id = :'r1'), 120, 'rep commission balance: earned 120');

-- a return that drops the month below the target removes the earned commission
select create_sales_return(:'org_id', :'s2_id', '2026-06-25', null, 0, null, true, 'resalable') as id \gset ret_
select t.eq((select net_sales from rep_monthly_performance where rep_id = :'r1'), 600, 'rep monthly net sales after the return = 600');
select t.eq((select earned_commission from rep_monthly_performance where rep_id = :'r1'), 0, 'below target again → 0 earned');
select create_sales_invoice(:'org_id', :'c1', :'wh', 'S-3', '2026-06-27',
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 5, 'unit_price', 100, 'discount', 0)), 0, 0, 0, null, null) as id \gset s3_
select t.eq((select net_sales from rep_monthly_performance where rep_id = :'r1'), 1100, 'net sales 1,100');
select t.eq((select earned from rep_commission_balances where rep_id = :'r1'), 60 + 60 + 50, 'earned = 170 (S-1 60, S-2 60 [fully returned, history kept], S-3 50)');

-- ------------------------------------------------------------
-- Expense types → treasury and profit
-- ------------------------------------------------------------
select t.as_owner(); update treasury_accounts set opening_balance = 10000 where organization_id = :'org_id'; select t.as_user('91000000-0000-0000-0000-000000000001');
select t.eq((select balance from treasury_balances where organization_id = :'org_id'), 10000 - 4000, 'treasury: opening 10,000 − 4,000 purchase');
select create_expense(:'org_id', null, null, 300, '2026-06-28', 'نقدًا', 'مرتب', null, 'salary', :'r1') as id \gset e_
select create_expense(:'org_id', null, null, 100, '2026-06-28', 'نقدًا', 'بنزين', null, 'rep_expense', :'r1') as id \gset e_
select t.eq((select (report_summary(:'org_id', '2026-06-01', '2026-06-30')->'financial'->>'operating_expenses')::numeric), 400, 'salary + rep expense are operating expenses (hit profit)');
select t.throws(format('select create_expense(%L, null, null, 500, null, null, null, null, ''commission_payout'', %L)', :'org_id', :'r1'), 'أكبر من العمولة المستحقة', 'payout cannot exceed the commission payable');
select t.throws(format('select create_expense(%L, null, null, 50, null, null, null, null, ''salary'', null)', :'org_id'), 'يجب اختيار المندوب', 'salary needs a rep');
select (report_summary(:'org_id', '2026-06-01', '2026-06-30')->'financial'->>'net_profit')::numeric as np_before \gset
select create_expense(:'org_id', null, null, 100, '2026-06-29', 'نقدًا', 'صرف عمولة', null, 'commission_payout', :'r1') as id \gset e_
select t.eq((report_summary(:'org_id', '2026-06-01', '2026-06-30')->'financial'->>'net_profit')::numeric, :'np_before'::numeric, 'commission payout does NOT hit profit again');
select t.eq((report_summary(:'org_id', '2026-06-01', '2026-06-30')->'financial'->>'commissions_paid')::numeric, 100, 'commissions_paid reported');
select t.eq((select payable from rep_commission_balances where rep_id = :'r1'), 70, 'payable = 170 − 100');
select t.eq((select balance from treasury_balances where organization_id = :'org_id'), 10000 - 4000 - 300 - 100 - 100, 'treasury is down by salary, rep expense and the payout');

-- ------------------------------------------------------------
-- Rep isolation
-- ------------------------------------------------------------
select create_sales_invoice(:'org_id', :'c2', :'wh', 'S-R2', '2026-06-10',
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 2, 'unit_price', 100, 'discount', 0)), 0, 0, 0, null, null) as id \gset s4_

select t.as_user('91000000-0000-0000-0000-000000000002');
select t.eq((select count(*) from sales_invoices), 3, 'rep 1 sees only their 3 invoices');
select t.eq((select count(*) from customers), 1, 'rep 1 sees only their customer');
select t.eq((select count(*) from sales_invoice_items), 3, 'and only their invoice lines');
-- since 0031 a rep without customers.view_balance sees the customer row but a NULL balance
select t.ok((select balance is null from customer_balances where customer_id = :'c1'), 'rep: their customer''s balance is hidden (NULL) without customers.view_balance');
select t.empty('select 1 from customer_balances where customer_id = ''' || :'c2' || '''', 'rep 1 cannot see customer 2''s debt');
select t.empty('select 1 from purchase_invoices', 'rep cannot see purchases');
select t.empty('select 1 from suppliers', 'rep cannot see suppliers');
select t.empty('select 1 from treasury_movements', 'rep cannot see the treasury');
select t.empty('select 1 from expenses', 'rep cannot see expenses');
select t.eq((select count(*) from sales_representatives), 1, 'rep sees only their own rep record');
select t.eq((report_summary(:'org_id', null, null)->'sales'->>'invoices')::numeric, 3, 'reports computed by the same functions are scoped too');
select t.throws(format('select create_sales_invoice(%L, %L, %L, null, null, %L::jsonb, 0, 0, 0, null, null)', :'org_id', :'c2', :'wh',
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 1, 'unit_price', 100, 'discount', 0))::text), 'غير تابع لك', 'rep cannot invoice another rep''s customer');

-- notes (do not touch any number)
insert into party_notes (organization_id, party_type, customer_id, note) values (:'org_id', 'customer', :'c1', 'دفع 500 كاش اليوم');
select t.eq((select count(*) from party_notes), 1, 'rep can write and read a note on their customer');
select t.throws(format('insert into party_notes (organization_id, party_type, customer_id, note) values (%L, ''customer'', %L, ''x'')', :'org_id', :'c2'), 'row-level security', 'rep cannot note another rep''s customer');
-- the rep can no longer read balances (0031), so check that a note changes nothing as the owner, then switch back
select t.as_user('91000000-0000-0000-0000-000000000001');
select t.eq((select balance from customer_balances where customer_id = :'c1'), 1100, 'notes changed no balance');
select t.as_user('91000000-0000-0000-0000-000000000002');

-- a customer a rep creates is assigned to them and cannot be given away
insert into customers (organization_id, name) values (:'org_id', 'عميل جديد');
select t.eq((select count(*) from customers where name = 'عميل جديد' and sales_rep_id = :'r1'), 1, 'new customer auto-assigned to the rep');
select t.eq((select count(*) from customers), 2, 'rep now sees 2 customers');

select t.as_user('91000000-0000-0000-0000-000000000003');
select t.eq((select count(*) from sales_invoices), 1, 'rep 2 sees only their invoice');

select t.as_user('91000000-0000-0000-0000-000000000001');
select t.eq((select count(*) from sales_invoices), 4, 'owner still sees everything');

-- ------------------------------------------------------------
-- Treasury: sales collections minus recorded expenses (by type)
-- ------------------------------------------------------------
select t.as_user('91000000-0000-0000-0000-000000000001');
select t.eq((report_treasury_summary(:'org_id', '2026-06-01', '2026-06-30')->>'sales_collections')::numeric, 0, 'treasury: no sales cash collected in this scenario');
select t.eq((report_treasury_summary(:'org_id', '2026-06-01', '2026-06-30')->>'recorded_expenses')::numeric, 300 + 100 + 100, 'treasury: recorded expenses = salary 300 + rep expense 100 + commission payout 100');
select t.eq(jsonb_array_length(report_treasury_summary(:'org_id', '2026-06-01', '2026-06-30')->'expenses_by_type'), 3, 'treasury: expenses split into 3 types');
select t.eq((report_treasury_summary(:'org_id', '2026-06-01', '2026-06-30')->>'collections_minus_expenses')::numeric, -500, 'treasury: collections − expenses');

-- invoice-level note by the rep
select t.as_user('91000000-0000-0000-0000-000000000002');
insert into party_notes (organization_id, party_type, customer_id, sales_invoice_id, note) values (:'org_id', 'customer', :'c1', :'s1_id', 'العميل دفع 200 InstaPay');
select t.eq((select count(*) from party_notes where sales_invoice_id = :'s1_id'), 1, 'rep can note a specific invoice of their customer');

-- ------------------------------------------------------------
-- Cost & profit are not readable by a rep, even through the API
-- ------------------------------------------------------------
select t.as_user('91000000-0000-0000-0000-000000000002');
select t.eq((select count(*) from sales_invoice_financials), 0, 'rep: invoice cost/profit table returns nothing');
select t.eq((select count(*) from sales_item_financials), 0, 'rep: item cost/profit table returns nothing');
select t.eq((select count(*) from sales_return_financials), 0, 'rep: return cost/profit table returns nothing');
select t.eq((select count(*) from sales_return_item_financials), 0, 'rep: return-item cost table returns nothing');
select t.eq((select count(*) from v_sales_invoices where cogs_total is not null or profit_total is not null), 0, 'rep: joined view shows NULL cost/profit');
select t.throws('select cogs_total from sales_invoices', 'does not exist', 'rep: cost column is gone from the invoice table');
select t.throws('select unit_cost from sales_invoice_items', 'does not exist', 'rep: cost column is gone from the item table');
select t.empty('select 1 from inventory_stock', 'rep: no stock average cost');
select t.empty('select 1 from inventory_movements', 'rep: no stock movements');
select t.empty('select 1 from product_prices', 'rep: no product cost price');
select t.ok((select count(*) from product_sale_prices where selling_price = 100) = 1, 'rep: selling price still available through the safe view');
select t.eq((select count(*) from sales_invoices), 3, 'rep: own invoices still readable');

-- the owner still sees everything
select t.as_user('91000000-0000-0000-0000-000000000001');
select t.ok((select count(*) from sales_invoice_financials) >= 4, 'owner: reads invoice cost/profit');
select t.ok((select sum(profit_total) from v_sales_invoices) is not null, 'owner: joined view carries profit');
