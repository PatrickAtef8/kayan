-- Reports package, Phase 2: per-batch expiry dates, FEFO, expired stock is never sold.
\set ON_ERROR_STOP on
select t.as_owner();
-- batches always add up to the stock tables (the invariant everything relies on)
create or replace function t.batch_drift(p_org uuid) returns bigint language sql as $$
  select count(*) from (
    select s.product_id, s.warehouse_id, s.quantity as stock, coalesce((select sum(b.quantity) from stock_batches b where b.product_id = s.product_id and b.warehouse_id = s.warehouse_id), 0) as batches
    from inventory_stock s where s.organization_id = p_org) x
  where abs(x.stock - x.batches) > 0.0005 $$;
grant execute on function t.batch_drift(uuid) to authenticated;
insert into auth.users (id, email) values
  ('95000000-0000-0000-0000-000000000001', 'owner@exp95.test'),
  ('95000000-0000-0000-0000-000000000002', 'other@exp95.test');
select t.as_user('95000000-0000-0000-0000-000000000001');
select create_organization('شركة الصلاحية', 'تجارة', 'EG', 'EGP', 'ar',
  array['sales','customers','inventory','purchases','suppliers','expenses','treasury']) as id \gset org_
select t.as_user('95000000-0000-0000-0000-000000000002');
select create_organization('شركة أخرى', 'تجارة', 'EG', 'EGP', 'ar', array['sales','inventory']) as id \gset orgb_

select t.as_user('95000000-0000-0000-0000-000000000001');
insert into warehouses (organization_id, name) values (:'org_id', 'الرئيسي') returning id as w1 \gset
insert into warehouses (organization_id, name) values (:'org_id', 'الفرعي') returning id as w2 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as sup \gset
insert into customers (organization_id, name) values (:'org_id', 'عميل') returning id as cus \gset
insert into products (organization_id, name, sku, unit, barcode) values (:'org_id', 'أ', 'A', 'قطعة', '1001') returning id as pa \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'ب', 'B', 'قطعة') returning id as pb \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'ج', 'C', 'قطعة') returning id as pc \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'د', 'D', 'قطعة') returning id as pd \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'هـ', 'E', 'قطعة') returning id as pe \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'و', 'F', 'قطعة') returning id as pf \gset
insert into product_prices (organization_id, product_id, selling_price) select :'org_id', id, 100 from products where organization_id = :'org_id';


-- ---------- receiving: same product, several expiry dates, one purchase ----------
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'P-1', cairo_today(),
  jsonb_build_array(
    jsonb_build_object('product_id', :'pa', 'quantity', 10, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() - 5)::text),
    jsonb_build_object('product_id', :'pa', 'quantity', 20, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() + 10)::text),
    jsonb_build_object('product_id', :'pa', 'quantity', 30, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() + 200)::text),
    jsonb_build_object('product_id', :'pa', 'quantity', 40, 'unit_cost', 5, 'discount_pct', 0)),
  0, 0, 0, null, null, 0) as id \gset p1_
select t.eq((select count(*) from stock_batches where product_id = :'pa' and warehouse_id = :'w1'), 4, 'one product, four batches (three dates + one undated)');
select t.eq((select quantity from inventory_stock where product_id = :'pa' and warehouse_id = :'w1'), 100, 'stock is the sum of the batches');
select t.eq((select quantity from stock_batches where product_id = :'pa' and expiry_date = cairo_today() + 10), 20, 'batch quantity kept per expiry date');
select t.eq((select count(*) from stock_batches where product_id = :'pa' and expiry_date is null), 1, 'a line without a date becomes an undated batch (optional)');
select t.eq((select count(*) from stock_batches where product_id = :'pa' and purchase_invoice_id = :'p1_id'), 4, 'batches remember the purchase invoice');
select t.eq(t.batch_drift(:'org_id'), 0, 'no drift after the purchase');

-- merging: the same expiry on a later invoice is a separate batch only because the invoice differs
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'P-1b', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pc', 'quantity', 5, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() + 30)::text),
                    jsonb_build_object('product_id', :'pc', 'quantity', 7, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() + 30)::text)),
  0, 0, 0, null, null, 0) as id \gset p1b_
select t.eq((select count(*) from stock_batches where product_id = :'pc'), 1, 'two lines with the same expiry on one invoice share one batch');
select t.eq((select quantity from stock_batches where product_id = :'pc'), 12, 'and their quantities add up');

-- bad dates
select t.throws(format($q$select create_purchase_invoice(%L, %L, %L, 'X', cairo_today(), jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 1, 'unit_cost', 1, 'discount_pct', 0, 'expiry_date', 'not-a-date')), 0, 0, 0, null, null, 0)$q$, :'org_id', :'sup', :'w1', :'pb'), 'تاريخ الصلاحية غير صحيح', 'garbage expiry date refused');
select t.throws(format($q$select create_purchase_invoice(%L, %L, %L, 'X', cairo_today(), jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 1, 'unit_cost', 1, 'discount_pct', 0, 'expiry_date', '1999-01-01')), 0, 0, 0, null, null, 0)$q$, :'org_id', :'sup', :'w1', :'pb'), 'تاريخ الصلاحية غير صحيح', 'implausible expiry date refused');
select t.eq((select count(*) from stock_batches where product_id = :'pb'), 0, 'refused purchases left no batches behind');
-- empty string = no date
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'P-empty', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 2, 'unit_cost', 1, 'discount_pct', 0, 'expiry_date', '')), 0, 0, 0, null, null, 0) as id \gset pe_
select t.eq((select count(*) from stock_batches where product_id = :'pb' and expiry_date is null), 1, 'an empty date field means "no expiry recorded"');

-- ---------- selling: FEFO, never expired ----------
-- A: expired 10 | +10d 20 | +200d 30 | undated 40
select create_sales_invoice(:'org_id', :'cus', :'w1', 'S-1', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 25, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset s1_
select t.eq((select count(*) from stock_batches where product_id = :'pa' and expiry_date = cairo_today() + 10), 0, 'FEFO: the earliest non-expired batch (20) is used up first');
select t.eq((select quantity from stock_batches where product_id = :'pa' and expiry_date = cairo_today() + 200), 25, 'FEFO: then the next one (30 − 5 = 25)');
select t.eq((select quantity from stock_batches where product_id = :'pa' and expiry_date is null), 40, 'undated stock is touched only after dated stock');
select t.eq((select quantity from stock_batches where product_id = :'pa' and expiry_date < cairo_today()), 10, 'the expired batch is untouched');
select t.eq(t.batch_drift(:'org_id'), 0, 'no drift after a sale');

-- 75 on hand but only 65 sellable
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'S-2', cairo_today(), jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 70, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0)$q$, :'org_id', :'cus', :'w1', :'pa'),
  'لا يمكن بيع بضاعة منتهية الصلاحية', 'selling into expired stock is refused (75 on hand, 65 sellable)');
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'S-2', cairo_today(), jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 70, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0)$q$, :'org_id', :'cus', :'w1', :'pa'),
  'المتاح للبيع (غير المنتهي): 65', 'the message says how much is actually sellable');
select t.eq((select quantity from inventory_stock where product_id = :'pa' and warehouse_id = :'w1'), 75, 'a refused sale changes nothing');
-- a bonus line is a deduction too: it cannot dip into expired stock either
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'S-3', cairo_today(), jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 60, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0, jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 10)))$q$, :'org_id', :'cus', :'w1', :'pa', :'pa'),
  'منتهية الصلاحية', 'bonus units cannot come out of expired stock');

select create_sales_invoice(:'org_id', :'cus', :'w1', 'S-4', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 65, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset s4_
select t.eq((select count(*) from stock_batches where product_id = :'pa'), 1, 'only the expired batch is left');
select t.eq((select quantity from stock_batches where product_id = :'pa'), 10, 'with its 10 units');
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'S-5', cairo_today(), jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 1, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0)$q$, :'org_id', :'cus', :'w1', :'pa'),
  'المتاح للبيع (غير المنتهي): 0', 'a product with only expired stock cannot be sold at all');
-- the ordinary "not enough stock" message still wins when the total is short
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'S-6', cairo_today(), jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 500, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0)$q$, :'org_id', :'cus', :'w1', :'pa'),
  'الكمية المتاحة بالمخزون أقل', 'the usual shortage message is unchanged');

-- write-off of expired stock = a negative adjustment (deducts expired batches too)
select adjust_inventory_stock(:'org_id', :'pa', :'w1', -10, 'إعدام منتهي الصلاحية') as id \gset wo_
select t.eq((select count(*) from stock_batches where product_id = :'pa'), 0, 'write-off removes the expired batch');
select t.eq((select quantity from inventory_stock where product_id = :'pa' and warehouse_id = :'w1'), 0, 'and the stock');

-- ---------- adjustments ----------
select adjust_inventory_stock(:'org_id', :'pa', :'w1', 5, 'جرد', (cairo_today() + 90)::date) as id \gset a1_
select t.eq((select quantity from stock_batches where product_id = :'pa' and expiry_date = cairo_today() + 90), 5, 'an increase can carry an expiry date');
select adjust_inventory_stock(:'org_id', :'pa', :'w1', 3, 'جرد') as id \gset a2_
select t.eq((select quantity from stock_batches where product_id = :'pa' and expiry_date is null), 3, 'an increase without a date is an undated batch');
select t.throws(format('select adjust_inventory_stock(%L, %L, %L, -1, ''x'', cairo_today() + 5)', :'org_id', :'pa', :'w1'), 'مع الزيادة فقط', 'an expiry date on a decrease is refused');
select t.throws(format('select adjust_inventory_stock(%L, %L, %L, 1, ''x'', date ''1990-01-01'')', :'org_id', :'pa', :'w1'), 'تاريخ الصلاحية غير صحيح', 'implausible adjustment date refused');
select t.eq((select count(*) from stock_batches where product_id = :'pa'), 2, 'adjustments left exactly two batches');
select t.eq(t.batch_drift(:'org_id'), 0, 'no drift after adjustments');
-- the 5-argument call (old signature) still works
select adjust_inventory_stock(:'org_id', :'pa', :'w1', -3, 'تصحيح') as id \gset a3_
select t.eq((select quantity from inventory_stock where product_id = :'pa' and warehouse_id = :'w1'), 5, 'the old 5-argument call still works');

-- ---------- purchase return: from the returned invoice's batch, not the FEFO one ----------
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'P-B1', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 10, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() + 100)::text)), 0, 0, 0, null, null, 0) as id \gset pb1_
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'P-B2', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 10, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() + 50)::text)), 0, 0, 0, null, null, 0) as id \gset pb2_
select create_purchase_return(:'org_id', :'pb1_id', cairo_today(),
  jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', (select id from purchase_invoice_items where purchase_invoice_id = :'pb1_id'), 'quantity', 4)), 0, null) as id \gset rb_
select t.eq((select quantity from stock_batches where product_id = :'pb' and expiry_date = cairo_today() + 100), 6, 'purchase return came out of the returned invoice''s batch (10 − 4)');
select t.eq((select quantity from stock_batches where product_id = :'pb' and expiry_date = cairo_today() + 50), 10, 'the other (earlier-expiring) batch is untouched');
select t.eq(t.batch_drift(:'org_id'), 0, 'no drift after a purchase return');

-- ---------- sales return (resalable) ----------
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'P-D', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pd', 'quantity', 10, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() + 60)::text)), 0, 0, 0, null, null, 0) as id \gset pd_
select create_sales_invoice(:'org_id', :'cus', :'w1', 'S-D', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pd', 'quantity', 4, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset sd_
select create_sales_return(:'org_id', :'sd_id', cairo_today(),
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'sd_id'), 'quantity', 2, 'condition', 'resalable')), 0, null) as id \gset rd_
select t.eq((select quantity from stock_batches where product_id = :'pd' and expiry_date = cairo_today() + 60), 8, 'sold 4 of 10, 2 returned → back in the ORIGINAL dated batch (6 + 2)');
select t.eq((select count(*) from stock_batches where product_id = :'pd' and expiry_date is null), 0, 'a resalable return no longer creates an undated batch (Phase 2.1)');
select t.eq(t.batch_drift(:'org_id'), 0, 'no drift after a sales return');
-- damaged returns never re-enter stock → no batch
select pg_sleep(5.5);   -- the duplicate-submission guard (0010) blocks a second return on the same invoice within 5 s
select create_sales_return(:'org_id', :'sd_id', cairo_today(),
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'sd_id'), 'quantity', 1, 'condition', 'damaged')), 0, null) as id \gset rd2_
select t.eq((select sum(quantity) from stock_batches where product_id = :'pd'), 8, 'a damaged return adds no batch');

-- ---------- transfers keep expiry dates ----------
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'P-C', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pe', 'quantity', 30, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() + 20)::text),
                    jsonb_build_object('product_id', :'pe', 'quantity', 10, 'unit_cost', 5, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset pcx_
select create_stock_transfer(:'org_id', :'w1', :'w2', cairo_today(), jsonb_build_array(jsonb_build_object('product_id', :'pe', 'quantity', 35)), null) as id \gset tr_
select t.eq((select quantity from stock_batches where product_id = :'pe' and warehouse_id = :'w2' and expiry_date = cairo_today() + 20), 30, 'transfer: the dated batch arrives with its expiry date');
select t.eq((select quantity from stock_batches where product_id = :'pe' and warehouse_id = :'w2' and expiry_date is null), 5, 'transfer: FEFO took 5 undated after the dated 30');
select t.eq((select quantity from stock_batches where product_id = :'pe' and warehouse_id = :'w1' and expiry_date is null), 5, 'transfer: 5 undated stay in the source');
select t.eq((select count(*) from stock_batches where product_id = :'pe' and warehouse_id = :'w1' and expiry_date is not null), 0, 'transfer: no dated batch left in the source');
select t.eq(t.batch_drift(:'org_id'), 0, 'no drift after a transfer');
-- GUC hygiene: a transfer must not leave the "skip" switch on for later stock changes
select adjust_inventory_stock(:'org_id', :'pe', :'w1', 2, 'بعد النقل', (cairo_today() + 7)::date) as id \gset ah_
select t.eq((select quantity from stock_batches where product_id = :'pe' and warehouse_id = :'w1' and expiry_date = cairo_today() + 7), 2, 'batch tracking still works after a transfer in the same session');

-- ---------- reports ----------
-- product F: expired 5 | expiring in 30d: 6 | ok (+400d): 7 | undated 8
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'P-F', cairo_today(),
  jsonb_build_array(
    jsonb_build_object('product_id', :'pf', 'quantity', 5, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() - 3)::text),
    jsonb_build_object('product_id', :'pf', 'quantity', 6, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() + 30)::text),
    jsonb_build_object('product_id', :'pf', 'quantity', 7, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() + 400)::text),
    jsonb_build_object('product_id', :'pf', 'quantity', 8, 'unit_cost', 5, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset pf_
select t.eq_text((select status from report_expiry(:'org_id') where product_id = :'pf' and quantity = 5), 'expired', 'report: expired');
select t.eq((select days_to_expiry from report_expiry(:'org_id') where product_id = :'pf' and quantity = 5), -3, 'report: 3 days past');
select t.eq_text((select status from report_expiry(:'org_id') where product_id = :'pf' and quantity = 6), 'expiring', 'report: expires within the default 90 days');
select t.eq((select days_to_expiry from report_expiry(:'org_id') where product_id = :'pf' and quantity = 6), 30, 'report: 30 days to go');
select t.eq_text((select status from report_expiry(:'org_id') where product_id = :'pf' and quantity = 7), 'ok', 'report: far-off date is ok');
select t.eq_text((select status from report_expiry(:'org_id') where product_id = :'pf' and quantity = 8), 'no_expiry', 'report: undated batch is no_expiry');
select t.ok((select days_to_expiry from report_expiry(:'org_id') where product_id = :'pf' and quantity = 8) is null, 'report: no days figure for an undated batch');
select t.eq_text((select status from report_expiry(:'org_id', null, null, 20) where product_id = :'pf' and quantity = 6), 'ok', 'report: the window is adjustable (30 days out is "ok" with a 20-day window)');
select t.eq((select count(*) from report_expiry(:'org_id', null, 'expired') where product_id = :'pf'), 1, 'report: filter by status');
select t.eq((select count(*) from report_expiry(:'org_id', null, 'no_expiry') where product_id = :'pf'), 1, 'report: filter undated');
select t.eq((select count(*) from report_expiry(:'org_id', :'w2') where product_id = :'pf'), 0, 'report: warehouse filter');
select t.eq_text((select barcode from report_expiry(:'org_id') where product_id = :'pa' limit 1), '1001', 'report: barcode is returned');
-- ordering: soonest first, undated last
select t.ok((select expiry_date from report_expiry(:'org_id') limit 1) = (select min(expiry_date) from stock_batches where organization_id = :'org_id'), 'report: soonest expiry first');
select t.ok((select expiry_date from (select expiry_date, row_number() over () as n from report_expiry(:'org_id')) q order by n desc limit 1) is null, 'report: undated batches come last');
-- the same product shows once per batch
select t.eq((select count(*) from report_expiry(:'org_id') where product_id = :'pf'), 4, 'report: one row per batch');
-- summary agrees with the rows
select t.eq((report_expiry_summary(:'org_id')->'expired'->>'quantity')::numeric, (select coalesce(sum(quantity), 0) from report_expiry(:'org_id', null, 'expired')), 'summary: expired quantity = sum of expired rows');
select t.eq((report_expiry_summary(:'org_id')->'no_expiry'->>'quantity')::numeric, (select coalesce(sum(quantity), 0) from report_expiry(:'org_id', null, 'no_expiry')), 'summary: undated quantity = sum of undated rows');
select t.eq((report_expiry_summary(:'org_id')->'expiring'->>'batches')::numeric, (select count(*) from report_expiry(:'org_id', null, 'expiring')), 'summary: expiring batch count');
select t.eq((select sum((v->>'quantity')::numeric) from jsonb_each(report_expiry_summary(:'org_id')) e(k, v)), (select sum(quantity) from inventory_stock where organization_id = :'org_id'), 'summary: the four statuses cover all stock on hand');

-- ---------- backfill ----------
select t.as_owner();
delete from stock_batches where product_id = :'pf';
select t.ok(_backfill_stock_batches() >= 1, 'backfill reports the rows it repaired');
select t.eq((select count(*) from stock_batches where product_id = :'pf'), 1, 'backfill: one undated batch for the legacy stock');
select t.eq((select quantity from stock_batches where product_id = :'pf'), 26, 'backfill: covering the full 26 units');
select t.eq(_backfill_stock_batches(), 0, 'backfill is idempotent');
select t.eq(t.batch_drift(:'org_id'), 0, 'no drift after backfill');
select t.as_user('95000000-0000-0000-0000-000000000001');

-- ---------- access control ----------
select t.as_user('95000000-0000-0000-0000-000000000002');
select t.eq((select count(*) from stock_batches where organization_id = :'org_id'), 0, 'another organization cannot read my batches');
select t.throws(format('select * from report_expiry(%L)', :'org_id'), 'لست عضوًا', 'another organization cannot run the expiry report');
select t.throws(format('select report_expiry_summary(%L)', :'org_id'), 'لست عضوًا', 'nor the summary');
select t.throws(format($q$insert into stock_batches (organization_id, product_id, warehouse_id, quantity) values (%L, %L, %L, 5)$q$, :'org_id', :'pa', :'w1'), 'permission denied', 'nobody can write batches directly');
select t.as_user('95000000-0000-0000-0000-000000000001');
select t.throws(format($q$insert into stock_batches (organization_id, product_id, warehouse_id, quantity) values (%L, %L, %L, 5)$q$, :'org_id', :'pa', :'w1'), 'permission denied', 'not even the owner can write batches directly');
select t.throws(format($q$update stock_batches set quantity = 999 where product_id = %L$q$, :'pa'), 'permission denied', 'nor edit them');
select t.throws(format($q$select _batch_take(%L, %L, %L, 1, false, null, null)$q$, :'org_id', :'pa', :'w1'), 'permission denied', 'internal batch helpers are not callable');
select t.as_anon();
select t.throws(format('select * from report_expiry(%L)', :'org_id'), 'permission denied', 'anonymous callers cannot run the report');
select t.as_owner();
