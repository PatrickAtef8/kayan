-- Reports package, Phase 1: report_reorder + report_product_movement + new product fields.
\set ON_ERROR_STOP on
select t.as_owner();
insert into auth.users (id, email) values
  ('94000000-0000-0000-0000-000000000001', 'owner@inv94.test'),
  ('94000000-0000-0000-0000-000000000002', 'other@inv94.test');
select t.as_user('94000000-0000-0000-0000-000000000001');
select create_organization('شركة المخزون', 'تجارة', 'EG', 'EGP', 'ar',
  array['sales','customers','inventory','purchases','suppliers','expenses','treasury']) as id \gset org_
select t.as_user('94000000-0000-0000-0000-000000000002');
select create_organization('شركة أخرى', 'تجارة', 'EG', 'EGP', 'ar', array['sales','inventory']) as id \gset orgb_

select t.as_user('94000000-0000-0000-0000-000000000001');
insert into warehouses (organization_id, name) values (:'org_id', 'الرئيسي') returning id as w1 \gset
insert into warehouses (organization_id, name) values (:'org_id', 'الفرعي') returning id as w2 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as sup \gset
insert into customers (organization_id, name) values (:'org_id', 'عميل') returning id as cus \gset

-- A: level 50, 12 per carton | B: level 10 | C: no level | D: inactive with a level
insert into products (organization_id, name, sku, unit, barcode, reorder_level, units_per_carton) values (:'org_id', 'أ', 'A', 'قطعة', '6221000000011', 50, 12) returning id as pa \gset
insert into products (organization_id, name, sku, unit, barcode, reorder_level) values (:'org_id', 'ب', 'B', 'قطعة', '6221000000028', 10) returning id as pb \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'ج', 'C', 'قطعة') returning id as pc \gset
insert into products (organization_id, name, sku, unit, reorder_level, is_active) values (:'org_id', 'د', 'D', 'قطعة', 99, false) returning id as pd \gset
insert into product_prices (organization_id, product_id, selling_price) select :'org_id', id, 100 from products where organization_id = :'org_id';

-- ---------- product fields ----------
select t.eq((select reorder_level from products where id = :'pc'), 0, 'a product with no level defaults to 0');
select t.ok((select units_per_carton from products where id = :'pc') is null, 'carton size is optional');
select t.throws(format('insert into products (organization_id, name, barcode) values (%L, ''x'', ''6221000000011'')', :'org_id'), 'products_org_barcode_uniq', 'a barcode cannot be used by two products in one organization');
select t.throws(format('update products set reorder_level = -1 where id = %L', :'pa'), 'products_reorder_level_chk', 'negative reorder level refused');
select t.throws(format('update products set units_per_carton = 0 where id = %L', :'pa'), 'products_units_per_carton_chk', 'zero carton size refused');
select t.throws(format('update products set reorder_level = ''NaN'' where id = %L', :'pa'), 'products_reorder_level_chk', 'NaN reorder level refused');

-- ---------- stock: buy 100 A, 20 B, 5 C ----------
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'P-1', cairo_today(),
  jsonb_build_array(
    jsonb_build_object('product_id', :'pa', 'quantity', 100, 'unit_cost', 40, 'discount_pct', 0),
    jsonb_build_object('product_id', :'pb', 'quantity', 20,  'unit_cost', 10, 'discount_pct', 0),
    jsonb_build_object('product_id', :'pc', 'quantity', 5,   'unit_cost', 5,  'discount_pct', 0)),
  0, 0, 0, null, null, 0) as id \gset p1_

-- at this point nothing is at/below its level
select t.eq((select count(*) from report_reorder(:'org_id')), 0, 'nothing short while stock is above every level');

-- sell 60 A (→ 40 ≤ 50 = low), all 20 B (→ 0 = out), all 5 C (→ 0 but no level)
select create_sales_invoice(:'org_id', :'cus', :'w1', 'S-1', cairo_today(),
  jsonb_build_array(
    jsonb_build_object('product_id', :'pa', 'quantity', 60, 'unit_price', 100, 'discount_pct', 0),
    jsonb_build_object('product_id', :'pb', 'quantity', 20, 'unit_price', 100, 'discount_pct', 0),
    jsonb_build_object('product_id', :'pc', 'quantity', 5,  'unit_price', 100, 'discount_pct', 0)),
  0, 0, 0, null, null, null, 0) as id \gset s1_

select t.eq((select count(*) from report_reorder(:'org_id')), 2, 'A (low) and B (out) are short; C has no level; D is inactive');
select t.eq_text((select status from report_reorder(:'org_id') where product_id = :'pa'), 'low', 'A is low');
select t.eq((select current_qty from report_reorder(:'org_id') where product_id = :'pa'), 40, 'A current quantity 40');
select t.eq((select shortage from report_reorder(:'org_id') where product_id = :'pa'), 10, 'A shortage = 50 − 40');
select t.eq_text((select status from report_reorder(:'org_id') where product_id = :'pb'), 'out', 'B is out');
select t.eq((select shortage from report_reorder(:'org_id') where product_id = :'pb'), 10, 'B shortage = the full level');
select t.eq_text((select product_id::text from report_reorder(:'org_id') limit 1), :'pb', 'out-of-stock items are listed first');
select t.eq_text((select barcode from report_reorder(:'org_id') where product_id = :'pa'), '6221000000011', 'barcode is returned');

-- stock exactly at the level counts as short ("at or below")
select adjust_inventory_stock(:'org_id', :'pa', :'w1', 10, 'اختبار') as id \gset adj_
select t.eq((select current_qty from report_reorder(:'org_id') where product_id = :'pa'), 50, 'A is exactly at its level…');
select t.eq((select count(*) from report_reorder(:'org_id') where product_id = :'pa'), 1, '…and still listed (at or below)');
select adjust_inventory_stock(:'org_id', :'pa', :'w1', 1, 'اختبار') as id \gset adj_
select t.eq((select count(*) from report_reorder(:'org_id') where product_id = :'pa'), 0, 'one above the level drops it off the report');
select adjust_inventory_stock(:'org_id', :'pa', :'w1', -11, 'تصحيح') as id \gset adj_   -- back to 40

-- warehouse filter: compare inside one warehouse
select t.eq((select current_qty from report_reorder(:'org_id', :'w2') where product_id = :'pa'), 0, 'warehouse filter: A has nothing in the second warehouse');
select t.eq_text((select status from report_reorder(:'org_id', :'w2') where product_id = :'pa'), 'out', 'warehouse filter: out in that warehouse');

-- ---------- product movement ----------
-- A so far: purchased 100, sold 60. Return 5 resalable, move 10 to w2.
select create_sales_return(:'org_id', :'s1_id', cairo_today(),
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'s1_id' and product_id = :'pa'), 'quantity', 5, 'condition', 'resalable')), 0, null) as id \gset r1_
select create_stock_transfer(:'org_id', :'w1', :'w2', cairo_today(), jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 10)), null) as id \gset tr_

-- whole period, all warehouses
select t.eq((select purchased_qty from report_product_movement(:'org_id') where product_id = :'pa'), 100, 'A purchased');
select t.eq((select sold_qty from report_product_movement(:'org_id') where product_id = :'pa'), 60, 'A sold');
select t.eq((select sale_returned_qty from report_product_movement(:'org_id') where product_id = :'pa'), 5, 'A resalable return');
select t.eq((select net_sold_qty from report_product_movement(:'org_id') where product_id = :'pa'), 55, 'A net sold = 60 − 5');
select t.eq((select other_net_qty from report_product_movement(:'org_id') where product_id = :'pa'), 0, 'transfer between warehouses nets to zero overall');
select t.eq((select closing_qty from report_product_movement(:'org_id') where product_id = :'pa'), 45, 'A remaining = 100 − 60 + 5');
select t.eq((select opening_qty from report_product_movement(:'org_id') where product_id = :'pa'), 0, 'no opening balance when no start date is given');
select t.eq((select units_per_carton from report_product_movement(:'org_id') where product_id = :'pa'), 12, 'carton size is returned');

-- the ledger agrees with the stock tables for every product (the report is only as good as this)
select t.eq((select count(*) from (
  select p.id, coalesce((select sum(quantity) from inventory_stock s where s.product_id = p.id), 0) as on_hand
  from products p where p.organization_id = :'org_id') x
  join report_product_movement(:'org_id') r on r.product_id = x.id
  where abs(r.closing_qty - x.on_hand) > 0.0005), 0, 'closing quantity = stock on hand for every product');

-- one warehouse: the transfer shows up as "other"
select t.eq((select other_net_qty from report_product_movement(:'org_id', null, null, :'w1') where product_id = :'pa'), -10, 'warehouse 1: transfer out is -10');
select t.eq((select closing_qty from report_product_movement(:'org_id', null, null, :'w2') where product_id = :'pa'), 10, 'warehouse 2 closing = 10');

-- period boundaries: a window that starts tomorrow sees everything as opening balance
select t.eq((select opening_qty from report_product_movement(:'org_id', cairo_today() + 1, null) where product_id = :'pa'), 45, 'from tomorrow: opening = 45');
select t.eq((select sold_qty from report_product_movement(:'org_id', cairo_today() + 1, null) where product_id = :'pa'), 0, 'from tomorrow: nothing sold in the window');
select t.eq((select closing_qty from report_product_movement(:'org_id', null, cairo_today() - 1) where product_id = :'pa'), 0, 'up to yesterday: nothing existed yet');
-- identity: opening + in − out + other = closing
select t.eq((select count(*) from report_product_movement(:'org_id', cairo_today(), cairo_today()) r
             where abs(r.opening_qty + r.purchased_qty + r.sale_returned_qty - r.sold_qty - r.purchase_returned_qty + r.other_net_qty - r.closing_qty) > 0.0005), 0, 'opening + purchased + returned − sold − returned out + other = closing');

-- ranking: B sold 20, A net 55, C sold 5, ... best seller first
select t.eq((select sales_rank from report_product_movement(:'org_id') where product_id = :'pa'), 1, 'A is the best seller (net 55)');
select t.eq((select sales_rank from report_product_movement(:'org_id') where product_id = :'pb'), 2, 'B is second (20)');
select t.eq((select sales_rank from report_product_movement(:'org_id') where product_id = :'pc'), 3, 'C is third (5)');
select t.eq((select count(*) from report_product_movement(:'org_id') where product_id = :'pd'), 0, 'inactive products are not in the report');
-- a product that never sold ranks last (the "least sold" list must include zero-sales items)
insert into products (organization_id, name, sku, unit) values (:'org_id', 'راكد', 'DEAD', 'قطعة') returning id as pz \gset
select t.eq((select net_sold_qty from report_product_movement(:'org_id') where product_id = :'pz'), 0, 'a never-sold product appears with 0');
select t.eq((select sales_rank from report_product_movement(:'org_id') where product_id = :'pz'), 4, 'and ranks last');

-- ---------- access control ----------
select t.as_user('94000000-0000-0000-0000-000000000002');
select t.throws(format('select * from report_reorder(%L)', :'org_id'), 'لست عضوًا', 'another organization cannot read the reorder report');
select t.throws(format('select * from report_product_movement(%L)', :'org_id'), 'لست عضوًا', 'another organization cannot read the movement report');
select t.eq((select count(*) from report_reorder(:'orgb_id')), 0, 'own (empty) organization works');
select t.as_anon();
select t.throws(format('select * from report_reorder(%L)', :'org_id'), 'permission denied', 'anonymous callers cannot run the reorder report');
select t.throws(format('select * from report_product_movement(%L)', :'org_id'), 'permission denied', 'anonymous callers cannot run the movement report');
select t.as_owner();
