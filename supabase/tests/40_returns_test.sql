-- SRS §27/§28/§36/§46 Sales Returns: resalable vs damaged condition,
-- over-return rejection, duplicate-guard, permission gating, tenant
-- isolation, cash refunds, and every report function that now accounts
-- for returns.

\set ON_ERROR_STOP on

select t.as_owner();
insert into auth.users (id, email) values
  ('e0000000-0000-0000-0000-000000000001', 'owner@returns.test'),
  ('e0000000-0000-0000-0000-000000000002', 'sales@returns.test');

select t.as_user('e0000000-0000-0000-0000-000000000001');
select create_organization('شركة المرتجعات', 'x', 'EG', 'EGP', 'ar', array['sales','customers','inventory','purchases','suppliers','expenses','treasury']) as id \gset org_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', 'e0000000-0000-0000-0000-000000000002', id, 'active' from roles where key = 'sales' and organization_id is null;
select t.as_user('e0000000-0000-0000-0000-000000000001');

insert into warehouses (organization_id, name) values (:'org_id', 'المخزن') returning id as wh \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as sup \gset
insert into customers (organization_id, name) values (:'org_id', 'عميل') returning id as cus \gset
insert into products (organization_id, name) values (:'org_id', 'منتج') returning id as prod \gset

-- 100 units @ cost 100 → stock 100 @ avg_cost 100
select create_purchase_invoice(:'org_id', :'sup', :'wh', 'P-1', '2026-03-01',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 100, 'unit_cost', 100, 'discount', 0)),
  0, 0, 10000, 'نقدًا', null) as id \gset

-- Sale S-1: 10 units @ 200, unpaid
select create_sales_invoice(:'org_id', :'cus', :'wh', 'S-1', '2026-03-10',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 10, 'unit_price', 200, 'discount', 0)),
  0, 0, 0, null, null, null) as id \gset s1_
select id as s1_item from sales_invoice_items where sales_invoice_id = :'s1_id' \gset

select t.eq((select quantity from inventory_stock where product_id = :'prod'), 90, 'after the sale, stock is 90');
select t.eq((select cogs_total from v_sales_invoices where id = :'s1_id'), 1000, 'invoice COGS = 10 × 100');
select t.eq((select profit_total from v_sales_invoices where id = :'s1_id'), 1000, 'invoice profit = 2,000 − 1,000');

-- ============================================================
-- Permission gating: a plain sales role has sales.create but not
-- sales.approve, which is what returns are gated on.
-- ============================================================
select t.as_user('e0000000-0000-0000-0000-000000000002');
select t.throws(
  format('select create_sales_return(%L, %L, %L, %L::jsonb, 0, null)', :'org_id', :'s1_id', '2026-03-15',
    jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'s1_item', 'quantity', 1, 'condition', 'resalable'))::text),
  'صلاحية تسجيل مرتجعات', 'a plain sales role (no sales.approve) cannot create a return');
select t.as_user('e0000000-0000-0000-0000-000000000001');

-- ============================================================
-- Return #1: 3 units, resalable
-- ============================================================
select create_sales_return(:'org_id', :'s1_id', '2026-03-15',
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'s1_item', 'quantity', 3, 'condition', 'resalable')),
  0, 'تالف في التغليف') as id \gset ret1_

select t.eq((select quantity from inventory_stock where product_id = :'prod'), 93, 'resalable return: stock goes back up to 93');
select t.eq((select avg_cost from t.stock_with_cost where product_id = :'prod'), 100, 'resalable return: average cost is unchanged (returned at its own historical cost)');
select t.eq((select total from sales_returns where id = :'ret1_id'), 600, 'return 1: revenue reversed = 3 × 200');
select t.eq((select cost_reversed from v_sales_returns where id = :'ret1_id'), 300, 'return 1: cost reversed = 3 × 100 (resalable)');
select t.eq((select profit_reversed from v_sales_returns where id = :'ret1_id'), 300, 'return 1: profit reversed = 600 − 300');
select t.eq((select count(*) from inventory_movements where reference_type = 'sales_return' and reference_id = :'ret1_id'), 1, 'resalable return writes an inventory movement');

-- Over-return: only 7 of the original 10 remain returnable now
select t.throws(
  format('select create_sales_return(%L, %L, %L, %L::jsonb, 0, null)', :'org_id', :'s1_id', '2026-03-16',
    jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'s1_item', 'quantity', 8, 'condition', 'resalable'))::text),
  'أكبر من المتاح', 'returning more than what remains on the line is refused');

-- ============================================================
-- Return #2: 2 units, damaged — no restock, full revenue hits profit
-- ============================================================
select create_sales_return(:'org_id', :'s1_id', '2026-03-16',
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'s1_item', 'quantity', 2, 'condition', 'damaged')),
  0, 'تلف أثناء الشحن') as id \gset ret2_

select t.eq((select quantity from inventory_stock where product_id = :'prod'), 93, 'damaged return: stock does NOT go back up');
select t.eq((select cost_reversed from v_sales_returns where id = :'ret2_id'), 0, 'damaged return: no cost reversal');
select t.eq((select profit_reversed from v_sales_returns where id = :'ret2_id'), 400, 'damaged return: full reversed revenue hits profit (2 × 200)');
select t.eq((select count(*) from inventory_movements where reference_type = 'sales_return' and reference_id = :'ret2_id'), 0, 'damaged return writes no inventory movement');

-- Duplicate-submission guard: same invoice, same return_date, immediately again
select t.throws(
  format('select create_sales_return(%L, %L, %L, %L::jsonb, 0, null)', :'org_id', :'s1_id', '2026-03-16',
    jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'s1_item', 'quantity', 1, 'condition', 'resalable'))::text),
  'تم تسجيل عملية مطابقة', 'a second return on the same invoice/date within 5 seconds is rejected');

-- get_returnable_items reflects both returns
select t.eq((select returnable from get_returnable_items(:'org_id', :'s1_id') where sales_invoice_item_id = :'s1_item'), 5, 'returnable quantity is 10 − 3 − 2 = 5');

-- ============================================================
-- Reports
-- ============================================================
select t.eq((select total_returned from customer_balances where customer_id = :'cus'), 1000, 'customer_balances: total returned 600 + 400 = 1,000');
select t.eq((select balance from customer_balances where customer_id = :'cus'), 1000, 'customer_balances: balance = 2,000 − 0 collected − 1,000 returned');

select report_summary(:'org_id') as j \gset sum_
select t.eq((:'sum_j'::jsonb #>> '{sales,returns}')::numeric, 1000, 'report_summary: returns line is 1,000');
select t.eq((:'sum_j'::jsonb #>> '{sales,net_sales}')::numeric, 1000, 'report_summary: net sales = 2,000 − 0 discount − 1,000 returns');
select t.eq((:'sum_j'::jsonb #>> '{financial,cogs}')::numeric, 700, 'report_summary: COGS = 1,000 − 300 resalable cost reversed');
select t.eq((:'sum_j'::jsonb #>> '{financial,gross_profit}')::numeric, 300, 'report_summary: gross profit = 1,000 (orig) − 700 (both reversals)');

select t.eq((select returns from report_sales_breakdown(:'org_id', null, null, 'invoice') where group_label = 'S-1'), 1000, 'by invoice: returns netted against S-1');
select t.eq((select net_sales from report_sales_breakdown(:'org_id', null, null, 'invoice') where group_label = 'S-1'), 1000, 'by invoice: net sales after returns');
select t.eq((select quantity from report_sales_breakdown(:'org_id', null, null, 'invoice') where group_label = 'S-1'), 5, 'by invoice: quantity net of both returns (10 − 5)');
select t.eq((select gross_profit from report_sales_breakdown(:'org_id', null, null, 'invoice') where group_label = 'S-1'), 300, 'by invoice: profit net of both returns');
select t.eq((select returns from report_sales_breakdown(:'org_id', null, null, 'customer')), 1000, 'by customer: returns netted');
select t.eq((select returns from report_sales_breakdown(:'org_id', null, null, 'product')), 1000, 'by product: returns netted');
select t.eq((select quantity from report_sales_breakdown(:'org_id', null, null, 'product')), 5, 'by product: quantity net of both returns');
select t.eq((select gross_profit from report_sales_breakdown(:'org_id', null, null, 'product')), 300, 'by product: profit net of both returns');

select t.eq((select count(*) from report_party_ledger(:'org_id', 'customer', :'cus') where entry_type = 'return'), 2, 'customer ledger lists both returns');
select t.eq((select balance from report_party_ledger(:'org_id', 'customer', :'cus') order by entry_date desc, balance limit 1), 1000, 'customer ledger ends at 1,000 after both returns');

select t.eq((select count(*) from report_recent_activity(:'org_id', 20) where kind = 'sales_return'), 2, 'recent activity lists both returns');

-- A plain sales role (no view_financial) still sees returns happened, just
-- not cost/profit — same treatment as a plain sale.
select t.as_owner();
select t.make_rep(:'org_id', 'e0000000-0000-0000-0000-000000000002');
select t.as_user('e0000000-0000-0000-0000-000000000002');
select t.ok((select count(*) from report_recent_activity(:'org_id', 20) where kind = 'sales_return') = 2, 'sales role still sees return activity (no financial figures exposed)');
select t.ok((select bool_and(cogs is null and gross_profit is null) from report_sales_breakdown(:'org_id', null, null, 'invoice')), 'sales role: cost/profit columns stay NULL even with returns present');
select t.eq((select returns from report_sales_breakdown(:'org_id', null, null, 'invoice') where group_label = 'S-1'), 1000, 'sales role still sees the returns figure itself (not financial)');
select t.as_user('e0000000-0000-0000-0000-000000000001');

-- ============================================================
-- Cash refund on a second, independent sale
-- ============================================================
select create_sales_invoice(:'org_id', :'cus', :'wh', 'S-2', '2026-03-20',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 5, 'unit_price', 100, 'discount', 0)),
  0, 0, 500, 'نقدًا', null, null) as id \gset s2_
select id as s2_item from sales_invoice_items where sales_invoice_id = :'s2_id' \gset
select balance as treasury_before from treasury_balances where organization_id = :'org_id' \gset

select t.throws(
  format('select create_sales_return(%L, %L, %L, %L::jsonb, 999, null)', :'org_id', :'s2_id', '2026-03-21',
    jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'s2_item', 'quantity', 2, 'condition', 'resalable'))::text),
  'أكبر من قيمة المرتجع', 'a cash refund larger than the return itself is refused');

select create_sales_return(:'org_id', :'s2_id', '2026-03-21',
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'s2_item', 'quantity', 2, 'condition', 'resalable')),
  200, 'العميل فضّل استرجاع نقدي') as id \gset ret3_

select t.eq((select cash_refunded from sales_returns where id = :'ret3_id'), 200, 'cash refund is recorded on the return');
select t.eq((select balance from treasury_balances where organization_id = :'org_id'), :'treasury_before'::numeric - 200, 'cash refund reduces the treasury balance');
select t.eq((select count(*) from treasury_movements where source_type = 'sales_return' and source_id = :'ret3_id'), 1, 'cash refund writes its own treasury movement');

-- ============================================================
-- Tenant isolation and module enforcement
-- ============================================================
select t.as_owner();
insert into auth.users (id, email) values ('e0000000-0000-0000-0000-000000000003', 'other@returns.test');
select t.as_user('e0000000-0000-0000-0000-000000000003');
select create_organization('شركة أخرى', 'x', 'EG', 'EGP', 'ar', array['sales']) as id \gset otherorg_
select t.throws(
  format('select create_sales_return(%L, %L, %L, %L::jsonb, 0, null)', :'otherorg_id', :'s1_id', '2026-03-22',
    jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'s1_item', 'quantity', 1, 'condition', 'resalable'))::text),
  'لا تنتمي إلى هذه المؤسسة', 'a return cannot reference another organization''s invoice');

select t.as_owner();
update organization_modules set enabled = false where organization_id = :'org_id' and module_key = 'sales';
select t.as_user('e0000000-0000-0000-0000-000000000001');
select t.throws(
  format('select create_sales_return(%L, %L, %L, %L::jsonb, 0, null)', :'org_id', :'s2_id', '2026-03-23',
    jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'s2_item', 'quantity', 1, 'condition', 'resalable'))::text),
  'غير مفعّلة', 'a return is refused once the sales module is disabled, same as any other sales action');

select t.as_owner();
update organization_modules set enabled = true where organization_id = :'org_id' and module_key = 'sales';

-- ============================================================
-- Audit trail (§46: "Return creation" is a required auditable action)
-- ============================================================
select t.eq((select count(*) from audit_logs where organization_id = :'org_id' and entity = 'sales_return'), 3, 'every return creation is audited');
select t.eq((select (after_data ->> 'total')::numeric from audit_logs where entity = 'sales_return' and entity_id = :'ret1_id'), 600, 'the audit row captures the return''s finished total (deferred trigger)');

select t.as_owner();
