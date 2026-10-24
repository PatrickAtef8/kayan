-- Reports package, Phase 4: sales channel + report_sales_by.
\set ON_ERROR_STOP on
select t.as_owner();
insert into auth.users (id, email) values
  ('9a000000-0000-0000-0000-000000000001', 'owner@sr98.test'),
  ('9a000000-0000-0000-0000-000000000002', 'other@sr98.test'),
  ('9a000000-0000-0000-0000-000000000003', 'rep1@sr98.test'),
  ('9a000000-0000-0000-0000-000000000004', 'rep2@sr98.test');
select t.as_user('9a000000-0000-0000-0000-000000000001');
select create_organization('شركة المبيعات', 'تجارة', 'EG', 'EGP', 'ar',
  array['sales','customers','inventory','purchases','suppliers','expenses','treasury','representatives']) as id \gset org_
select t.as_user('9a000000-0000-0000-0000-000000000002');
select create_organization('شركة أخرى', 'تجارة', 'EG', 'EGP', 'ar', array['sales','inventory']) as id \gset orgb_
select t.as_owner();
-- two restricted reps (sales role + a linked rep record), each owning one customer
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', u, r.id, 'active' from roles r, (values ('9a000000-0000-0000-0000-000000000003'::uuid), ('9a000000-0000-0000-0000-000000000004'::uuid)) v(u)
where r.key = 'sales' and r.organization_id is null;

select t.as_user('9a000000-0000-0000-0000-000000000001');
insert into warehouses (organization_id, name) values (:'org_id', 'الرئيسي') returning id as w1 \gset
insert into warehouses (organization_id, name) values (:'org_id', 'الفرعي') returning id as w2 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as sup \gset
insert into sales_representatives (organization_id, name, user_id) values (:'org_id', 'مندوب 1', '9a000000-0000-0000-0000-000000000003') returning id as rep1 \gset
insert into sales_representatives (organization_id, name, user_id) values (:'org_id', 'مندوب 2', '9a000000-0000-0000-0000-000000000004') returning id as rep2 \gset
insert into customers (organization_id, name, price_tier, sales_rep_id) values (:'org_id', 'عميل تجزئة', 'retail', :'rep1') returning id as c_retail \gset
insert into customers (organization_id, name, price_tier, sales_rep_id) values (:'org_id', 'عميل جملة', 'wholesale', :'rep1') returning id as c_whole \gset
insert into customers (organization_id, name, price_tier, sales_rep_id) values (:'org_id', 'عميل موزع', 'distributor', :'rep2') returning id as c_dist \gset
-- X: 12 per carton, Y: 6 per carton, Z: no carton size
insert into products (organization_id, name, sku, unit, units_per_carton) values (:'org_id', 'X', 'X', 'قطعة', 12) returning id as px \gset
insert into products (organization_id, name, sku, unit, units_per_carton) values (:'org_id', 'Y', 'Y', 'قطعة', 6) returning id as py \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'Z', 'Z', 'قطعة') returning id as pz \gset
insert into product_prices (organization_id, product_id, selling_price) select :'org_id', id, 100 from products where organization_id = :'org_id';
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'SR-P1', current_date,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 1000, 'unit_cost', 5, 'discount_pct', 0),
                    jsonb_build_object('product_id', :'py', 'quantity', 1000, 'unit_cost', 5, 'discount_pct', 0),
                    jsonb_build_object('product_id', :'pz', 'quantity', 1000, 'unit_cost', 5, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset p1_
select create_purchase_invoice(:'org_id', :'sup', :'w2', 'SR-P2', current_date,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 1000, 'unit_cost', 5, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset p2_

-- =====================================================================
-- 1. Sales channel on the invoice
-- =====================================================================
-- S1: retail customer, no channel given → derived 'retail'. X 30 (2.5 cartons) + Z 10, invoice discount 10%
select create_sales_invoice(:'org_id', :'c_retail', :'w1', 'SR-S1', current_date,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 30, 'unit_price', 100, 'discount_pct', 0),
                    jsonb_build_object('product_id', :'pz', 'quantity', 10, 'unit_price', 50, 'discount_pct', 0)), 10, 0, 0, null, null, null, 0) as id \gset s1_
select t.eq_text((select sales_channel from sales_invoices where id = :'s1_id'), 'retail', 'channel: derived from a retail customer');
-- S2: distributor customer, no channel → 'wholesale'. X 24 (2 cartons), Y 12 (2 cartons) with a 5% line discount on Y, 1 bonus unit of Y on the Y line is via bonus_items
select create_sales_invoice(:'org_id', :'c_dist', :'w1', 'SR-S2', current_date,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 24, 'unit_price', 100, 'discount_pct', 0),
                    jsonb_build_object('product_id', :'py', 'quantity', 12, 'unit_price', 80, 'discount_pct', 5)), 0, 0, 0, null, null, null, 0) as id \gset s2_
select t.eq_text((select sales_channel from sales_invoices where id = :'s2_id'), 'wholesale', 'channel: a distributor is wholesale');
-- S3: retail customer but explicitly SOCIAL; second warehouse. X 12 (1 carton)
select create_sales_invoice(:'org_id', :'c_retail', :'w2', 'SR-S3', current_date,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 12, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0, '[]'::jsonb, 'social') as id \gset s3_
select t.eq_text((select sales_channel from sales_invoices where id = :'s3_id'), 'social', 'channel: an explicit choice wins over the customer tier');
-- S4: wholesale customer, with free goods: X 20 paid + 4 free X (bonus_items) , Y 6
select create_sales_invoice(:'org_id', :'c_whole', :'w1', 'SR-S4', current_date,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 20, 'unit_price', 100, 'discount_pct', 0),
                    jsonb_build_object('product_id', :'py', 'quantity', 6, 'unit_price', 80, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0,
  jsonb_build_array(jsonb_build_object('product_id', :'pz', 'quantity', 4))) as id \gset s4_
select t.eq_text((select sales_channel from sales_invoices where id = :'s4_id'), 'wholesale', 'channel: wholesale customer → wholesale');
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'SR-BAD', current_date, jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 1, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0, '[]'::jsonb, 'tiktok')$q$, :'org_id', :'c_retail', :'w1', :'px'), 'قناة البيع غير صحيحة', 'an unknown channel is refused');
select t.eq((select count(*) from sales_invoices where invoice_number = 'SR-BAD'), 0, 'and no invoice is left behind');
select t.throws(format($q$update sales_invoices set sales_channel = 'x' where id = %L$q$, :'s1_id'), 'permission denied', 'channel cannot be edited directly');
-- the old 14-argument call (existing callers) still works and behaves as before
select create_sales_invoice(:'org_id', :'c_retail', :'w1', 'SR-OLD', current_date,
  jsonb_build_array(jsonb_build_object('product_id', :'pz', 'quantity', 1, 'unit_price', 50, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0, '[]'::jsonb) as id \gset sold_
select t.eq_text((select sales_channel from sales_invoices where id = :'sold_id'), 'retail', 'existing callers (no channel argument) are unaffected');

-- a "legacy" invoice: channel NULL, as every invoice created before this migration
select t.as_owner();
update sales_invoices set sales_channel = null where id = :'sold_id';
select t.as_user('9a000000-0000-0000-0000-000000000001');
select t.eq((select count(*) from report_sales_by(:'org_id', 'channel', current_date, current_date) where group_id = 'retail' and invoices = 2), 1, 'legacy (NULL channel) invoice falls back to the customer tier: retail has S1 + the legacy one');
select t.as_owner();
update sales_invoices set sales_channel = 'retail' where id = :'sold_id';   -- restore the label for the exact figures below
select t.as_user('9a000000-0000-0000-0000-000000000001');

-- =====================================================================
-- 2. Reconciliation with the EXISTING sales report (no double counting)
-- =====================================================================
-- before any return: our totals must equal report_sales_breakdown's totals
select t.eq(
  (select sum(net_revenue) from report_sales_by(:'org_id', 'rep')),
  (select sum(net_sales) from report_sales_breakdown(:'org_id', null, null, 'representative', 1000, 0)),
  'rep report net revenue = existing report (by rep)');
select t.eq(
  (select sum(net_revenue) from report_sales_by(:'org_id', 'product')),
  (select sum(net_sales) from report_sales_breakdown(:'org_id', null, null, 'product', 1000, 0)),
  'product report net revenue = existing report (by product)');
select t.eq(
  (select sum(net_revenue) from report_sales_by(:'org_id', 'channel')),
  (select sum(net_revenue) from report_sales_by(:'org_id', 'rep')),
  'channel total = rep total (every invoice is in exactly one channel and one rep bucket)');
select t.eq(
  (select sum(net_revenue) from report_sales_by(:'org_id', 'customer')),
  (select sum(net_revenue) from report_sales_by(:'org_id', 'product')),
  'customer total = product total');
select t.eq(
  (select sum(net_revenue) from report_sales_by(:'org_id', 'product')),
  (select sum(subtotal - discount_total) from sales_invoices where organization_id = :'org_id'),
  'item-level revenue = invoice headers (subtotal − discounts): nothing lost or doubled by the item join');
select t.eq((select sum(gross_sales - discounts - returns_value - net_revenue) from report_sales_by(:'org_id', 'product')), 0, 'identity: gross − discounts − returns = net revenue');
select t.eq((select sum(invoices) from report_sales_by(:'org_id', 'channel')), (select count(*) from sales_invoices where organization_id = :'org_id'), 'every invoice is counted exactly once across channels');

-- =====================================================================
-- 3. Sales by product, cartons, bonus
-- =====================================================================
-- X: billed 30 + 24 + 12 + 20 = 86, free 0;  Z: billed 10 + 1 = 11 (+ 4 free from S4);  Y: 12 + 6 = 18
select t.eq((select billed_qty from report_sales_by(:'org_id', 'product') where group_label = 'X'), 86, 'X billed units');
select t.eq((select net_qty from report_sales_by(:'org_id', 'product') where group_label = 'X'), 86, 'X net units');
select t.eq((select units_per_carton from report_sales_by(:'org_id', 'product') where group_label = 'X'), 12, 'X carton size is returned');
select t.eq((select whole_cartons from report_sales_by(:'org_id', 'product') where group_label = 'X'), 7, 'X: 86 units = 7 whole cartons…');
select t.eq((select remainder_units from report_sales_by(:'org_id', 'product') where group_label = 'X'), 2, '…and 2 loose units (7 × 12 + 2)');
select t.eq((select round(cartons, 4) from report_sales_by(:'org_id', 'product') where group_label = 'X'), round(86 / 12.0, 4), 'X cartons (decimal) = 86 ÷ 12');
select t.eq((select whole_cartons from report_sales_by(:'org_id', 'product') where group_label = 'Y'), 3, 'Y: 18 units ÷ 6 = 3 cartons');
select t.eq((select remainder_units from report_sales_by(:'org_id', 'product') where group_label = 'Y'), 0, 'Y: no remainder');
select t.ok((select whole_cartons from report_sales_by(:'org_id', 'product') where group_label = 'Z') is null, 'Z has no carton size → no carton figure');
select t.eq((select cartons from report_sales_by(:'org_id', 'product') where group_label = 'Z'), 0, 'Z contributes 0 cartons');
select t.eq((select loose_units from report_sales_by(:'org_id', 'product') where group_label = 'Z'), 15, 'Z: all 15 units (11 billed + 4 free) are loose units');
select t.eq((select bonus_qty from report_sales_by(:'org_id', 'product') where group_label = 'Z'), 4, 'free units (bonus line) are reported separately');
select t.eq((select billed_qty from report_sales_by(:'org_id', 'product') where group_label = 'Z'), 11, 'and are NOT in billed units');
-- product revenue: X: 3000 + 2400 + 1200 + 2000 = 8600 minus the 10% invoice discount on S1 (30 × 100 × 10% = 300) → check against the existing report
select t.eq((select net_revenue from report_sales_by(:'org_id', 'product') where group_label = 'X'), (select net_sales from report_sales_breakdown(:'org_id', null, null, 'product', 1000, 0) where group_label = 'X'), 'X revenue = existing report');
select t.ok((select net_revenue from report_sales_by(:'org_id', 'product') where group_label = 'X') < 8600, 'X revenue is below list price (S1 had a 10% invoice discount)');
select t.eq((select products from report_sales_by(:'org_id', 'product') where group_label = 'X'), 1, 'a product row counts itself once');
select t.eq((select customers from report_sales_by(:'org_id', 'product') where group_label = 'X'), 3, 'X: 3 distinct customers (the retail customer bought it on two invoices and counts once)');
select t.eq((select invoices from report_sales_by(:'org_id', 'product') where group_label = 'X'), 4, 'X appears on 4 invoices');

-- =====================================================================
-- 4. Returns are netted once (resalable AND damaged), against the original invoice
-- =====================================================================
-- return 6 of X from S1 (resalable) and 3 of X from S1 (damaged)
select create_sales_return(:'org_id', :'s1_id', current_date,
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'s1_id' and product_id = :'px'), 'quantity', 6, 'condition', 'resalable')), 0, null) as id \gset r1_
select pg_sleep(5.5);   -- duplicate-submission guard (0010)
select create_sales_return(:'org_id', :'s1_id', current_date,
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'s1_id' and product_id = :'px'), 'quantity', 3, 'condition', 'damaged')), 0, null) as id \gset r2_
select t.eq((select returned_qty from report_sales_by(:'org_id', 'product') where group_label = 'X'), 9, 'returns: 6 resalable + 3 damaged = 9 returned units');
select t.eq((select net_qty from report_sales_by(:'org_id', 'product') where group_label = 'X'), 77, 'net units = 86 − 9');
select t.eq((select whole_cartons from report_sales_by(:'org_id', 'product') where group_label = 'X'), 6, 'cartons follow the NET units: 77 = 6 cartons…');
select t.eq((select remainder_units from report_sales_by(:'org_id', 'product') where group_label = 'X'), 5, '…+ 5 units');
select t.eq((select returns_value from report_sales_by(:'org_id', 'product') where group_label = 'X'), (select returns_value from report_sales_by(:'org_id', 'rep') where group_id = :'rep1' and returns_value > 0), 'the same return value shows under the rep that owns the invoice');
select t.eq(
  (select sum(net_revenue) from report_sales_by(:'org_id', 'rep')),
  (select sum(net_sales) from report_sales_breakdown(:'org_id', null, null, 'representative', 1000, 0)),
  'after returns: rep report still = existing report');
select t.eq(
  (select sum(net_revenue) from report_sales_by(:'org_id', 'product')),
  (select sum(net_sales) from report_sales_breakdown(:'org_id', null, null, 'product', 1000, 0)),
  'after returns: product report still = existing report');
select t.eq((select sum(net_revenue) from report_sales_by(:'org_id', 'channel')), (select sum(net_revenue) from report_sales_by(:'org_id', 'customer')), 'after returns: channel total = customer total');
select t.eq((select sum(gross_sales - discounts - returns_value - net_revenue) from report_sales_by(:'org_id', 'product')), 0, 'after returns: identity gross − discounts − returns = net still holds');
select t.eq((select sum(returns_value) from report_sales_by(:'org_id', 'product')), (select sum(subtotal_reversed) from sales_returns where organization_id = :'org_id'), 'total returns value = the sum of the return documents (each return counted once)');
-- a return moves the INVOICE's figures, not today's: a window that excludes the invoice date shows nothing
select t.eq((select count(*) from report_sales_by(:'org_id', 'product', current_date + 1, current_date + 5)), 0, 'a future window shows no sales and no returns');
select t.eq((select count(*) from report_sales_by(:'org_id', 'product', current_date - 5, current_date - 1)), 0, 'a past window shows none either');
select t.eq((select returned_qty from report_sales_by(:'org_id', 'product', current_date, current_date) where group_label = 'X'), 9, 'the invoice day carries the returns');

-- =====================================================================
-- 5. Sales by rep
-- =====================================================================
-- rep1 owns S1 (retail customer), S3 (retail customer, social), S4 (wholesale customer) and SR-OLD; rep2 owns S2
select t.eq((select invoices from report_sales_by(:'org_id', 'rep') where group_id = :'rep1'), 4, 'rep 1: four invoices');
select t.eq((select invoices from report_sales_by(:'org_id', 'rep') where group_id = :'rep2'), 1, 'rep 2: one invoice');
select t.eq((select customers from report_sales_by(:'org_id', 'rep') where group_id = :'rep1'), 2, 'rep 1: two distinct customers (the retail one bought three times)');
select t.eq((select customers from report_sales_by(:'org_id', 'rep') where group_id = :'rep2'), 1, 'rep 2: one customer');
select t.eq((select products from report_sales_by(:'org_id', 'rep') where group_id = :'rep1'), 3, 'rep 1: three distinct products');
select t.eq((select products from report_sales_by(:'org_id', 'rep') where group_id = :'rep2'), 2, 'rep 2: two distinct products');
-- rep 2: X 24 (2 cartons) + Y 12 (2 cartons) = 4 cartons, 36 units, no loose units
select t.eq((select cartons from report_sales_by(:'org_id', 'rep') where group_id = :'rep2'), 4, 'rep 2: 2 + 2 = 4 cartons');
select t.eq((select net_qty from report_sales_by(:'org_id', 'rep') where group_id = :'rep2'), 36, 'rep 2: 36 individual units');
select t.eq((select loose_units from report_sales_by(:'org_id', 'rep') where group_id = :'rep2'), 0, 'rep 2: nothing outside a carton configuration');
-- rep 1: X (30−9 + 12 + 20 = 53 → 53/12) + Y 6 (1 carton) ; Z 10 + 1 + 4 free = 15 loose
select t.eq((select round(cartons, 4) from report_sales_by(:'org_id', 'rep') where group_id = :'rep1'), round(53 / 12.0 + 1, 4), 'rep 1: X 53 ÷ 12 + Y 6 ÷ 6 cartons');
select t.eq((select loose_units from report_sales_by(:'org_id', 'rep') where group_id = :'rep1'), 15, 'rep 1: Z units are loose (no carton size)');
select t.eq((select net_qty from report_sales_by(:'org_id', 'rep') where group_id = :'rep1'), 53 + 6 + 15, 'rep 1: individual units = 53 + 6 + 15');
select t.eq_text((select group_label from report_sales_by(:'org_id', 'rep') where group_id = :'rep2'), 'مندوب 2', 'the rep name is the label');
select t.eq((select count(*) from report_sales_by(:'org_id', 'rep')), 2, 'only reps with sales appear');
-- invoices with no rep are grouped, not dropped
select t.as_owner();
insert into customers (organization_id, name, price_tier) values (:'org_id', 'بدون مندوب', 'retail') returning id as c_norep \gset
select t.as_user('9a000000-0000-0000-0000-000000000001');
select create_sales_invoice(:'org_id', :'c_norep', :'w1', 'SR-S5', current_date,
  jsonb_build_array(jsonb_build_object('product_id', :'pz', 'quantity', 2, 'unit_price', 50, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset s5_
select t.eq((select invoices from report_sales_by(:'org_id', 'rep') where group_id = 'none'), 1, 'an invoice with no rep appears under "بدون مندوب"');
select t.eq_text((select group_label from report_sales_by(:'org_id', 'rep') where group_id = 'none'), 'بدون مندوب', 'with its own label');

-- =====================================================================
-- 6. Sales by channel
-- =====================================================================
select t.eq((select count(*) from report_sales_by(:'org_id', 'channel')), 3, 'channel report always lists wholesale, retail and social');
select t.eq((select count(*) from report_sales_by(:'org_id', 'channel', current_date + 1, current_date + 2)), 3, 'even for a period with no sales (zeros, not missing rows)');
select t.eq((select net_revenue from report_sales_by(:'org_id', 'channel', current_date + 1, current_date + 2) where group_id = 'social'), 0, 'a quiet channel shows zero');
select t.eq((select invoices from report_sales_by(:'org_id', 'channel') where group_id = 'social'), 1, 'social: S3 only');
select t.eq((select net_qty from report_sales_by(:'org_id', 'channel') where group_id = 'social'), 12, 'social: 12 units');
select t.eq((select cartons from report_sales_by(:'org_id', 'channel') where group_id = 'social'), 1, 'social: 1 carton');
select t.eq((select invoices from report_sales_by(:'org_id', 'channel') where group_id = 'wholesale'), 2, 'wholesale: S2 (distributor) + S4');
select t.eq((select invoices from report_sales_by(:'org_id', 'channel') where group_id = 'retail'), 3, 'retail: S1 + SR-OLD + S5');
select t.eq_text((select group_label from report_sales_by(:'org_id', 'channel') where group_id = 'wholesale'), 'جملة', 'channel labels are Arabic (جملة)');
select t.eq_text((select group_label from report_sales_by(:'org_id', 'channel') where group_id = 'social'), 'سوشيال ميديا', 'channel labels are Arabic (سوشيال ميديا)');
select t.eq((select count(*) from report_sales_by(:'org_id', 'channel', null, null, null, null, 'social')), 1, 'the channel filter on the channel report narrows to that channel');

-- =====================================================================
-- 7. Filters: date range, warehouse, rep, channel
-- =====================================================================
select t.eq((select count(*) from report_sales_by(:'org_id', 'product', null, null, :'w2')), 1, 'warehouse 2: only X was sold from it');
select t.eq((select net_qty from report_sales_by(:'org_id', 'product', null, null, :'w2') where group_label = 'X'), 12, 'warehouse 2: 12 units (S3)');
select t.eq((select net_qty from report_sales_by(:'org_id', 'product', null, null, :'w1') where group_label = 'X'), 65, 'warehouse 1: X = 86 − 12 (S3) − 9 returned = 65');
select t.eq((select count(*) from report_sales_by(:'org_id', 'product', null, null, null, :'rep2')), 2, 'rep filter: rep 2 sold X and Y only');
select t.eq((select net_qty from report_sales_by(:'org_id', 'product', null, null, null, :'rep2') where group_label = 'X'), 24, 'rep filter: X 24');
select t.eq((select count(*) from report_sales_by(:'org_id', 'product', null, null, null, null, 'social')), 1, 'channel filter: social sold only X');
select t.eq((select net_qty from report_sales_by(:'org_id', 'product', null, null, null, null, 'wholesale') where group_label = 'X'), 44, 'channel filter: wholesale X = 24 + 20');
select t.eq((select sum(net_revenue) from report_sales_by(:'org_id', 'rep', null, null, null, null, 'retail')),
            (select net_revenue from report_sales_by(:'org_id', 'channel') where group_id = 'retail'), 'rep report filtered to retail = the retail channel total');
select t.eq((select count(*) from report_sales_by(:'org_id', 'rep', null, null, null, :'rep1', 'wholesale')), 1, 'combined filters: rep 1 ∩ wholesale');
select t.eq((select invoices from report_sales_by(:'org_id', 'rep', null, null, null, :'rep1', 'wholesale')), 1, '…is S4 only');
select t.eq((select net_qty from report_sales_by(:'org_id', 'customer', null, null, :'w1', :'rep1', 'retail') where group_label = 'عميل تجزئة'), (select net_qty from report_sales_by(:'org_id', 'customer', null, null, :'w1', :'rep1', 'retail') where group_label = 'عميل تجزئة'), 'combined filters run without error');
select t.eq((select count(*) from report_sales_by(:'org_id', 'product', current_date, current_date)), 3, 'a window that contains today includes everything');
-- date filter uses the invoice date
select t.as_owner();
update sales_invoices set invoice_date = current_date - 40 where id = :'s2_id';
select t.as_user('9a000000-0000-0000-0000-000000000001');
select t.eq((select count(*) from report_sales_by(:'org_id', 'rep', current_date - 10, current_date) where group_id = :'rep2'), 0, 'date range: rep 2''s only invoice is 40 days old → absent from the last 10 days');
select t.eq((select invoices from report_sales_by(:'org_id', 'rep', current_date - 60, current_date - 30) where group_id = :'rep2'), 1, 'date range: …and present in the window that contains it');
select t.eq((select count(*) from report_sales_by(:'org_id', 'rep', current_date - 40, current_date - 40) where group_id = :'rep2'), 1, 'date range: both ends are inclusive');
-- ordering and pagination
select t.eq_text((select group_label from report_sales_by(:'org_id', 'product') limit 1), (select group_label from report_sales_by(:'org_id', 'product') order by net_revenue desc, group_label limit 1), 'sorted by revenue, best first');
select t.eq((select count(*) from report_sales_by(:'org_id', 'product', null, null, null, null, null, 1, 0)), 1, 'limit works');
select t.eq((select total_count from report_sales_by(:'org_id', 'product', null, null, null, null, null, 1, 0)), 3, 'total_count reports the full size');
select t.eq((select count(*) from report_sales_by(:'org_id', 'product', null, null, null, null, null, 10, 3)), 0, 'offset past the end is empty');
select t.throws(format($q$select * from report_sales_by(%L, 'bogus')$q$, :'org_id'), 'نوع التقرير غير صحيح', 'unknown report type refused');
select t.throws(format($q$select * from report_sales_by(%L, 'rep', null, null, null, null, 'tiktok')$q$, :'org_id'), 'قناة البيع غير صحيحة', 'unknown channel filter refused');

-- =====================================================================
-- 8. Permissions: restricted reps only see their own sales; other orgs see nothing
-- =====================================================================
select t.as_user('9a000000-0000-0000-0000-000000000003');   -- rep 1
select t.eq((select count(*) from report_sales_by(:'org_id', 'rep')), 1, 'rep 1 sees a rep report with only himself');
select t.eq_text((select group_id from report_sales_by(:'org_id', 'rep')), :'rep1', 'and it is his own row');
select t.eq((select invoices from report_sales_by(:'org_id', 'rep')), 4, 'with his own four invoices');
select t.eq((select count(*) from report_sales_by(:'org_id', 'rep', null, null, null, :'rep2')), 0, 'asking for the other rep returns nothing');
select t.eq((select sum(net_revenue) from report_sales_by(:'org_id', 'channel')), (select net_revenue from report_sales_by(:'org_id', 'rep')), 'his channel report totals his revenue only');
select t.ok(not exists (select 1 from report_sales_by(:'org_id', 'customer') where group_label = 'عميل موزع'), 'the other rep''s customer never appears');
select t.ok(not exists (select 1 from report_sales_by(:'org_id', 'product') where group_label = 'Y' and net_qty > 6), 'product totals contain only his own sales (Y: 6 units, not 18)');
select t.as_user('9a000000-0000-0000-0000-000000000004');   -- rep 2
select t.eq((select invoices from report_sales_by(:'org_id', 'rep')), 1, 'rep 2 sees only his own invoice');
select t.as_user('9a000000-0000-0000-0000-000000000002');   -- another organization
select t.throws(format('select * from report_sales_by(%L, ''rep'')', :'org_id'), 'لست عضوًا', 'another organization cannot run the report on my data');
select t.eq((select count(*) from report_sales_by(:'orgb_id', 'rep')), 0, 'its own organization is simply empty');
select t.as_anon();
select t.throws(format('select * from report_sales_by(%L, ''rep'')', :'org_id'), 'permission denied', 'anonymous callers cannot run it');
select t.as_owner();
