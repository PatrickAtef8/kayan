-- Reports package, Phase 6: accounting reports.
\set ON_ERROR_STOP on
select t.as_owner();
insert into auth.users (id, email) values
  ('9c000000-0000-0000-0000-000000000001', 'owner@ac100.test'),
  ('9c000000-0000-0000-0000-000000000002', 'other@ac100.test'),
  ('9c000000-0000-0000-0000-000000000003', 'acct@ac100.test'),
  ('9c000000-0000-0000-0000-000000000004', 'reprep@ac100.test'),
  ('9c000000-0000-0000-0000-000000000005', 'keeper@ac100.test');
select t.as_user('9c000000-0000-0000-0000-000000000001');
select create_organization('شركة الحسابات المالية', 'تجارة', 'EG', 'EGP', 'ar',
  array['sales','customers','inventory','purchases','suppliers','expenses','treasury','representatives','partners']) as id \gset org_
select t.as_user('9c000000-0000-0000-0000-000000000002');
select create_organization('شركة أخرى', 'تجارة', 'EG', 'EGP', 'ar', array['sales','inventory']) as id \gset orgb_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', v.u, r.id, 'active' from roles r
join (values ('owner', '9c000000-0000-0000-0000-000000000003'::uuid), ('sales', '9c000000-0000-0000-0000-000000000004'::uuid), ('warehouse', '9c000000-0000-0000-0000-000000000005'::uuid)) v(k, u) on v.k = r.key
where r.organization_id is null;

select t.as_user('9c000000-0000-0000-0000-000000000001');
select cairo_today() as d0 \gset
select date_trunc('month', :'d0'::date)::date as m0 \gset
select (:'m0'::date - 10) as dprev \gset
select (:'m0'::date - 40) as dprev2 \gset
insert into warehouses (organization_id, name) values (:'org_id', 'الرئيسي') returning id as w1 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as sup \gset
insert into sales_representatives (organization_id, name, user_id, fixed_salary, transportation_allowance, commission_basis, commission_rate, min_target_for_commission)
  values (:'org_id', 'مندوب أ', '9c000000-0000-0000-0000-000000000004', 3000, 500, 'net_sales', 5, 0) returning id as repa \gset
insert into sales_representatives (organization_id, name, fixed_salary, transportation_allowance, commission_basis, commission_rate, min_target_for_commission)
  values (:'org_id', 'مندوب ب', 2000, 0, 'collected_amount', 10, 1000) returning id as repb \gset
insert into sales_representatives (organization_id, name, fixed_salary, transportation_allowance, commission_basis, commission_rate, min_target_for_commission)
  values (:'org_id', 'مندوب ج', 1500, 100, 'gross_profit', 20, 100000) returning id as repc \gset
insert into customers (organization_id, name, price_tier, sales_rep_id) values (:'org_id', 'عميل أ', 'retail', :'repa') returning id as ca \gset
insert into customers (organization_id, name, price_tier, sales_rep_id) values (:'org_id', 'عميل ب', 'retail', :'repb') returning id as cb \gset
insert into customers (organization_id, name, price_tier, sales_rep_id) values (:'org_id', 'عميل ج', 'retail', :'repc') returning id as cc \gset
insert into customers (organization_id, name, price_tier) values (:'org_id', 'عميل بلا مندوب', 'retail') returning id as cn \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'X', 'X', 'قطعة') returning id as px \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'Y', 'Y', 'قطعة') returning id as py \gset
insert into product_prices (organization_id, product_id, selling_price) select :'org_id', id, 100 from products where organization_id = :'org_id';
insert into expense_categories (organization_id, name) values (:'org_id', 'إيجار') returning id as cat_rent \gset
insert into expense_categories (organization_id, name) values (:'org_id', 'كهرباء') returning id as cat_elec \gset
insert into partners (organization_id, name) values (:'org_id', 'شريك') returning id as partner \gset
select t.as_owner();
select ensure_default_treasury_account(:'org_id') as acct \gset
update treasury_accounts set opening_balance = 1000 where id = :'acct';
select t.as_user('9c000000-0000-0000-0000-000000000001');

-- stock: X 200 @ 40 (8000, 2000 paid on the spot), Y 50 @ 10
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'AC-P1', :'dprev2'::date,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 200, 'unit_cost', 40, 'discount_pct', 0),
                    jsonb_build_object('product_id', :'py', 'quantity', 50, 'unit_cost', 10, 'discount_pct', 0)), 0, 0, 2000, null, null, 0) as id \gset p1_

-- ---------- sales ----------
select create_sales_invoice(:'org_id', :'ca', :'w1', 'S1', :'dprev'::date,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 10, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset s1_
select create_sales_invoice(:'org_id', :'ca', :'w1', 'S2', :'m0'::date,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 20, 'unit_price', 100, 'discount_pct', 0)), 10, 0, 0, null, null, null, 0) as id \gset s2_
select create_sales_invoice(:'org_id', :'cb', :'w1', 'S3', :'m0'::date,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 20, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 500, null, null, null, 0) as id \gset s3_
select create_sales_invoice(:'org_id', :'cc', :'w1', 'S4', :'m0'::date,
  jsonb_build_array(jsonb_build_object('product_id', :'py', 'quantity', 10, 'unit_price', 30, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset s4_
select create_sales_invoice(:'org_id', :'cn', :'w1', 'S5', :'m0'::date,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 5, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset s5_
-- a later collection linked to S3 (raises rep B's collection commission) and an on-account one from customer A
select record_customer_collection(:'org_id', :'cb', :'s3_id', 700, :'d0'::date, 'cash', 'COL-S3', null) as id \gset col1_
select record_customer_collection(:'org_id', :'ca', null, 100, :'d0'::date, 'cash', 'ON-ACC', null) as id \gset col2_

-- ---------- returns (reasons) ----------
select create_sales_return(:'org_id', :'s2_id', :'d0'::date,
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'s2_id'), 'quantity', 2, 'condition', 'resalable', 'reason', 'slow_moving')), 0, null) as id \gset r1_
select create_sales_return(:'org_id', :'s3_id', :'d0'::date,
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'s3_id'), 'quantity', 1, 'condition', 'damaged', 'reason', 'damaged')), 50, null) as id \gset r2_
select create_sales_return(:'org_id', :'s5_id', :'d0'::date,
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'s5_id'), 'quantity', 1, 'condition', 'resalable', 'reason', 'expired')), 0, null) as id \gset r3_
select create_sales_return(:'org_id', :'s1_id', :'dprev'::date,
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'s1_id'), 'quantity', 1, 'condition', 'resalable')), 0, null) as id \gset r4_

-- ---------- expenses (operating / rep expense / salary / commission payouts) ----------
select create_expense(:'org_id', :'cat_rent', :'acct', 300, :'m0'::date, 'cash', 'إيجار', null) as id \gset e1_
select create_expense(:'org_id', :'cat_elec', :'acct', 120, :'m0'::date, 'cash', 'كهرباء', null) as id \gset e2_
select create_expense(:'org_id', null, :'acct', 80, :'dprev'::date, 'cash', 'مصروف بلا تصنيف', null) as id \gset e3_
select create_expense(:'org_id', null, :'acct', 60, :'m0'::date, 'cash', 'مصروف مندوب', null, 'rep_expense', :'repa') as id \gset e4_
select create_expense(:'org_id', null, :'acct', 3000, :'m0'::date, 'bank', 'راتب', null, 'salary', :'repa') as id \gset e5_
select create_expense(:'org_id', null, :'acct', 40, :'m0'::date, 'cash', 'دفعة عمولة', null, 'commission_payout', :'repa') as id \gset e6_
select create_expense(:'org_id', null, :'acct', 30, :'m0'::date, 'cash', 'دفعة عمولة', null, 'commission_payout', :'repb') as id \gset e7_
-- other cash movements
select record_supplier_payment(:'org_id', :'sup', null, 500, :'m0'::date, 'cash', 'SP-1', null) as id \gset sp1_
select record_partner_withdrawal(:'org_id', :'partner', :'acct', 200, :'m0'::date, 'سحب', null) as id \gset pw1_
select record_treasury_movement(:'org_id', :'acct', 'in', 150, :'m0'::date, 'إيداع يدوي') as id \gset tm1_
select create_purchase_return(:'org_id', :'p1_id', :'m0'::date,
  jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', (select id from purchase_invoice_items where purchase_invoice_id = :'p1_id' and product_id = :'px'), 'quantity', 5)), 100, null) as id \gset pr1_

-- =====================================================================
-- 1. Profit & loss reconciles with the existing summary, line by line
-- =====================================================================
select t.eq((select gross_sales from report_profit_loss(:'org_id')), 5800, 'P&L: gross sales = 1000 + 2000 + 2000 + 300 + 500');
select t.eq((select discounts from report_profit_loss(:'org_id')), 200, 'P&L: discounts = the 10% on S2');
select t.eq((select returns_value from report_profit_loss(:'org_id')), (select sum(subtotal_reversed) from sales_returns where organization_id = :'org_id'), 'P&L: returns = the return documents (each counted once)');
select t.eq((select net_sales from report_profit_loss(:'org_id')), 5800 - 200 - (select sum(subtotal_reversed) from sales_returns where organization_id = :'org_id'), 'P&L: net sales = gross − discounts − returns');
select t.eq((select net_sales from report_profit_loss(:'org_id')), ((select report_summary(:'org_id')->'sales'->>'net_sales')::numeric), 'P&L net sales = report_summary');
select t.eq((select cogs from report_profit_loss(:'org_id')), ((select report_summary(:'org_id')->'financial'->>'cogs')::numeric), 'P&L cost of goods = report_summary');
select t.eq((select gross_profit from report_profit_loss(:'org_id')), ((select report_summary(:'org_id')->'financial'->>'gross_profit')::numeric), 'P&L gross profit = report_summary');
select t.eq((select operating_expenses from report_profit_loss(:'org_id')), ((select report_summary(:'org_id')->'financial'->>'operating_expenses')::numeric), 'P&L operating expenses = report_summary');
select t.eq((select commissions from report_profit_loss(:'org_id')), ((select report_summary(:'org_id')->'financial'->>'commissions')::numeric), 'P&L commissions = report_summary');
select t.eq((select net_profit from report_profit_loss(:'org_id')), ((select report_summary(:'org_id')->'financial'->>'net_profit')::numeric), 'P&L net profit = report_summary');
select t.eq((select operating_expenses from report_profit_loss(:'org_id')), 3560, 'P&L: operating expenses = 300 + 120 + 80 + 60 (rep expense) + 3000 (salary); commission payouts are NOT in it');
select t.eq((select cogs from report_profit_loss(:'org_id')),
            (select coalesce(sum(cogs_total), 0) from v_sales_invoices where organization_id = :'org_id') - (select coalesce(sum(cost_reversed), 0) from v_sales_returns where organization_id = :'org_id'),
            'P&L: cost of goods = invoice costs − the cost of goods that came back (existing costing, average cost)');
select t.eq((select gross_profit - operating_expenses - commissions - net_profit from report_profit_loss(:'org_id')), 0, 'identity: gross profit − expenses − commissions = net profit');
-- the commission is deducted ONCE, as earned (not again when paid)
select t.eq((select commissions from report_profit_loss(:'org_id')), 50 + 90 + 120, 'commissions = earned: A 50 (prev) + 90, B 120 (5% ... 10% of 1200 collected); C is below its target → 0');
select t.eq((select sum(amount) from expenses where organization_id = :'org_id' and expense_type = 'commission_payout'), 70, 'setup: 70 of commissions were PAID (cash), and that is not deducted a second time');
-- by month
select t.eq((select count(*) from report_profit_loss(:'org_id', null, null, true)), 3, 'by month: two months + the total row');
select t.eq((select count(*) from report_profit_loss(:'org_id', null, null, true) where not is_total), 2, 'by month: previous month and this month');
select t.eq((select sum(net_profit) from report_profit_loss(:'org_id', null, null, true) where not is_total), (select net_profit from report_profit_loss(:'org_id', null, null, true) where is_total), 'by month: the months add up to the total');
select t.eq((select sum(net_sales) from report_profit_loss(:'org_id', null, null, true) where not is_total), (select net_sales from report_profit_loss(:'org_id')), 'by month: net sales adds up');
select t.eq((select gross_sales from report_profit_loss(:'org_id', null, null, true) where period_start = :'dprev'::date - extract(day from :'dprev'::date)::int + 1), 1000, 'previous month: only S1');
select t.eq((select operating_expenses from report_profit_loss(:'org_id', null, null, true) where period_start = (date_trunc('month', :'dprev'::date))::date), 80, 'previous month expenses: the 80 (no category)');
select t.eq((select commissions from report_profit_loss(:'org_id', null, null, true) where period_start = (date_trunc('month', :'dprev'::date))::date), 50, 'previous month commissions: rep A on S1');
-- period filter agrees with report_summary for the same period
select t.eq((select net_profit from report_profit_loss(:'org_id', :'m0'::date, :'d0'::date)), ((select report_summary(:'org_id', :'m0'::date, :'d0'::date)->'financial'->>'net_profit')::numeric), 'P&L net profit = report_summary for this month');
select t.eq((select net_profit from report_profit_loss(:'org_id', :'dprev'::date, :'dprev'::date)), ((select report_summary(:'org_id', :'dprev'::date, :'dprev'::date)->'financial'->>'net_profit')::numeric), 'P&L net profit = report_summary for a single day');
select t.eq((select count(*) from report_profit_loss(:'org_id', :'d0'::date + 5, :'d0'::date + 9)), 1, 'an empty period still returns the (zero) total row');
select t.eq((select net_profit from report_profit_loss(:'org_id', :'d0'::date + 5, :'d0'::date + 9)), 0, 'and it is zero');

-- =====================================================================
-- 2. Profit is not cash, cash is not profit
-- =====================================================================
select net_profit as np0 from report_profit_loss(:'org_id') \gset
select (report_treasury_summary(:'org_id')->>'closing')::numeric as cash0 \gset
select record_supplier_payment(:'org_id', :'sup', null, 111, :'m0'::date, 'cash', 'SP-2', null) as id \gset sp2_
select t.eq((select net_profit from report_profit_loss(:'org_id')), :np0::numeric, 'a supplier payment does not change profit');
select t.eq(((select report_treasury_summary(:'org_id')->>'closing')::numeric), :cash0::numeric - 111, 'but it reduces cash by 111');
-- paying a commission: cash out, no second deduction from profit
select create_expense(:'org_id', null, :'acct', 22, :'m0'::date, 'cash', 'دفعة عمولة', null, 'commission_payout', :'repb') as id \gset e8_
select t.eq((select net_profit from report_profit_loss(:'org_id')), :np0::numeric, 'paying a commission does not reduce profit again (it was deducted when earned)');
select t.eq(((select report_treasury_summary(:'org_id')->>'closing')::numeric), :cash0::numeric - 111 - 22, 'but it reduces cash');
-- collecting from a customer: cash in, no effect on profit (the sale was already profit)
select record_customer_collection(:'org_id', :'cn', :'s5_id', 44, :'m0'::date, 'cash', 'COL-S5', null) as id \gset col3_
select t.eq((select net_profit from report_profit_loss(:'org_id')), :np0::numeric, 'a customer collection does not change profit');
select t.eq(((select report_treasury_summary(:'org_id')->>'closing')::numeric), :cash0::numeric - 111 - 22 + 44, 'but it increases cash');
-- an operating expense hits both
select create_expense(:'org_id', :'cat_rent', :'acct', 33, :'m0'::date, 'cash', 'إيجار إضافي', null) as id \gset e9_
select t.eq((select net_profit from report_profit_loss(:'org_id')), :np0::numeric - 33, 'an operating expense reduces profit by 33');
select t.eq(((select report_treasury_summary(:'org_id')->>'closing')::numeric), :cash0::numeric - 111 - 22 + 44 - 33, 'and cash by 33');
-- a customer opening balance is neither a sale nor cash
select net_profit as np1 from report_profit_loss(:'org_id') \gset
select (report_treasury_summary(:'org_id')->>'closing')::numeric as cash1 \gset
select t.as_owner();
insert into customer_opening_balances (customer_id, amount) values (:'cn', 777);
insert into supplier_opening_balances (supplier_id, amount) values (:'sup', 888);
select t.as_user('9c000000-0000-0000-0000-000000000001');
select t.eq((select net_profit from report_profit_loss(:'org_id')), :np1::numeric, 'opening balances of customers/suppliers do not touch the profit');
select t.eq(((select report_treasury_summary(:'org_id')->>'closing')::numeric), :cash1::numeric, 'nor the cash');

-- =====================================================================
-- 3. Expenses classified
-- =====================================================================
select t.eq((select total from report_expenses(:'org_id', null, null, 'category') where group_label = 'إيجار'), 333, 'by category: rent 300 + 33');
select t.eq((select total from report_expenses(:'org_id', null, null, 'category') where group_label = 'كهرباء'), 120, 'by category: electricity');
select t.eq((select total from report_expenses(:'org_id', null, null, 'category') where group_id = 'none'), 80 + 60 + 3000 + 40 + 30 + 22, 'by category: everything without a category');
select t.eq_text((select group_label from report_expenses(:'org_id', null, null, 'category') where group_id = 'none'), 'بدون تصنيف', 'uncategorised expenses are labelled, not dropped');
select t.eq((select sum(total) from report_expenses(:'org_id', null, null, 'category')), (select sum(amount) from expenses where organization_id = :'org_id'), 'by category: Σ = every recorded expense, once');
select t.eq((select sum(total) from report_expenses(:'org_id', null, null, 'type')), (select sum(amount) from expenses where organization_id = :'org_id'), 'by type: Σ = every recorded expense');
select t.eq((select sum(total) from report_expenses(:'org_id', null, null, 'month')), (select sum(amount) from expenses where organization_id = :'org_id'), 'by month: Σ = every recorded expense');
select t.eq((select sum(expense_count) from report_expenses(:'org_id', null, null, 'category')), (select count(*) from expenses where organization_id = :'org_id'), 'the counts add up to the number of expenses');
select t.eq((select total from report_expenses(:'org_id', null, null, 'type') where group_id = 'commission_payout'), 92, 'by type: commission payouts 40 + 30 + 22');
select t.eq((select in_profit_loss from report_expenses(:'org_id', null, null, 'type') where group_id = 'commission_payout'), 0, 'commission payouts are not part of the profit & loss expenses');
select t.eq((select total from report_expenses(:'org_id', null, null, 'type') where group_id = 'salary'), 3000, 'by type: salaries');
select t.eq((select in_profit_loss from report_expenses(:'org_id', null, null, 'type') where group_id = 'salary'), 3000, 'salaries are an operating expense');
select t.eq((select sum(in_profit_loss) from report_expenses(:'org_id', null, null, 'category')), (select operating_expenses from report_profit_loss(:'org_id')), 'Σ in_profit_loss = the P&L operating expenses (3593)');
select t.eq((select sum(in_profit_loss) from report_expenses(:'org_id', null, null, 'type')), (select operating_expenses from report_profit_loss(:'org_id')), 'same by type');
select t.eq((select sum(in_profit_loss) from report_expenses(:'org_id', null, null, 'month')), (select operating_expenses from report_profit_loss(:'org_id')), 'same by month');
select t.eq((select count(*) from report_expenses(:'org_id', null, null, 'month')), 2, 'two months of expenses');
select t.eq((select total from report_expenses(:'org_id', :'dprev'::date, :'dprev'::date, 'category')), 80, 'date range: the previous-month expense');
select t.eq_text((select group_id from report_expenses(:'org_id', null, null, 'category') limit 1), 'none', 'largest category first');
select t.throws(format($q$select * from report_expenses(%L, null, null, 'bogus')$q$, :'org_id'), 'نوع التقرير غير صحيح', 'unknown grouping refused');

-- =====================================================================
-- 4. Returns by reason
-- =====================================================================
select t.eq((select count(*) from report_returns_by_reason(:'org_id')), 5, 'the reason report always lists the four reasons + unclassified');
select t.eq((select units from report_returns_by_reason(:'org_id') where group_id = 'slow_moving'), 2, 'slow-moving at the retailer: 2 units (R1)');
select t.eq((select units from report_returns_by_reason(:'org_id') where group_id = 'damaged'), 1, 'damaged: 1 unit (R2)');
select t.eq((select damaged_units from report_returns_by_reason(:'org_id') where group_id = 'damaged'), 1, 'damaged reason: the unit is also condition = damaged');
select t.eq((select units from report_returns_by_reason(:'org_id') where group_id = 'expired'), 1, 'expired: 1 unit (R3)');
select t.eq((select resalable_units from report_returns_by_reason(:'org_id') where group_id = 'expired'), 1, 'condition is reported separately from reason');
select t.eq((select units from report_returns_by_reason(:'org_id') where group_id = 'unclassified'), 1, 'a return without a reason is "unclassified" (R4), never guessed');
select t.eq((select units from report_returns_by_reason(:'org_id') where group_id = 'other'), 0, '"other": none, but still listed');
select t.eq_text((select group_label from report_returns_by_reason(:'org_id') where group_id = 'slow_moving'), 'عدم الدوران عند التاجر', 'the retailer slow-moving label');
select t.eq_text((select group_label from report_returns_by_reason(:'org_id') where group_id = 'damaged'), 'تالف', 'damaged label');
select t.eq_text((select group_label from report_returns_by_reason(:'org_id') where group_id = 'expired'), 'صلاحية منتهية', 'expired label');
select t.eq((select returns from report_returns_by_reason(:'org_id') where group_id = 'slow_moving'), 1, 'one return document per reason here');
select t.eq((select sum(value) from report_returns_by_reason(:'org_id')), (select sum(subtotal_reversed) from sales_returns where organization_id = :'org_id'), 'Σ value over the reasons = the return documents (nothing doubled)');
select t.eq((select sum(units) from report_returns_by_reason(:'org_id')), (select sum(quantity) from sales_return_items where organization_id = :'org_id'), 'Σ units = every returned unit');
select t.ok(abs((select sum(share_pct) from report_returns_by_reason(:'org_id')) - 100) < 0.05, 'shares add up to 100% (each is rounded to 2 decimals)');
select t.eq((select sum(value) from report_returns_by_reason(:'org_id')), (select returns_value from report_profit_loss(:'org_id')), 'returns report value = the returns line of the P&L');
select t.eq((select sum(value) from report_returns_by_reason(:'org_id', null, null, 'product')), (select sum(value) from report_returns_by_reason(:'org_id')), 'by product: same total');
select t.eq((select sum(value) from report_returns_by_reason(:'org_id', null, null, 'customer')), (select sum(value) from report_returns_by_reason(:'org_id')), 'by customer: same total');
select t.eq((select count(*) from report_returns_by_reason(:'org_id', null, null, 'customer')), 3, 'by customer: 3 distinct customers returned goods (customer A twice)');
-- filters: return date, reason, rep
select t.eq((select sum(units) from report_returns_by_reason(:'org_id', :'dprev'::date, :'dprev'::date)), 1, 'date range uses the RETURN date: only R4 in the previous month');
select t.eq((select sum(units) from report_returns_by_reason(:'org_id', :'m0'::date, :'d0'::date)), 4, 'this month: R1 (2) + R2 + R3');
select t.eq((select count(*) from report_returns_by_reason(:'org_id', null, null, 'reason', 'damaged')), 1, 'reason filter keeps that reason only');
select t.eq((select sum(units) from report_returns_by_reason(:'org_id', null, null, 'reason', 'unclassified')), 1, 'the unclassified filter');
select t.eq((select sum(units) from report_returns_by_reason(:'org_id', null, null, 'reason', null, null, :'repa')), 3, 'rep filter: rep A''s invoices were returned 2 + 1 times');
select t.eq((select sum(units) from report_returns_by_reason(:'org_id', null, null, 'reason', null, :'w1')), 5, 'warehouse filter (all returns went to warehouse 1)');
select t.eq((select count(*) from report_returns_by_reason(:'org_id', null, null, 'reason', null, gen_random_uuid())), 5, 'a warehouse with no returns still lists the five reasons (zeros)');
select t.eq((select sum(units) from report_returns_by_reason(:'org_id', null, null, 'reason', null, gen_random_uuid())), 0, 'with zero units');
-- validation and compatibility
select t.throws(format($q$select create_sales_return(%L, %L, current_date, jsonb_build_array(jsonb_build_object('sales_invoice_item_id', %L, 'quantity', 1, 'condition', 'resalable', 'reason', 'whatever')), 0, null)$q$, :'org_id', :'s4_id', (select id from sales_invoice_items where sales_invoice_id = :'s4_id')), 'سبب المرتجع غير صحيح', 'an unknown reason is refused');
select t.eq((select count(*) from sales_returns where sales_invoice_id = :'s4_id'), 0, 'and creates no return');
select t.throws(format($q$select * from report_returns_by_reason(%L, null, null, 'reason', 'whatever')$q$, :'org_id'), 'سبب المرتجع غير صحيح', 'unknown reason filter refused');
select t.throws(format($q$update sales_return_items set return_reason = 'other' where sales_return_id = %L$q$, :'r1_id'), 'permission denied', 'a recorded reason cannot be rewritten');
select t.eq((select quantity from inventory_stock where product_id = :'px' and warehouse_id = :'w1'), 200 - 5 - 10 - 20 - 20 - 5 + 2 + 1 - 0 + 1, 'stock still follows the existing rules (damaged units do not re-enter)');

-- =====================================================================
-- 5. Rep payroll and commissions
-- =====================================================================
select t.eq((select count(*) from report_rep_payroll(:'org_id', :'m0'::date)), 3, 'payroll: the three reps');
-- rep A
select t.eq((select fixed_salary from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repa'), 3000, 'A: base salary');
select t.eq((select transportation_allowance from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repa'), 500, 'A: transport allowance');
select t.eq_text((select commission_basis from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repa'), 'net_sales', 'A: commission basis');
select t.eq((select sales_commission from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repa'), 90, 'A: sales commission = 5% of S2''s net sales (1800)');
select t.eq((select collection_commission from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repa'), 0, 'A: no collection commission (basis is not collections)');
select t.eq((select salary_paid from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repa'), 3000, 'A: salary paid this month');
select t.eq((select commission_paid from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repa'), 40, 'A: commission paid this month');
select t.eq((select rep_expenses_paid from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repa'), 60, 'A: rep expenses (a reimbursement, shown apart from salary)');
select t.eq((select commission_payable from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repa'), 50 + 90 - 40, 'A: payable = all earned (50 + 90) − all paid (40)');
select t.eq((select collections_count from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repa'), 1, 'A: one collection this month (on account)');
select t.eq((select collected_amount from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repa'), 100, 'A: 100 collected');
-- rep B: commission on COLLECTED cash
select t.eq((select collection_commission from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repb'), 120, 'B: collection commission = 10% of the 1200 collected on S3 (500 on the spot + 700 later)');
select t.eq((select sales_commission from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repb'), 0, 'B: no sales commission');
select t.ok((select commission_eligible from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repb'), 'B reached its 1000 target');
select t.eq((select collections_count from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repb'), 2, 'B: two collections (the one made with the invoice counts)');
select t.eq((select collected_amount from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repb'), 1200, 'B: 1200 collected');
select t.eq_text((select last_collection_date::text from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repb'), :'d0', 'B: last collection date');
select t.eq_text((select first_collection_date::text from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repb'), :'m0', 'B: first collection date');
select t.eq((select commission_paid from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repb'), 52, 'B: commission paid 30 + 22');
select t.eq((select commission_payable from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repb'), 120 - 52, 'B: payable 120 − 52');
-- rep C: below the target → earns nothing although it has a potential commission
select t.ok(not (select commission_eligible from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repc'), 'C is below its 100000 target');
select t.eq((select sales_commission from report_rep_payroll(:'org_id', :'m0'::date) where rep_id = :'repc'), 0, 'C: nothing earned');
select t.eq((select potential_commission from rep_monthly_performance where rep_id = :'repc' and month = :'m0'::date), 40, 'C: the potential commission (20% of 200 profit) exists but is not earned');
-- identity with the existing model, for every rep and month
select t.eq((select count(*) from report_rep_payroll(:'org_id', :'m0'::date) p join rep_monthly_performance m on m.rep_id = p.rep_id and m.month = :'m0'::date
             where abs(p.sales_commission + p.collection_commission - m.earned_commission) > 0.005), 0, 'sales + collection commission = rep_monthly_performance.earned_commission for every rep');
select t.eq((select count(*) from report_rep_payroll(:'org_id', :'m0'::date) p where abs(p.earned_commission - (p.sales_commission + p.collection_commission)) > 0.005), 0, 'earned_commission column agrees with its two parts');
select t.eq((select count(*) from report_rep_payroll(:'org_id', date_trunc('month', :'dprev'::date)::date) p join rep_monthly_performance m on m.rep_id = p.rep_id and m.month = date_trunc('month', :'dprev'::date)::date
             where abs(p.sales_commission + p.collection_commission - m.earned_commission) > 0.005), 0, 'the same identity for the previous month');
select t.eq((select sales_commission from report_rep_payroll(:'org_id', date_trunc('month', :'dprev'::date)::date) where rep_id = :'repa'), 50, 'previous month: A earned 50 on S1');
select t.eq((select salary_paid from report_rep_payroll(:'org_id', date_trunc('month', :'dprev'::date)::date) where rep_id = :'repa'), 0, 'previous month: no salary was recorded');
-- no double counting between payroll and the P&L
select t.eq((select sum(earned_commission) from report_rep_payroll(:'org_id', date_trunc('month', :'dprev'::date)::date)) + (select sum(earned_commission) from report_rep_payroll(:'org_id', :'m0'::date)), (select commissions from report_profit_loss(:'org_id')), 'Σ earned commissions in the payroll over both months = the P&L commissions');
select t.eq((select sum(salary_paid) + sum(rep_expenses_paid) from report_rep_payroll(:'org_id', :'m0'::date)), 3060, 'salaries + rep expenses in the payroll are operating expenses of the P&L (3000 + 60)');
select t.eq((select sum(commission_paid) from report_rep_payroll(:'org_id', :'m0'::date)), 92, 'payouts are shown as paid, and are only cash');
-- the collection log (collection dates)
select t.eq((select count(*) from report_rep_collections(:'org_id', :'m0'::date, :'d0'::date)), 3, 'collection log: A 1 + B 2 (the customer without a rep is not a rep collection)');
select t.eq((select total_amount from report_rep_collections(:'org_id', :'m0'::date, :'d0'::date) limit 1), 1300, 'collection log total 100 + 500 + 700');
select t.eq((select count(*) from report_rep_collections(:'org_id', null, null, :'repb')), 2, 'rep filter: B''s two collections');
select t.ok((select bool_and(counts_for_commission) from report_rep_collections(:'org_id', null, null, :'repb')), 'B''s collections are linked to a collected-amount invoice → they count for commission');
select t.ok(not coalesce((select counts_for_commission from report_rep_collections(:'org_id', null, null, :'repa') limit 1), false), 'A''s on-account collection does not count for commission');
select t.eq_text((select invoice_number from report_rep_collections(:'org_id', null, null, :'repb') where reference = 'COL-S3'), 'S3', 'a collection names its invoice');
select t.eq_text((select collection_date::text from report_rep_collections(:'org_id', :'d0'::date, :'d0'::date, :'repb') limit 1), :'d0', 'the collection date is shown (and filterable)');
select t.eq((select count(*) from report_rep_collections(:'org_id', :'d0'::date + 1, :'d0'::date + 3)), 0, 'a window with no collections is empty');
select t.eq((select count(*) from report_rep_collections(:'org_id', null, null, null, 1, 0)), 1, 'limit works');
select t.eq((select total_count from report_rep_collections(:'org_id', null, null, null, 1, 0)), 3, 'and total_count reports the full size');

-- =====================================================================
-- 6. Cash: treasury reconciles with the documents; opening balances
-- =====================================================================
select t.eq((select count(*) from report_cash_reconciliation(:'org_id')), 6, 'six reconciliation checks');
select t.eq((select count(*) from report_cash_reconciliation(:'org_id') where abs(difference) > 0.005), 0, 'every treasury total equals the documents that created it');
select t.eq((select treasury_amount from report_cash_reconciliation(:'org_id') where check_key = 'customer_receipts'), 500 + 700 + 100 + 44, 'customer receipts 500 (with S3) + 700 + 100 + 44');
select t.eq((select treasury_amount from report_cash_reconciliation(:'org_id') where check_key = 'supplier_payments'), 2000 + 500 + 111, 'supplier payments 2000 (with the purchase) + 500 + 111');
select t.eq((select treasury_amount from report_cash_reconciliation(:'org_id') where check_key = 'expenses'), 3593 + 92, 'expenses = operating 3593 + commission payouts 92 (all cash out)');
select t.eq((select treasury_amount from report_cash_reconciliation(:'org_id') where check_key = 'partner_withdrawals'), 200, 'partner withdrawals');
select t.eq((select treasury_amount from report_cash_reconciliation(:'org_id') where check_key = 'customer_refunds'), 50, 'cash refunded to customers');
select t.eq((select treasury_amount from report_cash_reconciliation(:'org_id') where check_key = 'supplier_refunds'), 100, 'cash received back from suppliers');
select t.eq((select count(*) from report_cash_reconciliation(:'org_id', :'dprev'::date, :'dprev'::date) where abs(difference) > 0.005), 0, 'and for a single day');
-- the cash statement: opening (account opening balance) + in − out = closing = the account balances
select t.eq(((select report_treasury_summary(:'org_id')->>'opening')::numeric), 1000, 'opening cash = the account''s opening balance (1000)');
select t.eq(((select report_treasury_summary(:'org_id')->>'closing')::numeric), (select sum(balance) from treasury_balances where organization_id = :'org_id'), 'closing cash = the account balances');
select t.eq(((select report_treasury_summary(:'org_id')->>'closing')::numeric), 1000 + ((select report_treasury_summary(:'org_id')->>'total_in')::numeric) - ((select report_treasury_summary(:'org_id')->>'total_out')::numeric), 'closing = opening + total in − total out');
select t.eq(((select report_treasury_summary(:'org_id')->>'total_in')::numeric), 500 + 700 + 100 + 44 + 150 + 100, 'total collected/received = customer receipts + manual deposit + supplier refund');
select t.eq(((select report_treasury_summary(:'org_id')->>'total_out')::numeric), 2000 + 500 + 111 + 3593 + 92 + 200 + 50, 'total paid out = suppliers + expenses + commissions + partners + refunds');
-- the check catches movements made outside the documents
select t.as_owner();
insert into treasury_movements (organization_id, treasury_account_id, direction, amount, category, movement_date, source_type, description)
  values (:'org_id', :'acct', 'out', 25, 'expense', :'m0'::date, 'manual', 'خارج النظام');
select t.as_user('9c000000-0000-0000-0000-000000000001');
select t.eq((select difference from report_cash_reconciliation(:'org_id') where check_key = 'expenses'), 25, 'a stray expense movement shows up as a +25 difference');
select t.as_owner();
delete from treasury_movements where description = 'خارج النظام';
select t.as_user('9c000000-0000-0000-0000-000000000001');
select t.eq((select count(*) from report_cash_reconciliation(:'org_id') where abs(difference) > 0.005), 0, 'cleaned up: reconciled again');

-- =====================================================================
-- 7. Permissions
-- =====================================================================
select t.as_user('9c000000-0000-0000-0000-000000000003');   -- second owner: view_financial
select t.ok((select net_profit from report_profit_loss(:'org_id')) is not null, 'second owner: P&L');
select t.ok((select count(*) from report_expenses(:'org_id')) > 0, 'second owner: expenses');
select t.ok((select count(*) from report_rep_payroll(:'org_id', :'m0'::date)) > 0, 'second owner: payroll');
select t.ok((select count(*) from report_rep_collections(:'org_id')) > 0, 'second owner: collection log');
select t.ok((select count(*) from report_cash_reconciliation(:'org_id')) > 0, 'second owner: cash reconciliation');
select t.ok((select count(*) from report_returns_by_reason(:'org_id')) > 0, 'second owner: returns');
select t.as_user('9c000000-0000-0000-0000-000000000004');   -- restricted rep (rep A)
select t.throws(format('select * from report_profit_loss(%L)', :'org_id'), 'صلاحية عرض البيانات المالية', 'a rep cannot read the P&L');
select t.throws(format('select * from report_expenses(%L)', :'org_id'), 'صلاحية عرض البيانات المالية', 'nor expenses');
select t.throws(format('select * from report_rep_payroll(%L)', :'org_id'), 'صلاحية عرض البيانات المالية', 'nor payroll (other reps'' salaries)');
select t.throws(format('select * from report_rep_collections(%L)', :'org_id'), 'صلاحية عرض البيانات المالية', 'nor the collection log');
select t.throws(format('select * from report_cash_reconciliation(%L)', :'org_id'), 'صلاحية عرض البيانات المالية', 'nor the cash reconciliation');
select t.eq((select sum(units) from report_returns_by_reason(:'org_id')), 3, 'the returns report is allowed for a rep but scoped to his own customers (R1 2 + R4 1)');
select t.eq((select count(*) from report_returns_by_reason(:'org_id', null, null, 'customer')), 1, 'he sees one customer');
select t.as_user('9c000000-0000-0000-0000-000000000005');   -- storekeeper
select t.throws(format('select * from report_profit_loss(%L)', :'org_id'), 'صلاحية عرض البيانات المالية', 'a storekeeper cannot read the P&L');
select t.throws(format('select * from report_rep_payroll(%L)', :'org_id'), 'صلاحية عرض البيانات المالية', 'nor payroll');
select t.as_user('9c000000-0000-0000-0000-000000000002');   -- another organization
select t.throws(format('select * from report_profit_loss(%L)', :'org_id'), 'لست عضوًا', 'another organization cannot read my P&L');
select t.throws(format('select * from report_expenses(%L)', :'org_id'), 'لست عضوًا', 'nor expenses');
select t.throws(format('select * from report_rep_payroll(%L)', :'org_id'), 'لست عضوًا', 'nor payroll');
select t.throws(format('select * from report_returns_by_reason(%L)', :'org_id'), 'لست عضوًا', 'nor returns');
select t.throws(format('select * from report_cash_reconciliation(%L)', :'org_id'), 'لست عضوًا', 'nor the cash check');
select t.eq((select count(*) from report_expenses(:'orgb_id')), 0, 'its own organization is empty');
select t.as_anon();
select t.throws(format('select * from report_profit_loss(%L)', :'org_id'), 'permission denied', 'anonymous callers cannot run the P&L');
select t.throws(format('select * from report_rep_payroll(%L)', :'org_id'), 'permission denied', 'nor payroll');
select t.as_owner();
