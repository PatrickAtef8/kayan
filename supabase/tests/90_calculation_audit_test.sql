-- 0022: regression tests for every finding in KAYAN_CALCULATION_AUDIT.md.
-- Every expected value below is calculated by hand in the comment above it.
-- Exact-cent comparisons use eq_text on round(x, 2)::text so a 0.01 drift fails.

\set ON_ERROR_STOP on

select t.as_owner();
insert into auth.users (id, email) values ('a9000000-0000-0000-0000-000000000001', 'audit@calc.test');
select t.as_user('a9000000-0000-0000-0000-000000000001');
select create_organization('تدقيق', 'x', 'EG', 'EGP', 'ar', array['sales','customers','inventory','purchases','suppliers','expenses','treasury','representatives']) as id \gset org_

insert into warehouses (organization_id, name) values (:'org_id', 'W1') returning id as w1 \gset
insert into warehouses (organization_id, name) values (:'org_id', 'W2') returning id as w2 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'S1') returning id as s1 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'S2') returning id as s2 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'S3') returning id as s3 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'S4') returning id as s4 \gset
insert into products (organization_id, name) values (:'org_id', 'PA') returning id as pa \gset
insert into products (organization_id, name) values (:'org_id', 'PB') returning id as pb \gset
insert into products (organization_id, name) values (:'org_id', 'PC') returning id as pc \gset
insert into products (organization_id, name) values (:'org_id', 'PD') returning id as pd \gset
insert into products (organization_id, name) values (:'org_id', 'PE') returning id as pe \gset
insert into products (organization_id, name) values (:'org_id', 'PF') returning id as pf \gset

-- ============================================================
-- #1 purchase: line discount flows into subtotal / discount / total / stock cost
--   10 × 100 = 1,000 gross, line discount 100 → line 900, total 900, avg cost 90
-- ============================================================
select create_purchase_invoice(:'org_id', :'s1', :'w1', 'A-1', '2026-09-01',
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 10, 'unit_cost', 100, 'discount', 100)), 0, 0, 0, null, null) as id \gset a1_
select t.eq_text((select line_total::text from purchase_invoice_items where purchase_invoice_id = :'a1_id'), '900.00', '#1 purchase line total = 1,000 − 100');
select t.eq_text((select subtotal::text from purchase_invoices where id = :'a1_id'), '1000.00', '#1 purchase subtotal is gross 1,000');
select t.eq_text((select discount_total::text from purchase_invoices where id = :'a1_id'), '100.00', '#1 purchase discount_total includes the line discount');
select t.eq_text((select total::text from purchase_invoices where id = :'a1_id'), '900.00', '#1 purchase total = 900 (was 1,000)');
select t.eq_text((select round(avg_cost, 2)::text from inventory_stock where product_id = :'pa'), '90.00', '#1 stock is valued at the net cost 90, not 100');

-- ============================================================
-- #1/#2 purchase with line discount + invoice discount + tax, then full return
--   10 × 50 = 500; line discount 50; invoice discount 45; tax 63
--   net = 500 − 50 − 45 = 405 ; total = 405 + 63 = 468 ; avg cost 40.50
--   full return credits exactly 468 → supplier balance 0
-- ============================================================
select create_purchase_invoice(:'org_id', :'s2', :'w1', 'B-1', '2026-09-02',
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 10, 'unit_cost', 50, 'discount', 50)), 45, 63, 0, null, null) as id \gset b1_
select t.eq_text((select total::text from purchase_invoices where id = :'b1_id'), '468.00', '#1 purchase total = 500 − 50 − 45 + 63');
select t.eq_text((select discount_total::text from purchase_invoices where id = :'b1_id'), '95.00', '#1 discount_total = 45 + 50');
select t.eq_text((select round(avg_cost, 4)::text from inventory_stock where product_id = :'pb'), '40.5000', '#1 net unit cost = 405 / 10');
select id as b1_item from purchase_invoice_items where purchase_invoice_id = :'b1_id' \gset
select create_purchase_return(:'org_id', :'b1_id', '2026-09-03',
  jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', :'b1_item', 'quantity', 10)), 0, null) as id \gset b1r_
select t.eq_text((select total::text from purchase_returns where id = :'b1r_id'), '468.00', '#2 full purchase return credits exactly the invoice total');
select t.eq_text((select balance::text from supplier_balances where supplier_id = :'s2'), '0.00', '#2 supplier balance is 0 after a full return');

-- ============================================================
-- #4 WAC after returning the expensive batch
--   100 @ 10 + 100 @ 20 → avg 15 ; return the 100 @ 20 batch → avg 10, value 1,000
-- ============================================================
select create_purchase_invoice(:'org_id', :'s3', :'w1', 'C-1', '2026-09-04',
  jsonb_build_array(jsonb_build_object('product_id', :'pc', 'quantity', 100, 'unit_cost', 10, 'discount', 0)), 0, 0, 0, null, null) as id \gset
select create_purchase_invoice(:'org_id', :'s3', :'w1', 'C-2', '2026-09-05',
  jsonb_build_array(jsonb_build_object('product_id', :'pc', 'quantity', 100, 'unit_cost', 20, 'discount', 0)), 0, 0, 0, null, null) as id \gset c2_
select id as c2_item from purchase_invoice_items where purchase_invoice_id = :'c2_id' \gset
select t.eq((select avg_cost from inventory_stock where product_id = :'pc'), 15, '#4 avg before the return = 15');
select create_purchase_return(:'org_id', :'c2_id', '2026-09-06',
  jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', :'c2_item', 'quantity', 100)), 0, null) as id \gset
select t.eq_text((select round(avg_cost, 4)::text from inventory_stock where product_id = :'pc'), '10.0000', '#4 avg cost goes back to 10 after returning the 20-batch');
select t.eq_text((select round(quantity * avg_cost, 2)::text from inventory_stock where product_id = :'pc'), '1000.00', '#4 inventory value = 100 × 10');

-- ============================================================
-- #5 precision: 1,000 @ 10.00 + 1,000 @ 10.01 → value 20,010.00 (was 20,020)
-- ============================================================
select create_purchase_invoice(:'org_id', :'s4', :'w1', 'D-1', '2026-09-07',
  jsonb_build_array(jsonb_build_object('product_id', :'pd', 'quantity', 1000, 'unit_cost', 10.00, 'discount', 0)), 0, 0, 0, null, null) as id \gset
select create_purchase_invoice(:'org_id', :'s4', :'w1', 'D-2', '2026-09-08',
  jsonb_build_array(jsonb_build_object('product_id', :'pd', 'quantity', 1000, 'unit_cost', 10.01, 'discount', 0)), 0, 0, 0, null, null) as id \gset
select t.eq_text((select round(quantity * avg_cost, 2)::text from inventory_stock where product_id = :'pd'), '20010.00', '#5 stock value equals the real spend 20,010.00');

-- ============================================================
-- Sales fixtures: PE bought 100 @ 30 (avg 30), PF bought 100 @ 30
-- ============================================================
insert into customers (organization_id, name) values (:'org_id', 'C1') returning id as c1 \gset
insert into customers (organization_id, name) values (:'org_id', 'C2') returning id as c2 \gset
insert into customers (organization_id, name) values (:'org_id', 'C3') returning id as c3 \gset
insert into customers (organization_id, name) values (:'org_id', 'C4') returning id as c4 \gset
insert into customers (organization_id, name) values (:'org_id', 'C5') returning id as c5 \gset
insert into customers (organization_id, name) values (:'org_id', 'C6') returning id as c6 \gset
select create_purchase_invoice(:'org_id', :'s1', :'w1', 'E-1', '2026-09-09',
  jsonb_build_array(jsonb_build_object('product_id', :'pe', 'quantity', 200, 'unit_cost', 30, 'discount', 0), jsonb_build_object('product_id', :'pf', 'quantity', 100, 'unit_cost', 30, 'discount', 0)), 0, 0, 0, null, null) as id \gset

-- ============================================================
-- #1 sales: 3 × 40 with line discount 20 → line 100, total 100, cogs 90, profit 10
-- ============================================================
select create_sales_invoice(:'org_id', :'c1', :'w1', 'SA-1', '2026-09-10',
  jsonb_build_array(jsonb_build_object('product_id', :'pe', 'quantity', 3, 'unit_price', 40, 'discount', 20)), 0, 0, 0, null, null, null) as id \gset sa1_
select t.eq_text((select subtotal::text from sales_invoices where id = :'sa1_id'), '120.00', '#1 sales subtotal is gross 120');
select t.eq_text((select discount_total::text from sales_invoices where id = :'sa1_id'), '20.00', '#1 sales discount_total includes the line discount');
select t.eq_text((select total::text from sales_invoices where id = :'sa1_id'), '100.00', '#1 sales total = 120 − 20 (was 120)');
select t.eq_text((select profit_total::text from sales_invoices where id = :'sa1_id'), '10.00', '#1 invoice profit = 100 − 90 (was 30)');
select t.eq_text((select sum(profit)::text from sales_invoice_items where sales_invoice_id = :'sa1_id'), '10.00', '#1 invoice profit equals the sum of line profits');

-- ============================================================
-- #2 sales: 10 × 100, invoice discount 100, tax 126 → total 1,026
--   full return → credit exactly 1,026, customer balance 0
--   (C2, nothing collected)
-- ============================================================
select create_sales_invoice(:'org_id', :'c2', :'w1', 'SB-1', '2026-09-11',
  jsonb_build_array(jsonb_build_object('product_id', :'pf', 'quantity', 10, 'unit_price', 100, 'discount', 0)), 100, 126, 0, null, null, null) as id \gset sb1_
select t.eq_text((select total::text from sales_invoices where id = :'sb1_id'), '1026.00', '#2 invoice total = 1,000 − 100 + 126');
select id as sb1_item from sales_invoice_items where sales_invoice_id = :'sb1_id' \gset
-- half back first: net 450, tax 63 → credit 513
select create_sales_return(:'org_id', :'sb1_id', '2026-09-12',
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'sb1_item', 'quantity', 5, 'condition', 'resalable')), 0, null) as id \gset sbr1_
select t.eq_text((select subtotal_reversed::text from sales_returns where id = :'sbr1_id'), '450.00', '#2 half return reverses 450 of net sales (discount prorated)');
select t.eq_text((select tax_reversed::text from sales_returns where id = :'sbr1_id'), '63.00', '#2 half return reverses 63 of tax');
select t.eq_text((select total::text from sales_returns where id = :'sbr1_id'), '513.00', '#2 half return credit = 513');
select t.eq_text((select balance::text from customer_balances where customer_id = :'c2'), '513.00', '#2 customer owes 1,026 − 513 = 513');
select create_sales_return(:'org_id', :'sb1_id', '2026-09-13',
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'sb1_item', 'quantity', 5, 'condition', 'resalable')), 0, null) as id \gset
select t.eq_text((select balance::text from customer_balances where customer_id = :'c2'), '0.00', '#2 customer balance is exactly 0 after a full return of a taxed, discounted invoice');
select t.eq_text((select coalesce(sum(cost_reversed), 0)::text from sales_returns where sales_invoice_id = :'sb1_id'), '300.00', '#2 returned cost = 10 × 30 exactly');

-- ============================================================
-- #10 rounding: 3 units of a 100.00 line returned one by one → 33.33 + 33.33 + 33.34
-- ============================================================
select create_sales_invoice(:'org_id', :'c3', :'w1', 'SC-1', '2026-09-14',
  jsonb_build_array(jsonb_build_object('product_id', :'pf', 'quantity', 3, 'unit_price', 100, 'discount', 0)), 0, 0, 0, null, null, null) as id \gset sc1_
select id as sc1_item from sales_invoice_items where sales_invoice_id = :'sc1_id' \gset
select create_sales_return(:'org_id', :'sc1_id', '2026-09-16', jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'sc1_item', 'quantity', 1, 'condition', 'resalable')), 0, null) as id \gset
select create_sales_return(:'org_id', :'sc1_id', '2026-09-17', jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'sc1_item', 'quantity', 1, 'condition', 'resalable')), 0, null) as id \gset
select create_sales_return(:'org_id', :'sc1_id', '2026-09-15', jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'sc1_item', 'quantity', 1, 'condition', 'resalable')), 0, null) as id \gset
select t.eq_text((select balance::text from customer_balances where customer_id = :'c3'), '0.00', '#10 no 0.01 residue after returning 3 of 3 units one at a time');

-- ============================================================
-- Cash refund moves the balance back
--   customer paid 1,000 in full, returns 5 of 10 (500) and gets 500 cash → balance 0
-- ============================================================
select create_sales_invoice(:'org_id', :'c4', :'w1', 'SD-1', '2026-09-16',
  jsonb_build_array(jsonb_build_object('product_id', :'pf', 'quantity', 10, 'unit_price', 100, 'discount', 0)), 0, 0, 1000, 'cash', null, null) as id \gset sd1_
select id as sd1_item from sales_invoice_items where sales_invoice_id = :'sd1_id' \gset
select create_sales_return(:'org_id', :'sd1_id', '2026-09-17', jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'sd1_item', 'quantity', 5, 'condition', 'resalable')), 500, null) as id \gset
select t.eq_text((select balance::text from customer_balances where customer_id = :'c4'), '0.00', '#refund 1,000 paid − 500 credited + 500 refunded in cash → balance 0 (was −500 forever)');

-- ============================================================
-- #8 commission
--   net_sales basis 10%: 10 × 100, discount 100, tax 126 → net 900 → 90
--   after 5 of 10 units returned (net 450) → (900 − 450) × 10% = 45
-- ============================================================
insert into sales_representatives (organization_id, name, commission_basis, commission_rate) values (:'org_id', 'R-net', 'net_sales', 10) returning id as rep1 \gset
insert into sales_representatives (organization_id, name, commission_basis, commission_rate) values (:'org_id', 'R-col', 'collected_amount', 10) returning id as rep2 \gset
select create_sales_invoice(:'org_id', :'c5', :'w1', 'SE-1', '2026-09-18',
  jsonb_build_array(jsonb_build_object('product_id', :'pe', 'quantity', 10, 'unit_price', 100, 'discount', 0)), 100, 126, 0, null, null, :'rep1') as id \gset se1_
select t.eq_text((select commission_amount::text from sales_invoices where id = :'se1_id'), '90.00', '#8 net-sales commission = 10% × 900');
select id as se1_item from sales_invoice_items where sales_invoice_id = :'se1_id' \gset
select create_sales_return(:'org_id', :'se1_id', '2026-09-19', jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'se1_item', 'quantity', 5, 'condition', 'resalable')), 0, null) as id \gset
select t.eq_text((select commission_amount::text from sales_invoices where id = :'se1_id'), '45.00', '#8 commission follows the return: 10% × (900 − 450)');

--   collected_amount basis 10%: 10 × 100 + tax 140 = 1,140, fully collected
--   commission is on the sales part of the cash only: 1,140 × (1,000 / 1,140) × 10% = 100 (was 114)
select create_sales_invoice(:'org_id', :'c6', :'w1', 'SF-1', '2026-09-20',
  jsonb_build_array(jsonb_build_object('product_id', :'pe', 'quantity', 10, 'unit_price', 100, 'discount', 0)), 0, 140, 1140, 'cash', null, :'rep2') as id \gset sf1_
select t.eq_text((select commission_amount::text from sales_invoices where id = :'sf1_id'), '100.00', '#8 collected-basis commission excludes the tax share');
select t.throws(format('select record_customer_collection(%L, %L, %L, 1, %L, null, null, null)', :'org_id', :'c6', :'sf1_id', '2026-09-21'),
  'المتبقي', '#7 a collection above what is left on the invoice is refused (commission cannot grow)');
select id as sf1_item from sales_invoice_items where sales_invoice_id = :'sf1_id' \gset
--   return 5 units and refund 513... here: net 500 + tax 70 = 570 refunded → cash kept 570 → 570 × (1,000/1,140) × 10% = 50
select create_sales_return(:'org_id', :'sf1_id', '2026-09-22', jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'sf1_item', 'quantity', 5, 'condition', 'resalable')), 570, null) as id \gset
select t.eq_text((select commission_amount::text from sales_invoices where id = :'sf1_id'), '50.00', '#8 commission shrinks with the cash refunded');

-- ============================================================
-- #6 / #7 server-side validation
-- ============================================================
select t.throws(format('select create_sales_invoice(%L, %L, %L, %L, %L, %L::jsonb, 0, 0, 0, null, null, null)', :'org_id', :'c1', :'w1', 'X-1', '2026-09-23',
  jsonb_build_array(jsonb_build_object('product_id', :'pe', 'quantity', 100000, 'unit_price', 10, 'discount', 0))::text),
  'الكمية المتاحة', '#6 cannot sell more than the stock on hand');
select t.ok((select min(quantity) from inventory_stock where organization_id = :'org_id') >= 0, '#6 no stock row is negative');
select t.throws(format('select create_sales_invoice(%L, %L, %L, %L, %L, %L::jsonb, 500, 0, 0, null, null, null)', :'org_id', :'c1', :'w1', 'X-2', '2026-09-23',
  jsonb_build_array(jsonb_build_object('product_id', :'pe', 'quantity', 1, 'unit_price', 100, 'discount', 0))::text),
  'الخصم أكبر', '#7 invoice discount larger than the invoice is refused');
select t.throws(format('select create_sales_invoice(%L, %L, %L, %L, %L, %L::jsonb, -5, 0, 0, null, null, null)', :'org_id', :'c1', :'w1', 'X-3', '2026-09-23',
  jsonb_build_array(jsonb_build_object('product_id', :'pe', 'quantity', 1, 'unit_price', 100, 'discount', 0))::text),
  'سالبًا', '#7 negative discount is refused');
select t.throws(format('select create_sales_invoice(%L, %L, %L, %L, %L, %L::jsonb, 0, -50, 0, null, null, null)', :'org_id', :'c1', :'w1', 'X-4', '2026-09-23',
  jsonb_build_array(jsonb_build_object('product_id', :'pe', 'quantity', 1, 'unit_price', 100, 'discount', 0))::text),
  'سالبة', '#7 negative tax is refused');
select t.throws(format('select create_sales_invoice(%L, %L, %L, %L, %L, %L::jsonb, 0, 0, 101, null, null, null)', :'org_id', :'c1', :'w1', 'X-5', '2026-09-23',
  jsonb_build_array(jsonb_build_object('product_id', :'pe', 'quantity', 1, 'unit_price', 100, 'discount', 0))::text),
  'أكبر من إجمالي', '#7 collecting more than the invoice total is refused');
select t.throws(format('select create_sales_invoice(%L, %L, %L, %L, %L, %L::jsonb, 0, 0, 0, null, null, null)', :'org_id', :'c1', :'w1', 'X-6', '2026-09-23',
  jsonb_build_array(jsonb_build_object('product_id', :'pe', 'quantity', 1, 'unit_price', 100, 'discount', 150))::text),
  'خصم الصنف', '#7 a line discount larger than the line is refused');
select t.throws(format('select create_purchase_invoice(%L, %L, %L, %L, %L, %L::jsonb, 0, 0, 0, null, null)', :'org_id', :'s1', :'w1', 'X-7', '2026-09-23',
  jsonb_build_array(jsonb_build_object('product_id', :'pe', 'quantity', 1, 'unit_cost', -1, 'discount', 0))::text),
  'سالبًا', '#7 negative purchase cost is refused');
select t.throws(format('select record_supplier_payment(%L, %L, %L, 901, %L, null, null, null)', :'org_id', :'s1', :'a1_id', '2026-09-24'),
  'المتبقي', '#7 paying a supplier invoice more than its remaining 900 is refused');
select record_supplier_payment(:'org_id', :'s1', :'a1_id', 900, '2026-09-24', null, null, null) as id \gset
select t.eq_text((select payment_status from purchase_invoices where id = :'a1_id'), 'paid', '#7 paying exactly the remaining amount settles the invoice');

-- ============================================================
-- #3 / #9 every report nets the same way
-- ============================================================
select t.eq_text((select (report_summary(:'org_id', '2026-09-01', '2026-09-30')->'sales'->>'net_sales')), (select sum(net_sales)::text from report_sales_breakdown(:'org_id', '2026-09-01', '2026-09-30', 'invoice')), '#9 summary net sales = breakdown net sales');
select t.eq_text((select (report_summary(:'org_id', '2026-09-01', '2026-09-30')->'sales'->>'net_sales')), (select sum(net_sales)::text from report_timeseries(:'org_id', '2026-09-01', '2026-09-30', 'day')), '#9 summary net sales = timeseries net sales (returns netted)');
select t.eq_text((select (report_summary(:'org_id', '2026-09-01', null)->'sales'->>'net_sales')), (select total_sales::text from dashboard_sales_totals(:'org_id', '2026-09-01')), '#3 dashboard sales = report net sales');
select t.eq_text((select (report_summary(:'org_id', '2026-09-01', null)->'financial'->>'net_profit')), (select total_profit::text from dashboard_sales_totals(:'org_id', '2026-09-01')), '#3 dashboard profit = report net profit');
select t.eq_text((select sum(gross_profit)::text from report_sales_breakdown(:'org_id', '2026-09-01', '2026-09-30', 'invoice')), (select (report_summary(:'org_id', '2026-09-01', '2026-09-30')->'financial'->>'gross_profit')), '#9 summary gross profit = breakdown gross profit');
select t.eq_text((select sum(net_sales)::text from report_sales_breakdown(:'org_id', '2026-09-01', '2026-09-30', 'product')), (select (report_summary(:'org_id', '2026-09-01', '2026-09-30')->'sales'->>'net_sales')), '#9 per-product net sales add up to the summary');

-- ============================================================
-- #5 transfers keep the 6-decimal average (PD avg 10.005)
-- ============================================================
select create_stock_transfer(:'org_id', :'w1', :'w2', '2026-09-25', jsonb_build_array(jsonb_build_object('product_id', :'pd', 'quantity', 100)), null) as id \gset
select t.eq_text((select round(avg_cost, 6)::text from inventory_stock where product_id = :'pd' and warehouse_id = :'w2'), '10.005000', '#5 destination warehouse inherits the exact average cost');

-- ============================================================
-- Balance sheet consistency: inventory value is quantity × avg_cost summed exactly
-- ============================================================
select t.eq_text((select round((report_summary(:'org_id')->'balances'->>'inventory_value')::numeric, 2)::text), (select round(sum(quantity * avg_cost), 2)::text from inventory_stock where organization_id = :'org_id'), 'inventory value in the summary = Σ qty × avg_cost');
