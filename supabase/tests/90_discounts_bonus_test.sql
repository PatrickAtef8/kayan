-- Percentage discounts, tiers (%), immediate-payment discount, MANUAL bonus,
-- net unit price, partial/full returns — worked by hand.
\set ON_ERROR_STOP on

select t.as_owner();
insert into auth.users (id, email) values ('90000000-0000-0000-0000-000000000001', 'owner@disc.test');
select t.as_user('90000000-0000-0000-0000-000000000001');
select create_organization('شركة الخصومات', 'تجارة', 'EG', 'EGP', 'ar',
  array['sales','customers','inventory','purchases','suppliers','expenses','treasury','representatives','partners']) as id \gset org_

insert into warehouses (organization_id, name) values (:'org_id', 'الرئيسي') returning id as wh \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as sup \gset
insert into customers (organization_id, name) values (:'org_id', 'عميل') returning id as cus \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'أ', 'A', 'قطعة') returning id as pa \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'ب', 'B', 'قطعة') returning id as pb \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'ج', 'C', 'قطعة') returning id as pc \gset
insert into product_prices (organization_id, product_id, cost, selling_price) values (:'org_id', :'pa', 0, 100), (:'org_id', :'pb', 0, 200), (:'org_id', :'pc', 0, 60);

-- stock: 200 A @ 50, 200 B @ 40, 100 C @ 30
select create_purchase_invoice(:'org_id', :'sup', :'wh', 'P-1', '2026-05-01', jsonb_build_array(
  jsonb_build_object('product_id', :'pa', 'quantity', 200, 'unit_cost', 50, 'discount_pct', 0),
  jsonb_build_object('product_id', :'pb', 'quantity', 200, 'unit_cost', 40, 'discount_pct', 0),
  jsonb_build_object('product_id', :'pc', 'quantity', 100, 'unit_cost', 30, 'discount_pct', 0)), 0, 0, 0, null, null) as id \gset p0_
select t.eq((select avg_cost from inventory_stock where product_id = :'pa'), 50, 'setup: A avg cost 50');

-- ------------------------------------------------------------
-- Old automatic bonus rules still sitting in the table must do NOTHING
-- ------------------------------------------------------------
insert into bonus_rules (organization_id, applies_to, product_id, min_quantity, bonus_product_id, bonus_quantity)
values (:'org_id', 'sales', :'pa', 12, :'pa', 1), (:'org_id', 'purchases', :'pa', 50, :'pa', 5);
select t.eq(jsonb_array_length(pricing_preview(:'org_id', 'sales', jsonb_build_array(
    jsonb_build_object('product_id', :'pa', 'quantity', 12, 'unit_price', 100, 'discount_pct', 0))) -> 'bonus'), 0,
  'nothing is added automatically: a matching bonus rule in the table is ignored');

-- ------------------------------------------------------------
-- 1. Manual bonus of the SAME product: 12 × 100 + 1 free A → 13 units, ≈ 92.31 each
-- ------------------------------------------------------------
select create_sales_invoice(:'org_id', :'cus', :'wh', 'S-1', '2026-05-10',
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 12, 'unit_price', 100, 'discount_pct', 0)),
  0, 0, 0, null, null, null, 0,
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 1))) as id \gset s1_
select t.eq((select bonus_quantity from sales_invoice_items where sales_invoice_id = :'s1_id'), 1, 'bonus: 1 free piece on the line');
select t.eq((select effective_unit_price from sales_invoice_items where sales_invoice_id = :'s1_id'), 92.3077, 'effective unit price = 1200/13');
select t.eq((select total from sales_invoices where id = :'s1_id'), 1200, 'bonus is not money: invoice total stays 1,200');
select t.eq((select quantity from inventory_stock where product_id = :'pa'), 187, 'stock moved by 13 (200 − 13)');
select t.eq((select cogs_total from v_sales_invoices where id = :'s1_id'), 650, 'COGS includes the free unit: 13 × 50');
select t.eq((select profit_total from v_sales_invoices where id = :'s1_id'), 550, 'profit = 1200 − 650');
select t.eq((select bonus_units from sales_invoices where id = :'s1_id'), 1, 'invoice records bonus units');

-- partial return of ONE piece → ~92.31, not 100
select create_sales_return(:'org_id', :'s1_id', '2026-05-11',
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'s1_id'), 'quantity', 1, 'condition', 'resalable')), 0, null) as id \gset r1_
select t.eq((select total from sales_returns where id = :'r1_id'), 92.31, 'partial return valued at the net price 92.31');
select t.eq((select quantity from inventory_stock where product_id = :'pa'), 188, 'returned piece back in stock');
select t.eq((select cost_reversed from v_sales_returns where id = :'r1_id'), 50, 'COGS reversed at historical cost');
select t.eq((select returnable from get_returnable_items(:'org_id', :'s1_id')), 12, 'returnable counts bonus units: 13 − 1');
select create_sales_return(:'org_id', :'s1_id', '2026-05-12', null, 0, null, true, 'resalable') as id \gset r2_
select t.eq((select sum(total) from sales_returns where sales_invoice_id = :'s1_id'), 1200, 'partial + full return add up to exactly the invoice net 1,200');
select t.eq((select sum(profit_reversed) from v_sales_returns where sales_invoice_id = :'s1_id'), 550, 'profit fully reversed');
select t.eq((select quantity from inventory_stock where product_id = :'pa'), 200, 'stock fully restored');
select t.eq((select balance from customer_balances where customer_id = :'cus'), 0, 'customer debt back to zero');
select t.throws(format('select create_sales_return(%L, %L, null, null, 0, null, true, ''resalable'')', :'org_id', :'s1_id'), 'لا توجد كميات متبقية', 'nothing left to return');

-- ------------------------------------------------------------
-- 2. Percent discounts + tier (%) + manual bonus of ANOTHER product
--    A 10 × 100 + B 5 × 200 = 2,000 ; invoice 2 % = 40 ; tier 7.5 % = 150
--    (tiers: 1,000 → 5 %, 2,000 → 7.5 %: the higher one wins, no stacking)
--    immediate-payment 0.5 % entered but NOTHING paid now → not applied
--    bonus: 1 × C (not on the invoice) → its own zero-value line
-- ------------------------------------------------------------
insert into discount_tiers (organization_id, applies_to, min_amount, discount_pct)
values (:'org_id', 'sales', 1000, 5), (:'org_id', 'sales', 2000, 7.5);
select create_sales_invoice(:'org_id', :'cus', :'wh', 'S-2', '2026-05-15',
  jsonb_build_array(
    jsonb_build_object('product_id', :'pa', 'quantity', 10, 'unit_price', 100, 'discount_pct', 0),
    jsonb_build_object('product_id', :'pb', 'quantity', 5,  'unit_price', 200, 'discount_pct', 0)),
  2, 0, 0, 'Visa', null, null, 0.5,
  jsonb_build_array(jsonb_build_object('product_id', :'pc', 'quantity', 1))) as id \gset s2_
select t.eq((select tier_discount from sales_invoices where id = :'s2_id'), 150, 'tier: 2,000 reached → 7.5 % = 150 (higher tier wins, no stacking)');
select t.eq((select tier_discount_pct from sales_invoices where id = :'s2_id'), 7.5, 'the tier percentage is recorded');
select t.eq((select invoice_discount from sales_invoices where id = :'s2_id'), 40, 'invoice discount 2 % of 2,000 = 40');
select t.eq((select cash_discount from sales_invoices where id = :'s2_id'), 0, 'immediate-payment discount NOT applied when nothing is paid now');
select t.eq((select discount_total from sales_invoices where id = :'s2_id'), 190, 'discount_total = 40 invoice + 150 tier');
select t.eq((select total from sales_invoices where id = :'s2_id'), 1810, 'total = 2,000 − 190');
select t.eq((select sum(net_total) from sales_invoice_items where sales_invoice_id = :'s2_id' and not is_bonus), 1810, 'item net totals sum to the invoice net');
select t.eq((select count(*) from sales_invoice_items where sales_invoice_id = :'s2_id' and is_bonus), 1, 'bonus of a product that is not on the invoice is its own line');
select t.eq((select quantity from sales_invoice_items where sales_invoice_id = :'s2_id' and is_bonus), 1, 'bonus line: 1 × C');
select t.eq((select effective_unit_price from sales_invoice_items where sales_invoice_id = :'s2_id' and is_bonus), 0, 'bonus line is worth 0');
select t.eq((select quantity from inventory_stock where product_id = :'pa'), 190, 'stock A: 200 − 10 sold');
select t.eq((select quantity from inventory_stock where product_id = :'pc'), 99, 'stock C: 100 − 1 bonus');
select t.eq((select cogs_total from v_sales_invoices where id = :'s2_id'), 10*50 + 5*40 + 1*30, 'COGS = 500 + 200 + bonus 30');
select t.eq((select profit_total from v_sales_invoices where id = :'s2_id'), 1810 - 730, 'profit = net 1,810 − COGS 730');

-- the same engine through the UI preview RPC (inv %, immediate %, paid now, tax, bonus)
select t.eq((pricing_preview(:'org_id', 'sales', jsonb_build_array(
    jsonb_build_object('product_id', :'pa', 'quantity', 10, 'unit_price', 100, 'discount_pct', 0),
    jsonb_build_object('product_id', :'pb', 'quantity', 5,  'unit_price', 200, 'discount_pct', 0)),
  2, 0.5, 0, 0) ->> 'total')::numeric, 1810, 'preview matches what was posted');
select t.eq((pricing_preview(:'org_id', 'sales', jsonb_build_array(
    jsonb_build_object('product_id', :'pa', 'quantity', 10, 'unit_price', 100, 'discount_pct', 0),
    jsonb_build_object('product_id', :'pb', 'quantity', 5,  'unit_price', 200, 'discount_pct', 0)),
  2, 0.5, 500, 0) ->> 'cash_discount')::numeric, 10, 'preview: paying something now applies the immediate-payment discount (0.5 % = 10)');
select t.eq((pricing_preview(:'org_id', 'sales', jsonb_build_array(
    jsonb_build_object('product_id', :'pa', 'quantity', 10, 'unit_price', 100, 'discount_pct', 0)),
  0, 10, 0, 0) ->> 'cash_discount')::numeric, 0, 'preview: nothing paid now → no immediate-payment discount');

-- partial return of 5 × A from S-2 uses the allocated net price (905/10 = 90.5)
select create_sales_return(:'org_id', :'s2_id', '2026-05-16',
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'s2_id' and product_id = :'pa' and not is_bonus), 'quantity', 5, 'condition', 'resalable')), 0, null) as id \gset r3_
select t.eq((select total from sales_returns where id = :'r3_id'), 452.5, 'partial return of 5 × A at net 90.50 (not 100)');
-- full return of the rest, then everything nets to zero
select create_sales_return(:'org_id', :'s2_id', '2026-05-17', null, 0, null, true, 'resalable') as id \gset r4_
select t.eq((select sum(total) from sales_returns where sales_invoice_id = :'s2_id'), 1810, 'returns sum to the invoice net 1,810');
select t.eq((select sum(profit_reversed) from v_sales_returns where sales_invoice_id = :'s2_id'), 1080, 'profit fully reversed (1,080)');
select t.eq((select quantity from inventory_stock where product_id = :'pa'), 200, 'A back to 200');
select t.eq((select quantity from inventory_stock where product_id = :'pb'), 200, 'B back to 200');
select t.eq((select quantity from inventory_stock where product_id = :'pc'), 100, 'C (the bonus) back to 100');

-- ------------------------------------------------------------
-- 3. Immediate-payment discount: depends on PAYING NOW, never on the method
--    2 × 200 = 400 ; 2.5 % = 10 ; paid 390 by Visa
-- ------------------------------------------------------------
select create_sales_invoice(:'org_id', :'cus', :'wh', 'S-3', '2026-05-18',
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 2, 'unit_price', 200, 'discount_pct', 0)),
  0, 0, 390, 'Visa', null, null, 2.5) as id \gset s3_
select t.eq((select cash_discount from sales_invoices where id = :'s3_id'), 10, 'immediate-payment discount applied for a Visa payment made now');
select t.eq((select cash_discount_pct from sales_invoices where id = :'s3_id'), 2.5, 'its percentage is recorded');
select t.eq((select total from sales_invoices where id = :'s3_id'), 390, 'total = 400 − 10');
select t.eq((select payment_status = 'paid' from sales_invoices where id = :'s3_id')::int, 1, 'paid in full');

-- a percentage line discount: 4 × 50 = 200, 10 % = 20 → line 180
select create_sales_invoice(:'org_id', :'cus', :'wh', 'S-4', '2026-05-19',
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 4, 'unit_price', 50, 'discount_pct', 10)),
  0, 0, 0, null, null) as id \gset s4_
select t.eq((select discount from sales_invoice_items where sales_invoice_id = :'s4_id'), 20, 'line discount 10 % of 200 = 20');
select t.eq((select discount_pct from sales_invoice_items where sales_invoice_id = :'s4_id'), 10, 'the line percentage is recorded');
select t.eq((select line_total from sales_invoice_items where sales_invoice_id = :'s4_id'), 180, 'line total = 200 − 20');
select t.eq((select total from sales_invoices where id = :'s4_id'), 180, 'invoice total = 180');

-- guards
select t.throws(format('select create_sales_invoice(%L, %L, %L, null, null, %L::jsonb, 150, 0, 0, null, null, null, 0)', :'org_id', :'cus', :'wh',
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 1, 'unit_price', 200, 'discount_pct', 0))::text), 'بين 0 و 100', 'a discount above 100 % is refused');
select t.throws(format('select create_sales_invoice(%L, %L, %L, null, null, %L::jsonb, 60, 0, 10, null, null, null, 50)', :'org_id', :'cus', :'wh',
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 1, 'unit_price', 200, 'discount_pct', 0))::text), 'أكبر من 100', 'invoice % + immediate % above 100 % is refused');
select t.throws(format('select create_sales_invoice(%L, %L, %L, null, null, %L::jsonb, 0, 0, 0, null, null, null, 0)', :'org_id', :'cus', :'wh',
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 1, 'unit_price', 200, 'discount', 5))::text), 'نسبة مئوية', 'an old EGP-style line discount is refused, never silently reinterpreted');
select t.throws(format('select create_sales_invoice(%L, %L, %L, null, null, %L::jsonb, 0, 0, 0, null, null, null, 0, %L::jsonb)', :'org_id', :'cus', :'wh',
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 1, 'unit_price', 200, 'discount_pct', 0))::text,
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 0))::text), 'كمية الـBonus', 'a bonus quantity must be above zero');
select t.throws(format('select create_sales_invoice(%L, %L, %L, null, null, %L::jsonb, 0, 0, 0, null, null, null, 0, %L::jsonb)', :'org_id', :'cus', :'wh',
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 1, 'unit_price', 200, 'discount_pct', 0))::text,
  jsonb_build_array(jsonb_build_object('product_id', :'pc', 'quantity', 100000))::text), 'الكمية المتاحة', 'a bonus cannot oversell the stock');

-- ------------------------------------------------------------
-- 4. Purchases: same engine; manual bonus lowers the unit cost; returns at net cost
-- ------------------------------------------------------------
select create_purchase_invoice(:'org_id', :'sup', :'wh', 'P-2', '2026-05-20',
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 100, 'unit_cost', 10, 'discount_pct', 0)),
  0, 0, 0, null, null, 0,
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 10))) as id \gset p2_
select t.eq((select bonus_quantity from purchase_invoice_items where purchase_invoice_id = :'p2_id'), 10, 'purchase bonus: 10 free pieces entered by hand');
select t.eq((select effective_unit_cost from purchase_invoice_items where purchase_invoice_id = :'p2_id'), 9.0909, 'effective cost = 1000/110');
select t.eq((select quantity from inventory_stock where product_id = :'pa'), 310, 'stock +110');
select t.eq((select balance from supplier_balances where supplier_id = :'sup'), 1000 + 200*50 + 200*40 + 100*30, 'supplier owed = purchases (bonus is free)');
select create_purchase_return(:'org_id', :'p2_id', '2026-05-21', null, 0, null, true) as id \gset pr_
select t.eq((select total from purchase_returns where id = :'pr_id'), 1000, 'full purchase return = exactly the net 1,000');
select t.eq((select quantity from inventory_stock where product_id = :'pa'), 200, 'stock back to 200');

-- purchase: immediate-payment discount 5 % when paying now, whatever the method
--   50 × 20 = 1,000 ; 5 % = 50 ; paid 950 by bank transfer
select create_purchase_invoice(:'org_id', :'sup', :'wh', 'P-3', '2026-05-22',
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 50, 'unit_cost', 20, 'discount_pct', 0)),
  0, 0, 950, 'تحويل بنكي', null, 5) as id \gset p3_
select t.eq((select cash_discount from purchase_invoices where id = :'p3_id'), 50, 'purchase immediate-payment discount 5 % = 50');
select t.eq((select total from purchase_invoices where id = :'p3_id'), 950, 'purchase total = 1,000 − 50');
select t.eq_text((select payment_status from purchase_invoices where id = :'p3_id'), 'paid', 'purchase paid in full');
