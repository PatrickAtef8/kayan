-- Reports package, Phase 3: stock count (جرد) workflow.
\set ON_ERROR_STOP on
select t.as_owner();
-- a fingerprint of everything a count must NOT touch before approval
create or replace function t.inv_fp(p_org uuid) returns text language sql as $$
  select md5(
    coalesce((select string_agg(x::text, '|' order by x::text) from inventory_stock x where organization_id = p_org), '') || '#' ||
    coalesce((select string_agg(x::text, '|' order by x::text) from stock_batches x where organization_id = p_org), '') || '#' ||
    coalesce((select string_agg(x::text, '|' order by x::text) from inventory_movements x where organization_id = p_org), '') || '#' ||
    coalesce((select string_agg(sc::text, '|' order by sc::text) from stock_costs sc join inventory_stock s on s.id = sc.stock_id where s.organization_id = p_org), '')) $$;
grant execute on function t.inv_fp(uuid) to authenticated;
create or replace function t.drift3(p_org uuid) returns bigint language sql as $$
  select count(*) from (
    select s.quantity as stock, coalesce((select sum(b.quantity) from stock_batches b where b.product_id = s.product_id and b.warehouse_id = s.warehouse_id), 0) as batches
    from inventory_stock s where s.organization_id = p_org) x where abs(x.stock - x.batches) > 0.0005 $$;
grant execute on function t.drift3(uuid) to authenticated;

insert into auth.users (id, email) values
  ('97000000-0000-0000-0000-000000000001', 'owner@st97.test'),
  ('97000000-0000-0000-0000-000000000002', 'other@st97.test'),
  ('97000000-0000-0000-0000-000000000003', 'keeper@st97.test'),
  ('97000000-0000-0000-0000-000000000004', 'rep@st97.test');
select t.as_user('97000000-0000-0000-0000-000000000001');
select create_organization('شركة الجرد', 'تجارة', 'EG', 'EGP', 'ar',
  array['sales','customers','inventory','purchases','suppliers','expenses','treasury']) as id \gset org_
select t.as_user('97000000-0000-0000-0000-000000000002');
select create_organization('شركة أخرى', 'تجارة', 'EG', 'EGP', 'ar', array['sales','inventory']) as id \gset orgb_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', '97000000-0000-0000-0000-000000000003', r.id, 'active' from roles r where r.key = 'warehouse' and r.organization_id is null;
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', '97000000-0000-0000-0000-000000000004', r.id, 'active' from roles r where r.key = 'sales' and r.organization_id is null;

select t.as_user('97000000-0000-0000-0000-000000000001');
insert into warehouses (organization_id, name) values (:'org_id', 'الرئيسي') returning id as w1 \gset
insert into warehouses (organization_id, name) values (:'org_id', 'الفرعي') returning id as w2 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as sup \gset
insert into customers (organization_id, name) values (:'org_id', 'عميل') returning id as cus \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'أ', 'A', 'قطعة') returning id as pa \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'ب', 'B', 'قطعة') returning id as pb \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'ج', 'C', 'قطعة') returning id as pc \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'د', 'D', 'قطعة') returning id as pd \gset
insert into product_prices (organization_id, product_id, selling_price) select :'org_id', id, 100 from products where organization_id = :'org_id';
insert into product_costs (product_id, organization_id, cost) values (:'pd', :'org_id', 3);   -- D has never been bought: only a product cost

-- A: batch +30d (10 @4) and batch +90d (20 @7) → average cost 6 | B: undated 8 @10 | C: +60d 5 @2
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'ST-P1', cairo_today(),
  jsonb_build_array(
    jsonb_build_object('product_id', :'pa', 'quantity', 10, 'unit_cost', 4, 'discount_pct', 0, 'expiry_date', (cairo_today() + 30)::text),
    jsonb_build_object('product_id', :'pa', 'quantity', 20, 'unit_cost', 7, 'discount_pct', 0, 'expiry_date', (cairo_today() + 90)::text),
    jsonb_build_object('product_id', :'pb', 'quantity', 8,  'unit_cost', 10, 'discount_pct', 0),
    jsonb_build_object('product_id', :'pc', 'quantity', 5,  'unit_cost', 2, 'discount_pct', 0, 'expiry_date', (cairo_today() + 60)::text)),
  0, 0, 0, null, null, 0) as id \gset p1_
select id as ba1 from stock_batches where product_id = :'pa' and expiry_date = cairo_today() + 30 \gset
select id as ba2 from stock_batches where product_id = :'pa' and expiry_date = cairo_today() + 90 \gset
select id as bb1 from stock_batches where product_id = :'pb' \gset
select id as bc1 from stock_batches where product_id = :'pc' \gset
select t.eq((select avg_cost from stock_costs sc join inventory_stock s on s.id = sc.stock_id where s.product_id = :'pa' and s.warehouse_id = :'w1'), 6, 'setup: A average cost = 6');

-- =====================================================================
-- 1. Start / count / review change NOTHING in inventory
-- =====================================================================
select t.inv_fp(:'org_id') as fp0 \gset
select start_stocktake(:'org_id', :'w1', 'جرد نهاية الشهر') as id \gset st_
select t.eq((select count(*) from stocktake_lines where stocktake_id = :'st_id'), 4, 'start: one line per system batch (A×2, B, C)');
select t.eq_text((select status from stocktakes where id = :'st_id'), 'counting', 'start: status is counting');
select t.eq((select system_qty from stocktake_lines where stocktake_id = :'st_id' and batch_id = :'ba2'), 20, 'start: system quantity is snapshotted per batch');
select t.eq((select count(*) from stocktake_lines where stocktake_id = :'st_id' and counted_qty is not null), 0, 'start: nothing counted yet');
select t.eq_text(t.inv_fp(:'org_id'), :'fp0', 'start changed nothing (stock, batches, costs, movements)');
select t.throws(format('select start_stocktake(%L, %L)', :'org_id', :'w1'), 'جرد مفتوح', 'a second open count on the same warehouse is refused');
select start_stocktake(:'org_id', :'w2') as id \gset stw2_
select t.eq((select count(*) from stocktake_lines where stocktake_id = :'stw2_id'), 0, 'another warehouse can have its own (empty) count');
select cancel_stocktake(:'org_id', :'stw2_id');

-- the sheet: A1 counted 12 (+2), A2 counted 17 (−3 on the LATER batch), B matches, C not counted yet
select id as la1 from stocktake_lines where stocktake_id = :'st_id' and batch_id = :'ba1' \gset
select id as la2 from stocktake_lines where stocktake_id = :'st_id' and batch_id = :'ba2' \gset
select id as lb1 from stocktake_lines where stocktake_id = :'st_id' and batch_id = :'bb1' \gset
select id as lc1 from stocktake_lines where stocktake_id = :'st_id' and batch_id = :'bc1' \gset
select save_stocktake_counts(:'org_id', :'st_id', jsonb_build_array(
  jsonb_build_object('line_id', :'la1', 'counted_qty', 12),
  jsonb_build_object('line_id', :'la2', 'counted_qty', 17),
  jsonb_build_object('line_id', :'lb1', 'counted_qty', 8))) as n \gset
select t.eq(:n, 3, 'save: three lines recorded');
-- found stock: 4 more of A with a NEW expiry date, and 6 of D (not in the system at all)
select add_stocktake_found(:'org_id', :'st_id', :'pa', (cairo_today() + 200)::date, 4) as id \gset lfa_
select add_stocktake_found(:'org_id', :'st_id', :'pd', (cairo_today() + 120)::date, 6) as id \gset lfd_
select t.eq((select count(*) from stocktake_lines where stocktake_id = :'st_id'), 6, 'found stock adds lines (6 in total)');
select t.eq_text(t.inv_fp(:'org_id'), :'fp0', 'counting + found stock changed nothing in inventory');

-- review, as the owner (sees costs)
select stocktake_summary(:'org_id', :'st_id') as sm \gset
select t.eq((:'sm'::jsonb->>'counted')::int, 5, 'review: 5 lines counted');
select t.eq((:'sm'::jsonb->>'uncounted')::int, 1, 'review: 1 line not counted (C)');
select t.eq((:'sm'::jsonb->>'shortage_qty')::numeric, 3, 'review: shortage 3 (on A2)');
select t.eq((:'sm'::jsonb->>'surplus_qty')::numeric, 12, 'review: surplus 2 + 4 + 6 = 12');
select t.eq((:'sm'::jsonb->>'shortage_value')::numeric, 18, 'review: shortage value 3 × 6 = 18');
select t.eq((:'sm'::jsonb->>'surplus_value')::numeric, 54, 'review: surplus value 2×6 + 4×6 + 6×3 (D falls back to its product cost) = 54');
select t.eq((:'sm'::jsonb->>'net_value')::numeric, 36, 'review: net financial impact +36');
select t.eq((:'sm'::jsonb->>'lines_without_cost')::int, 0, 'review: every variance has a cost');
select t.eq_text((:'sm'::jsonb->>'stale'), 'false', 'review: not stale yet');
select t.eq_text((select state from report_stocktake(:'org_id', :'st_id') where line_id = :'la2'), 'shortage', 'review: A2 is a shortage');
select t.eq((select variance from report_stocktake(:'org_id', :'st_id') where line_id = :'la2'), -3, 'review: variance = actual − system = −3');
select t.eq((select system_qty from report_stocktake(:'org_id', :'st_id') where line_id = :'la2'), 20, 'review: system quantity shown');
select t.eq((select counted_qty from report_stocktake(:'org_id', :'st_id') where line_id = :'la2'), 17, 'review: actual quantity shown');
select t.eq((select impact from report_stocktake(:'org_id', :'st_id') where line_id = :'la2'), -18, 'review: line impact −3 × 6');
select t.eq_text((select state from report_stocktake(:'org_id', :'st_id') where line_id = :'lc1'), 'uncounted', 'review: C is uncounted');
select t.eq_text((select state from report_stocktake(:'org_id', :'st_id') where line_id = :'lb1'), 'match', 'review: B matches');
select t.eq((select count(*) from report_stocktake(:'org_id', :'st_id') where is_found), 2, 'review: both found lines flagged');
select t.eq_text(t.inv_fp(:'org_id'), :'fp0', 'reviewing changed nothing');

-- the storekeeper can count, but sees no money and cannot approve
select t.as_user('97000000-0000-0000-0000-000000000003');
select stocktake_summary(:'org_id', :'st_id') as smk \gset
select t.eq_text((:'smk'::jsonb->>'costs_visible'), 'false', 'storekeeper: costs are hidden');
select t.ok((:'smk'::jsonb->>'net_value') is null and (:'smk'::jsonb->>'shortage_value') is null, 'storekeeper: no financial figures');
select t.eq((:'smk'::jsonb->>'shortage_qty')::numeric, 3, 'storekeeper: quantities are visible');
select t.ok((select bool_and(unit_cost is null and impact is null) from report_stocktake(:'org_id', :'st_id')), 'storekeeper: no line carries a cost');
select t.eq_text((:'smk'::jsonb->>'can_apply'), 'false', 'storekeeper: cannot apply');
select t.throws(format('select apply_stocktake(%L, %L)', :'org_id', :'st_id'), 'صلاحية اعتماد الجرد', 'storekeeper cannot approve');
select save_stocktake_counts(:'org_id', :'st_id', jsonb_build_array(jsonb_build_object('line_id', :'lc1', 'counted_qty', 5))) as n \gset
select t.eq(:n, 1, 'storekeeper can record counts');
-- back to "not counted"
select save_stocktake_counts(:'org_id', :'st_id', jsonb_build_array(jsonb_build_object('line_id', :'lc1', 'counted_qty', null))) as n \gset

-- =====================================================================
-- 2. Concurrent changes make the count stale — approval is refused
-- =====================================================================
select t.as_user('97000000-0000-0000-0000-000000000001');
-- (a) a sale of B after the count started
select create_sales_invoice(:'org_id', :'cus', :'w1', 'ST-S1', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 2, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset s1_
select t.inv_fp(:'org_id') as fp1 \gset
select t.throws(format('select apply_stocktake(%L, %L)', :'org_id', :'st_id'), 'تغيّر المخزون بعد بدء الجرد', 'a sale after the count started blocks approval');
select t.eq_text(t.inv_fp(:'org_id'), :'fp1', 'the refused approval changed nothing');
select t.eq_text((select status from stocktakes where id = :'st_id'), 'counting', 'the count is still open');
select t.eq((stocktake_summary(:'org_id', :'st_id')->>'stale_products')::int, 1, 'summary: 1 stale product (B)');
select t.eq_text((stocktake_summary(:'org_id', :'st_id')->>'can_apply'), 'false', 'summary: cannot apply while stale');
select t.ok((select stale from report_stocktake(:'org_id', :'st_id') where line_id = :'lb1'), 'review flags the stale line');
select t.ok(not (select stale from report_stocktake(:'org_id', :'st_id') where line_id = :'la1'), 'and not the untouched ones');

-- (b) a movement that nets to zero is still a change: buy 5 of A, return the same 5
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'ST-P2', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 5, 'unit_cost', 6, 'discount_pct', 0, 'expiry_date', (cairo_today() + 30)::text)), 0, 0, 0, null, null, 0) as id \gset p2_
select create_purchase_return(:'org_id', :'p2_id', cairo_today(),
  jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', (select id from purchase_invoice_items where purchase_invoice_id = :'p2_id'), 'quantity', 5)), 0, null) as id \gset pr2_
select t.eq((select sum(quantity) from stock_batches where product_id = :'pa'), 30, 'setup: A is back to 30 units, same batches');
select t.eq((select count(*) from stocktake_stale(:'st_id') where product_id = :'pa' and reason = 'movement'), 1, 'a buy-then-return that nets to zero is still detected (movement)');
select t.eq((stocktake_summary(:'org_id', :'st_id')->>'stale_products')::int, 2, 'summary: A and B are stale');
select t.throws(format('select apply_stocktake(%L, %L)', :'org_id', :'st_id'), 'تغيّر المخزون بعد بدء الجرد \(2 صنف\)', 'approval refused, naming the number of affected products');

-- reconcile (as the storekeeper — counting permission is enough)
select t.as_user('97000000-0000-0000-0000-000000000003');
select reconcile_stocktake(:'org_id', :'st_id') as rc \gset
select t.eq((:'rc'::jsonb->>'stale_products')::int, 2, 'reconcile: 2 products refreshed');
select t.eq((stocktake_summary(:'org_id', :'st_id')->>'stale_products')::int, 0, 'reconcile: nothing is stale any more');
select t.eq((select system_qty from stocktake_lines where id = :'lb1'), 6, 'reconcile: B now shows today''s system quantity (8 − 2)');
select t.ok((select counted_qty from stocktake_lines where id = :'lb1') is null, 'reconcile: B must be recounted');
select t.ok((select counted_qty from stocktake_lines where id = :'la1') is null and (select counted_qty from stocktake_lines where id = :'la2') is null, 'reconcile: A''s batches must be recounted');
select t.ok((select counted_qty from stocktake_lines where id = :'lfa_id') is null, 'reconcile: found stock of an affected product must be re-confirmed');
select t.eq((select counted_qty from stocktake_lines where id = :'lfd_id'), 6, 'reconcile: an untouched product (D) keeps its count');
select t.eq((reconcile_stocktake(:'org_id', :'st_id')->>'stale_products')::int, 0, 'reconcile with nothing stale is a no-op');
-- recount what was reset
select save_stocktake_counts(:'org_id', :'st_id', jsonb_build_array(
  jsonb_build_object('line_id', :'la1', 'counted_qty', 12),
  jsonb_build_object('line_id', :'la2', 'counted_qty', 17),
  jsonb_build_object('line_id', :'lb1', 'counted_qty', 6),
  jsonb_build_object('line_id', :'lfa_id', 'counted_qty', 4))) as n \gset

-- =====================================================================
-- 3. Approval — the only step that changes inventory
-- =====================================================================
select t.as_user('97000000-0000-0000-0000-000000000001');
select t.eq_text((stocktake_summary(:'org_id', :'st_id')->>'can_apply'), 'true', 'owner: can apply once fresh');
select t.inv_fp(:'org_id') as fp2 \gset
select (select count(*) from inventory_movements where organization_id = :'org_id') as mv0 \gset
select (select count(*) from audit_logs where organization_id = :'org_id' and entity = 'inventory_adjustment') as au0 \gset
select apply_stocktake(:'org_id', :'st_id') as applied \gset
select t.eq(:applied, 4, 'approval: 4 adjustments (A1 +2, A2 −3, found A +4, found D +6; B matches, C not counted)');
select t.eq_text((select status from stocktakes where id = :'st_id'), 'applied', 'approval: count is closed');
-- batch-specific: the shortage came out of A2 (later expiry) although A1 expires first
select t.eq((select quantity from stock_batches where id = :'ba2'), 17, 'shortage −3 came out of A2 itself');
select t.eq((select quantity from stock_batches where id = :'ba1'), 12, 'surplus +2 went into A1 itself (same batch row, A1 was not drained by FEFO)');
select t.eq((select count(*) from stock_batches where product_id = :'pa'), 3, 'A has three batches: A1, A2 and the found one');
select t.eq((select quantity from stock_batches where product_id = :'pa' and expiry_date = cairo_today() + 200), 4, 'found A: new batch with the expiry date that was entered');
select t.eq((select count(*) from stock_batches where product_id = :'pa' and expiry_date = cairo_today() + 200 and purchase_invoice_id is null), 1, 'found A: not tied to any purchase invoice');
select t.eq((select quantity from stock_batches where product_id = :'pd' and warehouse_id = :'w1'), 6, 'found D: stock created in the warehouse');
select t.eq((select expiry_date - cairo_today() from stock_batches where product_id = :'pd'), 120, 'found D: with its expiry date');
select t.eq((select quantity from inventory_stock where product_id = :'pa' and warehouse_id = :'w1'), 33, 'A on hand = 12 + 17 + 4');
select t.eq((select quantity from stock_batches where id = :'bc1'), 5, 'C (not counted) is untouched');
select t.eq((select quantity from stock_batches where id = :'bb1'), 6, 'B (matched) is untouched');
select t.eq(t.drift3(:'org_id'), 0, 'batches still add up to the stock for every product');
-- movements, costing and audit
select t.eq((select count(*) from inventory_movements where organization_id = :'org_id') - :mv0, 4, 'approval wrote exactly 4 movements');
select t.eq((select count(*) from inventory_movements where reference_type = 'stocktake' and reference_id = :'st_id' and movement_type = 'adjustment'), 4, 'all are adjustments tagged stocktake');
select t.eq((select sum(quantity_delta) from inventory_movements where reference_type = 'stocktake' and reference_id = :'st_id'), 9, 'net movement = +2 −3 +4 +6');
select t.eq((select avg_cost from stock_costs sc join inventory_stock s on s.id = sc.stock_id where s.product_id = :'pa' and s.warehouse_id = :'w1'), 6, 'costing preserved: A''s average cost is still 6');
select t.eq((select count(*) from inventory_movement_costs c join inventory_movements m on m.id = c.movement_id where m.reference_id = :'st_id' and m.product_id = :'pa' and c.unit_cost = 6), 3, 'each A movement carries the average cost (kept in the protected cost table)');
select t.eq((select count(*) from audit_logs where organization_id = :'org_id' and entity = 'inventory_adjustment') - :au0, 4, 'audit: each adjustment is audited by the existing trigger');
select t.eq((select count(*) from audit_logs where entity = 'stocktake' and entity_id = :'st_id' and action = 'stocktake.created'), 1, 'audit: the count''s creation is logged');
select t.ok((select count(*) from audit_logs where entity = 'stocktake' and entity_id = :'st_id' and action = 'stocktake.updated' and after_data->>'status' = 'applied') = 1, 'audit: the approval (status → applied) is logged');
select t.eq((select applied_variance from stocktake_lines where id = :'la2'), -3, 'the applied variance is recorded on the line');
select t.eq((select count(*) from stocktake_lines where stocktake_id = :'st_id' and counted_qty is not null and applied_variance is null), 0, 'every counted line records its applied variance');
-- it cannot be approved twice or edited afterwards
select t.throws(format('select apply_stocktake(%L, %L)', :'org_id', :'st_id'), 'تم اعتماد هذا الجرد أو إلغاؤه', 'a second approval is refused');
select t.eq((select count(*) from inventory_movements where organization_id = :'org_id') - :mv0, 4, 'and no movements were duplicated');
select t.throws(format('select save_stocktake_counts(%L, %L, %L::jsonb)', :'org_id', :'st_id', jsonb_build_array(jsonb_build_object('line_id', :'la1', 'counted_qty', 1))), 'تم اعتماد هذا الجرد', 'an approved count can no longer be edited');
select t.throws(format('select cancel_stocktake(%L, %L)', :'org_id', :'st_id'), 'تم اعتماد هذا الجرد', 'nor cancelled');
select t.throws(format('select reconcile_stocktake(%L, %L)', :'org_id', :'st_id'), 'تم اعتماد هذا الجرد', 'nor reconciled');
select t.eq((stocktake_summary(:'org_id', :'st_id')->>'stale_products')::int, 0, 'a closed count is never "stale"');

-- =====================================================================
-- 4. Second count: new batches / vanished batches (all three stale reasons) + cancel
-- =====================================================================
select start_stocktake(:'org_id', :'w1') as id \gset st2_
select t.eq((select count(*) from stocktake_lines where stocktake_id = :'st2_id'), 6, 'second count sees the new reality (A×3, B, C, D)');
-- a new batch of C arrives, and the counted C batch is sold out
select create_purchase_invoice(:'org_id', :'sup', :'w1', 'ST-P3', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pc', 'quantity', 9, 'unit_cost', 2, 'discount_pct', 0, 'expiry_date', (cairo_today() + 200)::text)), 0, 0, 0, null, null, 0) as id \gset p3_
select create_sales_invoice(:'org_id', :'cus', :'w1', 'ST-S2', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pc', 'quantity', 5, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset s2_
select t.eq((select count(*) from stocktake_stale(:'st2_id') where product_id = :'pc'), 3, 'C is flagged for all three reasons (movement, batch_changed, new_batch)');
select t.eq((select count(*) from stocktake_stale(:'st2_id') where product_id = :'pc' and reason = 'new_batch'), 1, 'a batch the count never saw is detected');
select t.eq((select count(*) from stocktake_stale(:'st2_id') where product_id = :'pc' and reason = 'batch_changed'), 1, 'a counted batch that disappeared is detected');
select reconcile_stocktake(:'org_id', :'st2_id') as rc2 \gset
select t.eq((:'rc2'::jsonb->>'removed_lines')::int, 1, 'reconcile: the sold-out batch line is dropped');
select t.eq((:'rc2'::jsonb->>'added_lines')::int, 1, 'reconcile: the new batch is added for counting');
select t.eq((select count(*) from stocktake_lines where stocktake_id = :'st2_id' and product_id = :'pc'), 1, 'reconcile: C now has exactly its current batch');
select t.inv_fp(:'org_id') as fp3 \gset
select cancel_stocktake(:'org_id', :'st2_id');
select t.eq_text((select status from stocktakes where id = :'st2_id'), 'cancelled', 'cancel: status cancelled');
select t.eq_text(t.inv_fp(:'org_id'), :'fp3', 'cancel changed nothing in inventory');
select t.throws(format('select apply_stocktake(%L, %L)', :'org_id', :'st2_id'), 'تم اعتماد هذا الجرد أو إلغاؤه', 'a cancelled count cannot be approved');
select t.eq((select count(*) from audit_logs where entity = 'stocktake' and entity_id = :'st2_id' and after_data->>'status' = 'cancelled'), 1, 'audit: cancellation logged');

-- =====================================================================
-- 5. Validation
-- =====================================================================
select start_stocktake(:'org_id', :'w1') as id \gset st3_
select id as l3 from stocktake_lines where stocktake_id = :'st3_id' and product_id = :'pb' \gset
select t.throws(format('select save_stocktake_counts(%L, %L, %L::jsonb)', :'org_id', :'st3_id', jsonb_build_array(jsonb_build_object('line_id', :'l3', 'counted_qty', -1))), 'صفرًا أو أكثر', 'negative actual quantity refused');
select t.throws(format('select save_stocktake_counts(%L, %L, %L::jsonb)', :'org_id', :'st3_id', jsonb_build_array(jsonb_build_object('line_id', :'l3', 'counted_qty', 1000000000000))), 'صفرًا أو أكثر', 'absurd actual quantity refused');
select t.throws(format('select save_stocktake_counts(%L, %L, %L::jsonb)', :'org_id', :'st3_id', jsonb_build_array(jsonb_build_object('line_id', :'l3', 'counted_qty', 'abc'))), 'الكمية الفعلية غير صحيحة', 'garbage quantity refused');
select t.throws(format('select save_stocktake_counts(%L, %L, %L::jsonb)', :'org_id', :'st3_id', jsonb_build_array(jsonb_build_object('line_id', :'la1', 'counted_qty', 1))), 'غير موجود في هذا الجرد', 'a line of another count is refused');
select t.throws(format('select add_stocktake_found(%L, %L, %L, null, 0)', :'org_id', :'st3_id', :'pa'), 'أكبر من صفر', 'found quantity must be positive');
select t.throws(format('select add_stocktake_found(%L, %L, %L, date ''1990-01-01'', 1)', :'org_id', :'st3_id', :'pa'), 'تاريخ الصلاحية غير صحيح', 'implausible found expiry refused');
select t.throws(format('select add_stocktake_found(%L, %L, gen_random_uuid(), null, 1)', :'org_id', :'st3_id'), 'غير موجود', 'unknown product refused');
select t.throws(format('select apply_stocktake(%L, %L)', :'org_id', :'st3_id'), 'لم تُسجَّل أي كمية', 'approving a count with nothing counted is refused');
-- a found line can be removed again; a counted-to-zero batch is a full shortage
select add_stocktake_found(:'org_id', :'st3_id', :'pa', null, 2) as id \gset lf3_
select remove_stocktake_found(:'org_id', :'lf3_id');
select t.eq((select count(*) from stocktake_lines where id = :'lf3_id'), 0, 'a found line can be removed');
select t.throws(format('select remove_stocktake_found(%L, %L)', :'org_id', :'l3'), 'سطر الجرد غير موجود', 'a system-batch line cannot be removed');
select save_stocktake_counts(:'org_id', :'st3_id', jsonb_build_array(jsonb_build_object('line_id', :'l3', 'counted_qty', 0))) as n \gset
select apply_stocktake(:'org_id', :'st3_id') as ap3 \gset
select t.eq(:ap3, 1, 'counting a batch as 0 is a full-batch shortage');
select t.eq((select count(*) from stock_batches where product_id = :'pb'), 0, 'the batch is gone');
select t.eq((select quantity from inventory_stock where product_id = :'pb' and warehouse_id = :'w1'), 0, 'and so is the stock');
select t.eq(t.drift3(:'org_id'), 0, 'consistent after the full-batch shortage');

-- =====================================================================
-- 6. Access control
-- =====================================================================
select start_stocktake(:'org_id', :'w1') as id \gset st4_
select t.as_user('97000000-0000-0000-0000-000000000004');   -- sales rep: no inventory permission
select t.throws(format('select start_stocktake(%L, %L)', :'org_id', :'w2'), 'صلاحية تسوية المخزون', 'a rep cannot start a count');
select t.throws(format('select save_stocktake_counts(%L, %L, ''[]''::jsonb)', :'org_id', :'st4_id'), 'صلاحية تسوية المخزون', 'a rep cannot record counts');
select t.throws(format('select cancel_stocktake(%L, %L)', :'org_id', :'st4_id'), 'صلاحية تسوية المخزون', 'a rep cannot cancel');
select t.throws(format('select apply_stocktake(%L, %L)', :'org_id', :'st4_id'), 'صلاحية اعتماد الجرد', 'a rep cannot approve');
select t.as_user('97000000-0000-0000-0000-000000000002');   -- another organization
select t.throws(format('select start_stocktake(%L, %L)', :'org_id', :'w1'), 'لست عضوًا', 'another organization cannot start a count here');
select t.throws(format('select apply_stocktake(%L, %L)', :'org_id', :'st4_id'), 'لست عضوًا', 'nor approve');
select t.throws(format('select stocktake_summary(%L, %L)', :'orgb_id', :'st4_id'), 'الجرد غير موجود', 'nor read a count through its own organization id');
select t.eq((select count(*) from stocktakes where organization_id = :'org_id'), 0, 'nor list my counts');
select t.eq((select count(*) from stocktake_lines where organization_id = :'org_id'), 0, 'nor my count lines');
select t.as_user('97000000-0000-0000-0000-000000000001');
select t.throws(format($q$insert into stocktakes (organization_id, warehouse_id) values (%L, %L)$q$, :'org_id', :'w2'), 'permission denied', 'nobody can write counts directly (not even the owner)');
select t.throws(format($q$update stocktake_lines set counted_qty = 999 where stocktake_id = %L$q$, :'st4_id'), 'permission denied', 'nor edit lines directly');
select t.throws(format($q$update stocktakes set status = 'applied' where id = %L$q$, :'st4_id'), 'permission denied', 'nor flip a status directly');
select t.throws(format($q$select _stocktake_post(%L, %L, %L, 5, 'x', null, null, null, %L)$q$, :'org_id', :'pa', :'w1', :'st4_id'), 'permission denied', 'the internal adjustment helper is not callable');
select t.as_anon();
select t.throws(format('select start_stocktake(%L, %L)', :'org_id', :'w1'), 'permission denied', 'anonymous callers cannot start a count');
select t.throws(format('select stocktake_summary(%L, %L)', :'org_id', :'st4_id'), 'permission denied', 'nor read one');
select t.as_owner();

-- =====================================================================
-- 7. Costing consistency: a stock count must cost its adjustments exactly like adjust_inventory_stock
-- =====================================================================
select t.as_user('97000000-0000-0000-0000-000000000001');
insert into products (organization_id, name, sku, unit) values (:'org_id', 'T1', 'T1', 'قطعة') returning id as pt1 \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'T2', 'T2', 'قطعة') returning id as pt2 \gset
insert into product_prices (organization_id, product_id, selling_price) select :'org_id', id, 100 from products where id in (:'pt1', :'pt2');
-- identical history for both: 10 @ 8, then 10 @ 12 → weighted average cost 10
select create_purchase_invoice(:'org_id', :'sup', :'w2', 'ST-T1', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pt1', 'quantity', 10, 'unit_cost', 8, 'discount_pct', 0, 'expiry_date', (cairo_today() + 40)::text),
                    jsonb_build_object('product_id', :'pt2', 'quantity', 10, 'unit_cost', 8, 'discount_pct', 0, 'expiry_date', (cairo_today() + 40)::text)), 0, 0, 0, null, null, 0) as id \gset pt_a_
select create_purchase_invoice(:'org_id', :'sup', :'w2', 'ST-T2', cairo_today(),
  jsonb_build_array(jsonb_build_object('product_id', :'pt1', 'quantity', 10, 'unit_cost', 12, 'discount_pct', 0, 'expiry_date', (cairo_today() + 40)::text),
                    jsonb_build_object('product_id', :'pt2', 'quantity', 10, 'unit_cost', 12, 'discount_pct', 0, 'expiry_date', (cairo_today() + 40)::text)), 0, 0, 0, null, null, 0) as id \gset pt_b_
select t.eq((select avg_cost from stock_costs sc join inventory_stock s on s.id = sc.stock_id where s.product_id = :'pt2' and s.warehouse_id = :'w2'), 10, 'setup: both twins have average cost 10');

-- T1 goes through the existing adjustment function: −4 (a shortage), +7 (a surplus) = net +3
select adjust_inventory_stock(:'org_id', :'pt1', :'w2', -4, 'تسوية يدوية') as id \gset adjt1a_
select adjust_inventory_stock(:'org_id', :'pt1', :'w2', 7, 'تسوية يدوية') as id \gset adjt1b_
-- T2 goes through a stock count that arrives at the same quantity (23 = 20 + 3), as a shortage and a surplus line
select start_stocktake(:'org_id', :'w2') as id \gset stc_
-- (T2 has two batches, one per purchase invoice; the shortage is counted on the first one: 10 → 6)
select id as lt2 from stocktake_lines where stocktake_id = :'stc_id' and product_id = :'pt2' and purchase_invoice_id = :'pt_a_id' \gset
select save_stocktake_counts(:'org_id', :'stc_id', jsonb_build_array(jsonb_build_object('line_id', :'lt2', 'counted_qty', 6))) as n \gset
select add_stocktake_found(:'org_id', :'stc_id', :'pt2', (cairo_today() + 40)::date, 7) as id \gset lft2_
-- (a found line for a product that already has a batch: shortage 4 on the system batch, surplus 7 as found stock)
select apply_stocktake(:'org_id', :'stc_id') as ap \gset
select t.eq((select quantity from inventory_stock where product_id = :'pt2' and warehouse_id = :'w2'), 23, 'twin 2 ends at 23');
select t.eq((select quantity from inventory_stock where product_id = :'pt1' and warehouse_id = :'w2'), 23, 'twin 1 ends at 23');
select t.eq(
  (select avg_cost from stock_costs sc join inventory_stock s on s.id = sc.stock_id where s.product_id = :'pt2' and s.warehouse_id = :'w2'),
  (select avg_cost from stock_costs sc join inventory_stock s on s.id = sc.stock_id where s.product_id = :'pt1' and s.warehouse_id = :'w2'),
  'average cost after a count = average cost after the same adjustments');
select t.eq((select avg_cost from stock_costs sc join inventory_stock s on s.id = sc.stock_id where s.product_id = :'pt2' and s.warehouse_id = :'w2'), 10, 'and it is unchanged (10): adjustments never re-weight the cost');
select t.eq(
  (select quantity * avg_cost from inventory_stock s join stock_costs sc on sc.stock_id = s.id where s.product_id = :'pt2' and s.warehouse_id = :'w2'),
  (select quantity * avg_cost from inventory_stock s join stock_costs sc on sc.stock_id = s.id where s.product_id = :'pt1' and s.warehouse_id = :'w2'),
  'inventory value is identical');
-- every adjustment movement is valued at that average cost, whichever path made it
select t.eq((select count(*) from inventory_movements m join inventory_movement_costs c on c.movement_id = m.id
             where m.product_id = :'pt2' and m.reference_type = 'stocktake' and c.unit_cost = 10), 2, 'count movements carry the average cost (2 lines → 2 movements, both at 10)');
select t.eq((select count(*) from inventory_movements m join inventory_movement_costs c on c.movement_id = m.id
             where m.product_id = :'pt1' and m.reference_type = 'manual_adjustment' and c.unit_cost = 10), 2, 'manual adjustments carry the same cost');
select t.eq((select count(*) from inventory_movements where product_id = :'pt2' and movement_type = 'adjustment' and reference_type = 'stocktake'), 2, 'exactly the two stock-count movements');
select t.eq(t.drift3(:'org_id'), 0, 'batches == stock after the costing comparison');
-- the review's estimate used the same cost: variance × average cost
select t.eq((select impact from report_stocktake(:'org_id', :'stc_id') where line_id = :'lt2'), -40, 'review estimate for the shortage line = −4 × 10');
select t.eq((select impact from report_stocktake(:'org_id', :'stc_id') where line_id = :'lft2_id'), 70, 'review estimate for the surplus line = +7 × 10');
select t.as_owner();
