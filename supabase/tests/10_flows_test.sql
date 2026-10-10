-- SRS §59 integration tests: complete transaction flows, then every Phase 6
-- report checked against numbers worked out by hand.
--
--   Purchase  → inventory ↑, supplier debt ↑, weighted-average cost
--   Sale      → inventory ↓, customer debt ↑, COGS, profit, commission
--   Collection→ customer debt ↓, treasury ↑
--   Payment   → supplier debt ↓, treasury ↓
--   Expense / partner withdrawal / manual income → treasury, and only the
--   expense touches net profit.

\set ON_ERROR_STOP on

-- ------------------------------------------------------------
-- Users + organization
-- ------------------------------------------------------------
select t.as_owner();
insert into auth.users (id, email) values
  ('a0000000-0000-0000-0000-000000000001', 'owner@flows.test'),
  ('a0000000-0000-0000-0000-000000000002', 'accountant@flows.test'),
  ('a0000000-0000-0000-0000-000000000003', 'salesman@flows.test');

select t.as_user('a0000000-0000-0000-0000-000000000001');
select create_organization('شركة الاختبار', 'تجارة', 'EG', 'EGP', 'ar',
  array['sales','customers','inventory','purchases','suppliers','expenses','treasury','representatives','partners']) as id \gset org_

-- Extra members with system roles (accountant has view_financial, sales does not).
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', 'a0000000-0000-0000-0000-000000000002', id, 'active' from roles where key = 'accountant' and organization_id is null;
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', 'a0000000-0000-0000-0000-000000000003', id, 'active' from roles where key = 'sales' and organization_id is null;

-- ------------------------------------------------------------
-- Master data
-- ------------------------------------------------------------
select t.as_user('a0000000-0000-0000-0000-000000000001');
insert into warehouses (organization_id, name) values (:'org_id', 'المخزن الرئيسي') returning id as wh \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد أ') returning id as sup \gset
insert into customers (organization_id, name) values (:'org_id', 'عميل أ') returning id as cus \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'منتج أ', 'A-1', 'قطعة') returning id as prod \gset
insert into product_prices (organization_id, product_id, selling_price) values (:'org_id', :'prod', 150);
insert into product_costs (product_id, cost) values (:'prod', 100);
insert into sales_representatives (organization_id, name, commission_basis, commission_rate)
values (:'org_id', 'مندوب أ', 'net_sales', 5) returning id as rep \gset

-- ------------------------------------------------------------
-- Purchases: 100 × 100 (paid 4,000) then 100 × 120 (unpaid)  → avg cost 110
-- ------------------------------------------------------------
select create_purchase_invoice(:'org_id', :'sup', :'wh', 'P-1', '2026-03-01',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 100, 'unit_cost', 100, 'discount_pct', 0)),
  0, 0, 4000, 'نقدًا', null) as id \gset pi1_
select create_purchase_invoice(:'org_id', :'sup', :'wh', 'P-2', '2026-03-02',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 100, 'unit_cost', 120, 'discount_pct', 0)),
  0, 0, 0, null, null) as id \gset pi2_

select t.eq((select quantity from inventory_stock where product_id = :'prod'), 200, 'purchases: stock is 200 units');
select t.eq((select avg_cost from t.stock_with_cost where product_id = :'prod'), 110, 'purchases: weighted average cost is 110 (§21 example)');
select t.eq((select balance from supplier_balances where supplier_id = :'sup'), 18000, 'purchases: supplier owed 22,000 − 4,000 paid = 18,000');

-- Give the cashbox an opening balance so the treasury figures are realistic.
select t.as_owner();
update treasury_accounts set opening_balance = 20000 where organization_id = :'org_id';
select t.as_user('a0000000-0000-0000-0000-000000000001');

select t.eq((select balance from treasury_balances where organization_id = :'org_id'), 16000, 'treasury: 20,000 opening − 4,000 paid at purchase');

-- Supplier payment (April)
select record_supplier_payment(:'org_id', :'sup', null, 3000, '2026-04-02', 'تحويل', null, null) as id \gset
select t.eq((select balance from supplier_balances where supplier_id = :'sup'), 15000, 'supplier payment: owed 15,000');

-- ------------------------------------------------------------
-- Sales
--   #1  10 × 150, collected 500 at the counter, rep on 5% of net sales
--   #2  20 × 125, invoice discount 4% (= 100), unpaid
-- ------------------------------------------------------------
select create_sales_invoice(:'org_id', :'cus', :'wh', 'S-1', '2026-03-10',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 10, 'unit_price', 150, 'discount_pct', 0)),
  0, 0, 500, 'نقدًا', null, :'rep') as id \gset si1_
select create_sales_invoice(:'org_id', :'cus', :'wh', 'S-2', '2026-04-05',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 20, 'unit_price', 125, 'discount_pct', 0)),
  4, 0, 0, null, null, null) as id \gset si2_

select t.eq((select quantity from inventory_stock where product_id = :'prod'), 170, 'sales: stock down to 170');
select t.eq((select avg_cost from t.stock_with_cost where product_id = :'prod'), 110, 'sales: average cost is untouched by a sale (§21)');
select t.eq((select cogs_total from v_sales_invoices where id = :'si1_id'), 1100, 'invoice 1 COGS = 10 × 110');
select t.eq((select profit_total from v_sales_invoices where id = :'si1_id'), 400, 'invoice 1 profit = 1,500 − 1,100');
select t.eq((select commission_amount from sales_invoices where id = :'si1_id'), 75, 'invoice 1 commission = 5% of net sales 1,500');
select t.eq((select total from sales_invoices where id = :'si2_id'), 2400, 'invoice 2 total = 2,500 − 100 (4%) discount');
select t.eq((select profit_total from v_sales_invoices where id = :'si2_id'), 200, 'invoice 2 profit = 2,400 − 2,200');
select t.eq((select unit_cost from v_sales_invoice_items where sales_invoice_id = :'si1_id'), 110, 'item line keeps its historical unit cost (§48)');

-- Collection (April)
select record_customer_collection(:'org_id', :'cus', :'si1_id', 700, '2026-04-06', 'نقدًا', null, null) as id \gset
select t.eq((select balance from customer_balances where customer_id = :'cus'), 2700, 'collection: customer owes 1,500 − 500 + 2,400 − 700 = 2,700');

-- Expense (April), partner withdrawal, manual income
select id as cat from expense_categories where organization_id = :'org_id' and name = 'الإيجار' \gset
select create_expense(:'org_id', :'cat', null, 300, '2026-04-07', 'نقدًا', 'إيجار أبريل', null) as id \gset
insert into partners (organization_id, name) values (:'org_id', 'شريك أ') returning id as par \gset
select record_partner_withdrawal(:'org_id', :'par', null, 1000, '2026-04-08', 'سحب شخصي', null) as id \gset
select record_treasury_movement(:'org_id', null, 'in', 250, '2026-04-09', 'إيراد آخر') as id \gset

select t.eq((select balance from treasury_balances where organization_id = :'org_id'), 13150,
  'treasury: 20,000 − 4,000 − 3,000 + 500 + 700 − 300 − 1,000 + 250 = 13,150');

-- Other assets / liabilities for the financial position
select add_other_balance(:'org_id', 'liability', 'قرض بنكي', 2000, null) as id \gset ob_liab_
select add_other_balance(:'org_id', 'asset', 'عهدة', 500, null) as id \gset ob_asset_

-- ============================================================
-- Reports (owner has every permission)
-- ============================================================
-- All-time summary
select report_summary(:'org_id') as j \gset all_
select t.eq((:'all_j'::jsonb #>> '{sales,gross_sales}')::numeric, 4000, 'summary: gross sales 4,000');
select t.eq((:'all_j'::jsonb #>> '{sales,discounts}')::numeric, 100, 'summary: discounts 100');
select t.eq((:'all_j'::jsonb #>> '{sales,net_sales}')::numeric, 3900, 'summary: net sales 3,900');
select t.eq((:'all_j'::jsonb #>> '{financial,cogs}')::numeric, 3300, 'summary: COGS 3,300');
select t.eq((:'all_j'::jsonb #>> '{financial,gross_profit}')::numeric, 600, 'summary: gross profit 600 = net sales − COGS (§37)');
select t.eq((:'all_j'::jsonb #>> '{financial,operating_expenses}')::numeric, 300, 'summary: operating expenses 300');
select t.eq((:'all_j'::jsonb #>> '{financial,commissions}')::numeric, 75, 'summary: commissions 75');
select t.eq((:'all_j'::jsonb #>> '{financial,net_profit}')::numeric, 225, 'summary: net profit = 600 − 300 − 75 = 225 (§38); withdrawals excluded (§34)');
select t.eq((:'all_j'::jsonb #>> '{financial,collections}')::numeric, 1200, 'summary: collections 500 + 700');
select t.eq((:'all_j'::jsonb #>> '{financial,supplier_payments}')::numeric, 7000, 'summary: supplier payments 4,000 + 3,000');
select t.eq((:'all_j'::jsonb #>> '{balances,receivable}')::numeric, 2700, 'summary: receivable 2,700');
select t.eq((:'all_j'::jsonb #>> '{balances,payable}')::numeric, 15000, 'summary: payable 15,000');
select t.eq((:'all_j'::jsonb #>> '{balances,inventory_value}')::numeric, 18700, 'summary: inventory value 170 × 110');
select t.eq((:'all_j'::jsonb #>> '{balances,treasury}')::numeric, 13150, 'summary: treasury 13,150');

-- April only: invoice 2, the expense, the April collection and payment
select report_summary(:'org_id', '2026-04-01', '2026-04-30') as j \gset apr_
select t.eq((:'apr_j'::jsonb #>> '{sales,net_sales}')::numeric, 2400, 'April: net sales 2,400 (date filter)');
select t.eq((:'apr_j'::jsonb #>> '{financial,gross_profit}')::numeric, 200, 'April: gross profit 200');
select t.eq((:'apr_j'::jsonb #>> '{financial,net_profit}')::numeric, -100, 'April: net profit 200 − 300 = −100');
select t.eq((:'apr_j'::jsonb #>> '{financial,collections}')::numeric, 700, 'April: collections 700');
select t.eq((:'apr_j'::jsonb #>> '{financial,supplier_payments}')::numeric, 3000, 'April: supplier payments 3,000');
select t.eq((:'apr_j'::jsonb #>> '{financial,purchases}')::numeric, 0, 'April: no purchases');

-- Breakdowns reconcile with each other
select t.eq((select sum(net_sales) from report_sales_breakdown(:'org_id', null, null, 'customer')), 3900, 'by customer: net 3,900');
select t.eq((select sum(net_sales) from report_sales_breakdown(:'org_id', null, null, 'invoice')), 3900, 'by invoice: net 3,900');
select t.eq((select sum(net_sales) from report_sales_breakdown(:'org_id', null, null, 'date')), 3900, 'by date: net 3,900');
select t.eq((select sum(net_sales) from report_sales_breakdown(:'org_id', null, null, 'representative')), 3900, 'by representative: net 3,900');
select t.eq((select sum(net_sales) from report_sales_breakdown(:'org_id', null, null, 'product')), 3900, 'by product: net 3,900 (invoice discount allocated to lines)');
select t.eq((select sum(gross_profit) from report_sales_breakdown(:'org_id', null, null, 'product')), 600, 'by product: profit 600 reconciles with invoices');
select t.eq((select gross_profit from report_sales_breakdown(:'org_id', null, null, 'representative') where group_label = 'مندوب أ'), 400, 'by representative: 400 profit for the rep');
select t.eq((select net_sales from report_sales_breakdown(:'org_id', null, null, 'representative') where group_label = 'بدون مندوب'), 2400, 'by representative: unassigned sales are shown, not lost');
select t.eq((select quantity from report_sales_breakdown(:'org_id', null, null, 'product')), 30, 'by product: 30 units sold');
select t.eq((select count(*) from report_sales_breakdown(:'org_id', '2026-04-01', '2026-04-30', 'invoice')), 1, 'invoice list honours the date range');
select t.eq((select total_count from report_sales_breakdown(:'org_id', null, null, 'invoice', 1, 0)), 2, 'pagination: total_count is the full count');
select t.eq((select count(*) from report_sales_breakdown(:'org_id', null, null, 'invoice', 1, 0)), 1, 'pagination: limit is applied');
select t.eq((select margin from (select round(100 * gross_profit / nullif(net_sales, 0), 2) as margin from report_sales_breakdown(:'org_id', null, null, 'invoice') where group_label = 'S-1') m), 26.67, 'invoice margin 400 / 1,500 = 26.67%');

-- Time series
select t.eq((select sum(net_sales) from report_timeseries(:'org_id', null, null, 'month')), 3900, 'timeseries: monthly net sales 3,900');
select t.eq((select count(*) from report_timeseries(:'org_id', null, null, 'month')), 2, 'timeseries: two months (March, April)');
select t.eq((select expenses from report_timeseries(:'org_id', '2026-04-01', '2026-04-30', 'month')), 300, 'timeseries: April expenses 300');

-- Inventory
select t.eq((select sum(stock_value) from report_inventory_stock(:'org_id')), 18700, 'inventory report: value 18,700');
select t.eq((select count(*) from report_stock_movements(:'org_id', null, null, null, null, 'sale')), 2, 'stock movements: 2 sales movements');
select t.eq((select count(*) from report_stock_movements(:'org_id', null, null, null, null, null)), 4, 'stock movements: 2 purchases + 2 sales');

-- Customer / supplier balances + ledger
select t.eq((select balance from report_party_balances(:'org_id', 'customer') where party_id = :'cus'), 2700, 'customer balance report: 2,700');
select t.eq((select balance from report_party_balances(:'org_id', 'supplier') where party_id = :'sup'), 15000, 'supplier balance report: 15,000');
select t.eq((select balance from report_party_ledger(:'org_id', 'customer', :'cus') order by entry_date desc, balance limit 1), 2700, 'customer ledger ends at the balance');
select t.eq((select count(*) from report_party_ledger(:'org_id', 'customer', :'cus')), 4, 'customer ledger: 2 sales + 2 collections');
-- Running balance is right at every step, including the same-instant sale + collection.
select t.eq((select balance from report_party_ledger(:'org_id', 'customer', :'cus') where entry_type = 'sale' and reference = 'S-1'), 1500, 'ledger: after sale S-1 the balance is 1,500');
select t.eq((select balance from report_party_ledger(:'org_id', 'customer', :'cus') where entry_type = 'collection' and decrease = 500), 1000, 'ledger: after the counter collection it is 1,000');
select t.eq((select balance from report_party_ledger(:'org_id', 'customer', :'cus', '2026-04-01', null) where entry_type = 'opening'), 1000, 'ledger: opening balance at 1 April is 1,000');
select t.eq((select count(*) from report_party_ledger(:'org_id', 'customer', :'cus', '2026-04-01', null)), 3, 'ledger: opening + 2 April entries');
select t.eq((select balance from report_party_ledger(:'org_id', 'supplier', :'sup') order by entry_date desc, balance limit 1), 15000, 'supplier ledger ends at 15,000');

-- Treasury
select report_treasury_summary(:'org_id', '2026-04-01', '2026-04-30') as j \gset tre_
select t.eq((:'tre_j'::jsonb ->> 'opening')::numeric, 16500, 'treasury April: opening 16,500 (20,000 − 4,000 paid + 500 collected in March)');
select t.eq((:'tre_j'::jsonb ->> 'total_in')::numeric, 950, 'treasury April: in 700 + 250');
select t.eq((:'tre_j'::jsonb ->> 'total_out')::numeric, 4300, 'treasury April: out 3,000 + 300 + 1,000');
select t.eq((:'tre_j'::jsonb ->> 'closing')::numeric, 13150, 'treasury April: closing = opening + in − out, and equals the live balance');
select t.eq((select count(*) from report_treasury_movements(:'org_id', '2026-04-01', '2026-04-30', 'partner_withdrawal')), 1, 'treasury movements: category filter');

-- Financial position + رأس المال العام
select report_financial_position(:'org_id') as j \gset pos_
select t.eq((:'pos_j'::jsonb ->> 'inventory_value')::numeric, 18700, 'position: inventory 18,700');
select t.eq((:'pos_j'::jsonb ->> 'receivables')::numeric, 2700, 'position: receivables 2,700');
select t.eq((:'pos_j'::jsonb ->> 'cash')::numeric, 13150, 'position: cash 13,150');
select t.eq((:'pos_j'::jsonb ->> 'payables')::numeric, 15000, 'position: payables 15,000');
select t.eq((:'pos_j'::jsonb ->> 'other_liabilities')::numeric, 2000, 'position: other liabilities 2,000');
select t.eq((:'pos_j'::jsonb ->> 'other_assets')::numeric, 500, 'position: other assets 500');
select t.eq((:'pos_j'::jsonb ->> 'general_capital')::numeric, 17550, 'رأس المال العام = 18,700 + 2,700 + 13,150 − 15,000 − 2,000 = 17,550 (§41)');
select t.eq((:'pos_j'::jsonb ->> 'net_position')::numeric, 18050, 'net business position adds other assets: 18,050 (§40)');

-- Deactivating an other-balance removes it from the totals but keeps the row (§47)
select deactivate_other_balance(:'org_id', :'ob_liab_id');
select report_financial_position(:'org_id') as j \gset pos2_
select t.eq((:'pos2_j'::jsonb ->> 'general_capital')::numeric, 19550, 'position: deactivated liability no longer counts');
select t.eq((select count(*) from other_balances where id = :'ob_liab_id' and not is_active), 1, 'deactivated item is kept, not deleted');

-- Recent activity feed
select t.ok((select count(*) from report_recent_activity(:'org_id', 20)) >= 6, 'recent activity lists sales, purchases, collections, payments and expenses');

-- ============================================================
-- Permissions inside the database (§14): the salesman has no view_financial
-- ============================================================
select t.as_user('a0000000-0000-0000-0000-000000000003');
select t.throws(format('select report_financial_position(%L)', :'org_id'), 'صلاحية', 'salesman cannot read the financial position');
select t.throws(format('select * from report_party_balances(%L, ''customer'')', :'org_id'), 'صلاحية', 'salesman cannot read customer balances');
select t.throws(format('select report_treasury_summary(%L)', :'org_id'), 'صلاحية', 'salesman cannot read the treasury');
select report_summary(:'org_id') as j \gset sm_
select t.ok((:'sm_j'::jsonb -> 'financial') = 'null'::jsonb and (:'sm_j'::jsonb -> 'balances') = 'null'::jsonb, 'salesman: summary carries no profit, cost or balances');
select t.ok((select bool_and(cogs is null and gross_profit is null and commission is null) from report_sales_breakdown(:'org_id', null, null, 'invoice')), 'salesman: cost, profit and commission columns are NULL');
select t.ok((select bool_and(avg_cost is null and stock_value is null) from report_inventory_stock(:'org_id')), 'salesman: stock cost and value are NULL');
select t.eq((select sum(net_sales) from report_sales_breakdown(:'org_id', null, null, 'customer')), 3900, 'salesman still sees sales figures');
select t.ok((select count(*) from report_recent_activity(:'org_id', 20)) >= 1 and (select bool_and(kind = 'sale') from report_recent_activity(:'org_id', 20)), 'salesman: activity feed is sales only');
select t.throws(format('select add_other_balance(%L, ''liability'', ''x'', 10, null)', :'org_id'), 'صلاحية', 'salesman cannot record other liabilities');
select t.empty('select * from other_balances', 'salesman cannot read other_balances directly');

-- The accountant does have view_financial
select t.as_user('a0000000-0000-0000-0000-000000000002');
select t.eq((report_financial_position(:'org_id') ->> 'general_capital')::numeric, 19550, 'accountant can read the financial position');

-- Anonymous callers get nothing
select t.as_anon();
select t.throws(format('select report_summary(%L)', :'org_id'), 'permission denied', 'anon cannot execute report functions');

select t.as_owner();
