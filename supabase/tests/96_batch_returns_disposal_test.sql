-- Reports package, Phase 2.1:
--   (1) a resalable sales return goes back to the batch it was sold from (same id / expiry),
--   (2) dispose_stock_batch removes stock from ONE batch and can never touch another,
--   (3) a randomized mix of every inventory operation keeps Σ batches = stock on hand.
\set ON_ERROR_STOP on
select t.as_owner();
create or replace function t.batch_drift2(p_org uuid) returns bigint language sql as $$
  select count(*) from (
    select s.product_id, s.warehouse_id, s.quantity as stock, coalesce((select sum(b.quantity) from stock_batches b where b.product_id = s.product_id and b.warehouse_id = s.warehouse_id), 0) as batches
    from inventory_stock s where s.organization_id = p_org) x
  where abs(x.stock - x.batches) > 0.0005 $$;
grant execute on function t.batch_drift2(uuid) to authenticated;
insert into auth.users (id, email) values
  ('96000000-0000-0000-0000-000000000001', 'owner@ret96.test'),
  ('96000000-0000-0000-0000-000000000002', 'other@ret96.test'),
  ('96000000-0000-0000-0000-000000000003', 'rep@ret96.test');
select t.as_user('96000000-0000-0000-0000-000000000001');
select create_organization('شركة المرتجعات', 'تجارة', 'EG', 'EGP', 'ar',
  array['sales','customers','inventory','purchases','suppliers','expenses','treasury']) as id \gset org_
select t.as_user('96000000-0000-0000-0000-000000000002');
select create_organization('شركة أخرى', 'تجارة', 'EG', 'EGP', 'ar', array['sales','inventory']) as id \gset orgb_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', '96000000-0000-0000-0000-000000000003', r.id, 'active' from roles r where r.key = 'sales' and r.organization_id is null;

select t.as_user('96000000-0000-0000-0000-000000000001');
insert into warehouses (organization_id, name) values (:'org_id', 'الرئيسي') returning id as w1 \gset
insert into warehouses (organization_id, name) values (:'org_id', 'الفرعي') returning id as w2 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as sup \gset
insert into customers (organization_id, name) values (:'org_id', 'عميل') returning id as cus \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'X', 'X', 'قطعة') returning id as px \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'Y', 'Y', 'قطعة') returning id as py \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'Z', 'Z', 'قطعة') returning id as pz \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'W', 'W', 'قطعة') returning id as pw \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'V', 'V', 'قطعة') returning id as pv \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'V2', 'V2', 'قطعة') returning id as pv2 \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'LEG', 'LEG', 'قطعة') returning id as pleg \gset
insert into product_prices (organization_id, product_id, selling_price) select :'org_id', id, 100 from products where organization_id = :'org_id';

-- =====================================================================
-- (1) Sales returns go back to the original batch
-- =====================================================================
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'P-X', cairo_today(),
  jsonb_build_array(
    jsonb_build_object('product_id', :'px', 'quantity', 30, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() + 10)::text),
    jsonb_build_object('product_id', :'px', 'quantity', 30, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() + 200)::text)),
  0, 0, 0, null, null, 0) as id \gset px_
select id as b10 from stock_batches where product_id = :'px' and expiry_date = cairo_today() + 10 \gset
select id as b200 from stock_batches where product_id = :'px' and expiry_date = cairo_today() + 200 \gset

select create_sales_invoice(:'org_id', :'cus', :'w1', 'S-X', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 40, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset sx_
select t.eq((select count(*) from stock_batches where id = :'b10'), 0, 'the +10d batch was used up by the sale');
select t.eq((select count(*) from sales_batch_allocations where sales_invoice_id = :'sx_id'), 2, 'the sale recorded two allocations (one per batch it drew from)');
select t.eq((select quantity from sales_batch_allocations where sales_invoice_id = :'sx_id' and batch_id = :'b10'), 30, 'allocation: 30 from the +10d batch');
select t.eq((select quantity from sales_batch_allocations where sales_invoice_id = :'sx_id' and batch_id = :'b200'), 10, 'allocation: 10 from the +200d batch');
select t.eq((select count(*) from sales_batch_allocations where sales_invoice_id = :'sx_id' and expiry_date is null), 0, 'allocations remember the expiry date');

select id as sx_item from sales_invoice_items where sales_invoice_id = :'sx_id' \gset
select create_sales_return(:'org_id', :'sx_id', cairo_today(),
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'sx_item', 'quantity', 25, 'condition', 'resalable')), 0, null) as id \gset rx1_
select t.eq((select count(*) from stock_batches where id = :'b10'), 1, 'return: the used-up batch is back under its ORIGINAL id');
select t.eq((select quantity from stock_batches where id = :'b10'), 25, 'return: 25 units restored to it');
select t.eq_text((select expiry_date::text from stock_batches where id = :'b10'), (cairo_today() + 10)::text, 'return: with its original expiry date');
select t.eq_text((select purchase_invoice_id::text from stock_batches where id = :'b10'), :'px_id', 'return: and its original purchase invoice');
select t.eq((select count(*) from stock_batches where product_id = :'px' and expiry_date is null), 0, 'return: nothing became an undated batch');
select t.eq((select returned_quantity from sales_batch_allocations where sales_invoice_id = :'sx_id' and batch_id = :'b10'), 25, 'allocation tracks what has been returned');
select t.eq(t.batch_drift2(:'org_id'), 0, 'no drift after the first return');

-- second return spills over to the next allocation once the first is exhausted
select pg_sleep(5.5);   -- duplicate-submission guard (0010)
select create_sales_return(:'org_id', :'sx_id', cairo_today(),
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'sx_item', 'quantity', 8, 'condition', 'resalable')), 0, null) as id \gset rx2_
select t.eq((select quantity from stock_batches where id = :'b10'), 30, 'second return: the first batch is topped up to 30 (its 5 remaining)');
select t.eq((select quantity from stock_batches where id = :'b200'), 23, 'second return: the other 3 go to the +200d batch (20 + 3)');
select t.eq((select count(*) from stock_batches where product_id = :'px' and expiry_date is null), 0, 'still no undated batch');
select pg_sleep(5.5);
select create_sales_return(:'org_id', :'sx_id', cairo_today(),
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'sx_item', 'quantity', 7, 'condition', 'resalable')), 0, null) as id \gset rx3_
select t.eq((select quantity from stock_batches where id = :'b200'), 30, 'third return: the +200d batch is whole again');
select t.eq((select count(*) from sales_batch_allocations where sales_invoice_id = :'sx_id' and returned_quantity <> quantity), 0, 'every allocation fully returned');
select t.eq((select sum(quantity) from stock_batches where product_id = :'px'), 60, 'all 60 units are back, exactly as bought');
select t.eq(t.batch_drift2(:'org_id'), 0, 'no drift after the full return');

-- a damaged return never re-enters stock and consumes no allocation
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'P-Y', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'py', 'quantity', 10, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() + 40)::text)), 0, 0, 0, null, null, 0) as id \gset py_
select create_sales_invoice(:'org_id', :'cus', :'w1', 'S-Y', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'py', 'quantity', 4, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset sy_
select create_sales_return(:'org_id', :'sy_id', cairo_today(),
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'sy_id'), 'quantity', 1, 'condition', 'damaged')), 0, null) as id \gset ry_
select t.eq((select sum(quantity) from stock_batches where product_id = :'py'), 6, 'damaged return: stock and batches unchanged (6)');
select t.eq((select returned_quantity from sales_batch_allocations where sales_invoice_id = :'sy_id'), 0, 'damaged return: allocation untouched');

-- the return goes to the INVOICE's warehouse even after a transfer moved the rest elsewhere
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'P-Z', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pz', 'quantity', 20, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() + 50)::text)), 0, 0, 0, null, null, 0) as id \gset pz_
select id as bz from stock_batches where product_id = :'pz' \gset
select create_sales_invoice(:'org_id', :'cus', :'w1', 'S-Z', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pz', 'quantity', 5, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset sz_
select create_stock_transfer(:'org_id', :'w1', :'w2', cairo_today(), jsonb_build_array(jsonb_build_object('product_id', :'pz', 'quantity', 15)), null) as id \gset trz_
select create_sales_return(:'org_id', :'sz_id', cairo_today(),
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'sz_id'), 'quantity', 2, 'condition', 'resalable')), 0, null) as id \gset rz_
select t.eq((select quantity from stock_batches where product_id = :'pz' and warehouse_id = :'w1' and expiry_date = cairo_today() + 50), 2, 'return after a transfer: 2 units back in the invoice warehouse, with the original date');
select t.eq((select quantity from stock_batches where product_id = :'pz' and warehouse_id = :'w2' and expiry_date = cairo_today() + 50), 15, 'the transferred 15 stay in the other warehouse');
select t.eq((select count(*) from stock_batches where id = :'bz'), 1, 'the original batch id is reused in the invoice warehouse');
select t.eq(t.batch_drift2(:'org_id'), 0, 'no drift after transfer + return');

-- a batch that expired after the sale: the goods come back as EXPIRED stock (and stay unsellable)
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'P-W', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pw', 'quantity', 10, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() + 3)::text)), 0, 0, 0, null, null, 0) as id \gset pw_
select create_sales_invoice(:'org_id', :'cus', :'w1', 'S-W', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pw', 'quantity', 4, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset sw_
select t.as_owner();
update stock_batches set expiry_date = cairo_today() - 1 where product_id = :'pw';   -- time passes
select t.as_user('96000000-0000-0000-0000-000000000001');
select create_sales_return(:'org_id', :'sw_id', cairo_today(),
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'sw_id'), 'quantity', 2, 'condition', 'resalable')), 0, null) as id \gset rw_
select t.eq((select quantity from stock_batches where product_id = :'pw'), 8, 'return into a since-expired batch: back in the same row (6 + 2)');
select t.eq_text((select status from report_expiry(:'org_id') where product_id = :'pw'), 'expired', 'and it shows as expired in the report');
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'S-W2', cairo_today(), jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 1, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0)$q$, :'org_id', :'cus', :'w1', :'pw'), 'منتهية الصلاحية', 'it cannot be sold again');

-- legacy: an invoice with no allocations (sold before this migration) falls back to an undated batch
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'P-L', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pleg', 'quantity', 10, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() + 90)::text)), 0, 0, 0, null, null, 0) as id \gset pl_
select create_sales_invoice(:'org_id', :'cus', :'w1', 'S-L', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pleg', 'quantity', 5, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset sl_
select t.as_owner();
delete from sales_batch_allocations where sales_invoice_id = :'sl_id';
select t.as_user('96000000-0000-0000-0000-000000000001');
select create_sales_return(:'org_id', :'sl_id', cairo_today(),
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'sl_id'), 'quantity', 2, 'condition', 'resalable')), 0, null) as id \gset rl_
select t.eq((select quantity from stock_batches where product_id = :'pleg' and expiry_date is null), 2, 'untraceable (legacy) sale: the return becomes an undated batch');
select t.eq(t.batch_drift2(:'org_id'), 0, 'no drift after the legacy return');

-- =====================================================================
-- (2) Batch-specific disposal
-- =====================================================================
-- V: expired 10 | expired 4 | valid 20 | undated 15
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'P-V', cairo_today(),
  jsonb_build_array(
    jsonb_build_object('product_id', :'pv', 'quantity', 10, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() - 5)::text),
    jsonb_build_object('product_id', :'pv', 'quantity', 4,  'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() - 20)::text),
    jsonb_build_object('product_id', :'pv', 'quantity', 20, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() + 30)::text),
    jsonb_build_object('product_id', :'pv', 'quantity', 15, 'unit_cost', 5, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset pv_
select id as bv_exp10 from stock_batches where product_id = :'pv' and expiry_date = cairo_today() - 5 \gset
select id as bv_exp4  from stock_batches where product_id = :'pv' and expiry_date = cairo_today() - 20 \gset
select id as bv_ok    from stock_batches where product_id = :'pv' and expiry_date = cairo_today() + 30 \gset
select id as bv_none  from stock_batches where product_id = :'pv' and expiry_date is null \gset

-- why dispose exists: a plain negative adjustment is FEFO, so an over-sized quantity spills into valid stock
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'P-V2', cairo_today(),
  jsonb_build_array(
    jsonb_build_object('product_id', :'pv2', 'quantity', 10, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() - 5)::text),
    jsonb_build_object('product_id', :'pv2', 'quantity', 20, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', (cairo_today() + 30)::text)), 0, 0, 0, null, null, 0) as id \gset pv2_
select adjust_inventory_stock(:'org_id', :'pv2', :'w1', -15, 'إعدام (عام)') as id \gset adjv2_
select t.eq((select quantity from stock_batches where product_id = :'pv2' and expiry_date > cairo_today()), 15, 'plain adjustment −15 is FEFO: it took the 10 expired AND 5 valid units (documented limitation)');

-- dispose exactly the 10-unit expired batch
select dispose_stock_batch(:'org_id', :'bv_exp10', 10, 'إعدام منتهي الصلاحية') as id \gset dv1_
select t.eq((select count(*) from stock_batches where id = :'bv_exp10'), 0, 'dispose: the batch is gone');
select t.eq((select quantity from stock_batches where id = :'bv_exp4'), 4, 'dispose: the other expired batch is untouched');
select t.eq((select quantity from stock_batches where id = :'bv_ok'), 20, 'dispose: valid stock untouched');
select t.eq((select quantity from stock_batches where id = :'bv_none'), 15, 'dispose: undated stock untouched');
select t.eq((select quantity from inventory_stock where product_id = :'pv' and warehouse_id = :'w1'), 39, 'dispose: stock on hand = 39');
select t.eq((select quantity_delta from inventory_movements where id = :'dv1_id'), -10, 'dispose: a movement of −10 is written');
select t.eq_text((select movement_type from inventory_movements where id = :'dv1_id'), 'adjustment', 'dispose: recorded as an adjustment');
select t.eq_text((select reference_type from inventory_movements where id = :'dv1_id'), 'batch_disposal', 'dispose: tagged batch_disposal');
select t.ok((select note from inventory_movements where id = :'dv1_id') like '%إعدام منتهي الصلاحية%', 'dispose: the reason is kept');
-- partial disposal
select dispose_stock_batch(:'org_id', :'bv_exp4', 1, 'تالف') as id \gset dv2_
select t.eq((select quantity from stock_batches where id = :'bv_exp4'), 3, 'partial disposal leaves the rest of the batch');
-- cannot exceed the batch, even though the warehouse has plenty of other stock
select t.throws(format('select dispose_stock_batch(%L, %L, 5, ''x'')', :'org_id', :'bv_exp4'), 'الكمية أكبر من كمية الدفعة (المتاح: 3', 'cannot dispose more than the batch holds');
select t.eq((select quantity from stock_batches where id = :'bv_ok'), 20, 'a refused disposal took nothing from valid stock');
select t.eq((select quantity from inventory_stock where product_id = :'pv' and warehouse_id = :'w1'), 38, 'stock unchanged by the refused disposal (38)');
select t.throws(format('select dispose_stock_batch(%L, %L, 0, ''x'')', :'org_id', :'bv_exp4'), 'أكبر من صفر', 'zero quantity refused');
select t.throws(format('select dispose_stock_batch(%L, %L, -2, ''x'')', :'org_id', :'bv_exp4'), 'أكبر من صفر', 'negative quantity refused');
select t.throws(format('select dispose_stock_batch(%L, %L, 1, '''')', :'org_id', :'bv_exp4'), 'سبب الإعدام مطلوب', 'a reason is required');
select t.throws(format('select dispose_stock_batch(%L, gen_random_uuid(), 1, ''x'')', :'org_id'), 'الدفعة غير موجودة', 'unknown batch refused');
-- any batch can be disposed (damaged / recalled valid stock), not only expired ones
select dispose_stock_batch(:'org_id', :'bv_none', 5, 'سحب من السوق') as id \gset dv3_
select t.eq((select quantity from stock_batches where id = :'bv_none'), 10, 'a valid undated batch can be disposed too');
select t.eq((select quantity from stock_batches where id = :'bv_ok'), 20, 'while the dated valid batch stays whole');
select dispose_stock_batch(:'org_id', :'bv_exp4', 3, 'إعدام') as id \gset dv4_
select t.eq((select count(*) from stock_batches where id = :'bv_exp4'), 0, 'disposing a whole batch removes it');
select t.eq(t.batch_drift2(:'org_id'), 0, 'no drift after disposals');

-- access control
select t.as_user('96000000-0000-0000-0000-000000000002');
select t.throws(format('select dispose_stock_batch(%L, %L, 1, ''x'')', :'org_id', :'bv_ok'), 'لست عضوًا', 'another organization cannot dispose my batch');
select t.throws(format('select dispose_stock_batch(%L, %L, 1, ''x'')', :'orgb_id', :'bv_ok'), 'الدفعة غير موجودة', 'nor by passing its own organization id with my batch id');
select t.eq((select count(*) from sales_batch_allocations where organization_id = :'org_id'), 0, 'another organization cannot read my allocations');
select t.as_user('96000000-0000-0000-0000-000000000003');
select t.throws(format('select dispose_stock_batch(%L, %L, 1, ''x'')', :'org_id', :'bv_ok'), 'صلاحية تسوية المخزون', 'a member without inventory.adjust cannot dispose');
select t.throws(format($q$insert into sales_batch_allocations (organization_id, sales_invoice_id, product_id, warehouse_id, batch_id, quantity) values (%L, %L, %L, %L, gen_random_uuid(), 1)$q$, :'org_id', :'sx_id', :'px', :'w1'), 'permission denied', 'allocations cannot be written directly');
select t.throws(format($q$select _batch_restore(%L, %L, %L, 1, %L)$q$, :'org_id', :'px', :'w1', :'sx_id'), 'permission denied', 'internal restore helper is not callable');
select t.as_anon();
select t.throws(format('select dispose_stock_batch(%L, %L, 1, ''x'')', :'org_id', :'bv_ok'), 'permission denied', 'anonymous callers cannot dispose');

-- =====================================================================
-- (3) Randomized stress: every operation, one transaction, drift checked after each
-- =====================================================================
select t.as_user('96000000-0000-0000-0000-000000000001');
select set_config('t.org', :'org_id', false), set_config('t.sup', :'sup', false), set_config('t.cus', :'cus', false),
       set_config('t.w1', :'w1', false), set_config('t.w2', :'w2', false),
       set_config('t.prods', array_to_string(array[:'px', :'py', :'pz', :'pw']::text[], ','), false);
select setseed(0.424242);
do $$
declare
  v_org uuid := current_setting('t.org')::uuid;
  v_sup uuid := current_setting('t.sup')::uuid;
  v_cus uuid := current_setting('t.cus')::uuid;
  v_wh uuid[] := array[current_setting('t.w1')::uuid, current_setting('t.w2')::uuid];
  v_prods uuid[] := string_to_array(current_setting('t.prods'), ',')::uuid[];
  v_ok int[] := array[0,0,0,0,0,0,0];
  v_sales uuid[] := '{}'; v_purch uuid[] := '{}';
  v_op int; v_p uuid; v_w uuid; v_q numeric; v_inv uuid; v_item uuid; v_batch record; v_exp text; v_i int; v_drift bigint; v_other uuid; v_msg text;
  v_errs text[] := '{}';
begin
  for v_i in 1..400 loop
    v_op := floor(random() * 7)::int;
    v_p := v_prods[1 + floor(random() * 4)::int];
    v_w := v_wh[1 + floor(random() * 2)::int];
    v_other := case when v_w = v_wh[1] then v_wh[2] else v_wh[1] end;
    v_q := 1 + floor(random() * 25);
    begin
      if v_op = 0 then      -- purchase, expiry: none / past / soon / far
        v_exp := case floor(random() * 4)::int when 0 then null when 1 then (cairo_today() - (1 + floor(random() * 20))::int)::text
                      when 2 then (cairo_today() + (1 + floor(random() * 30))::int)::text else (cairo_today() + (60 + floor(random() * 300))::int)::text end;
        v_inv := create_purchase_invoice(v_org, v_sup, v_w, 'R-P' || v_i, cairo_today(),
          jsonb_build_array(case when v_exp is null then jsonb_build_object('product_id', v_p, 'quantity', v_q, 'unit_cost', 5, 'discount_pct', 0)
                                 else jsonb_build_object('product_id', v_p, 'quantity', v_q, 'unit_cost', 5, 'discount_pct', 0, 'expiry_date', v_exp) end),
          0, 0, 0, null, null, 0);
        v_purch := v_purch || v_inv;
      elsif v_op = 1 then   -- sale
        v_inv := create_sales_invoice(v_org, v_cus, v_w, 'R-S' || v_i, cairo_today(),
          jsonb_build_array(jsonb_build_object('product_id', v_p, 'quantity', v_q, 'unit_price', 100 + v_i, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0);
        v_sales := v_sales || v_inv;
      elsif v_op = 2 and array_length(v_sales, 1) > 0 then   -- sales return (resalable / damaged)
        v_inv := v_sales[1 + floor(random() * array_length(v_sales, 1))::int];
        select id into v_item from sales_invoice_items where sales_invoice_id = v_inv order by id limit 1;
        perform create_sales_return(v_org, v_inv, cairo_today(),
          jsonb_build_array(jsonb_build_object('sales_invoice_item_id', v_item, 'quantity', 1 + floor(random() * 4), 'condition', case when random() < 0.7 then 'resalable' else 'damaged' end)), 0, null);
      elsif v_op = 3 and array_length(v_purch, 1) > 0 then   -- purchase return
        v_inv := v_purch[1 + floor(random() * array_length(v_purch, 1))::int];
        select id into v_item from purchase_invoice_items where purchase_invoice_id = v_inv order by id limit 1;
        perform create_purchase_return(v_org, v_inv, cairo_today(),
          jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', v_item, 'quantity', 1 + floor(random() * 6))), 0, null);
      elsif v_op = 4 then   -- transfer
        -- a distinct date per iteration: the duplicate-submission guard (0010) refuses identical transfers inside one transaction
        perform create_stock_transfer(v_org, v_w, v_other, cairo_today() - (v_i % 300), jsonb_build_array(jsonb_build_object('product_id', v_p, 'quantity', 1 + floor(random() * 15))), null);
      elsif v_op = 5 then   -- manual adjustment ±
        if random() < 0.5 then
          perform adjust_inventory_stock(v_org, v_p, v_w, (1 + floor(random() * 10))::numeric, 'جرد ' || v_i, case when random() < 0.5 then (cairo_today() + (1 + floor(random() * 200))::int) else null::date end);
        else
          perform adjust_inventory_stock(v_org, v_p, v_w, (-(1 + floor(random() * 12)))::numeric, 'نقص ' || v_i);
        end if;
      elsif v_op = 6 then   -- dispose a random batch (whole or part)
        select * into v_batch from stock_batches where organization_id = v_org order by random() limit 1;
        if v_batch.id is not null then
          perform dispose_stock_batch(v_org, v_batch.id, case when random() < 0.5 then v_batch.quantity else greatest(1::numeric, floor(v_batch.quantity / 2)) end, 'إعدام ' || v_i);
        end if;
      end if;
      v_ok[v_op + 1] := v_ok[v_op + 1] + 1;
    exception when others then
      v_msg := sqlerrm;
      -- only business-rule rejections are acceptable; anything else is a bug
      if v_msg not like '%المتاح%' and v_msg not like '%أقل من%' and v_msg not like '%منتهية الصلاحية%' and v_msg not like '%سالب%'
         and v_msg not like '%مطابقة%' and v_msg not like '%الكمية%' and v_msg not like '%تتجاوز%' and v_msg not like '%المرتجع%' and v_msg not like '%لا يغطي%' then
        v_errs := v_errs || (v_op::text || ':' || v_msg);
      end if;
    end;
    select t.batch_drift2(v_org) into v_drift;
    if v_drift <> 0 then
      raise exception 'batch drift after op % (iteration %): % stock rows disagree with their batches', v_op, v_i, v_drift;
    end if;
  end loop;
  if array_length(v_errs, 1) > 0 then
    raise exception 'unexpected errors in the stress run: %', v_errs[1:5];
  end if;
  raise notice 'stress successes per op [purchase,sale,sale_return,purchase_return,transfer,adjust,dispose] = %', v_ok;
  perform set_config('t.stress_ok', array_to_string(v_ok, ','), false);
end $$;
select t.ok((select bool_and(x::int >= 8) from unnest(string_to_array(current_setting('t.stress_ok'), ',')) x), 'stress: every operation type succeeded at least 8 times (so the loop really exercised them)');
select t.eq(t.batch_drift2(:'org_id'), 0, 'stress: batches = stock for every product and warehouse after 400 mixed operations');
select t.eq((select count(*) from sales_batch_allocations where organization_id = :'org_id' and expiry_date < cairo_today() and created_at > now() - interval '1 hour' and sales_invoice_id in (select id from sales_invoices where invoice_number like 'R-S%')), 0, 'stress: no sale ever drew from an expired batch');
select t.eq((select count(*) from stock_batches where organization_id = :'org_id' and quantity <= 0), 0, 'stress: no empty batch rows linger');
select t.as_owner();
