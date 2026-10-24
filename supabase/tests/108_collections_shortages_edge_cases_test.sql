-- 0052: edge cases for collections and stock-shortage reports (sequential checks; the lock behaviour itself is proven by
-- supabase/tests/concurrency_collections_check.sh, which runs real parallel sessions).
--
-- COLLECTIONS  partial -> full payment keeps invoice balance / treasury / commission / owner + rep notifications in step ·
--   never more than what remains (also after rounding) · rep: own customers only (another rep's customer, no rep record,
--   deactivated rep, storekeeper all refused) · no direct table writes.
-- SHORTAGES    live remaining shortage (needed − sellable − coming) · duplicate purchase refused unless confirmed, a
--   legitimate additional purchase needs no confirmation · partial receipt · cancelled purchase (report follows) ·
--   stock added exactly once · auto-close only when SELLABLE stock covers the need · manual "provided from another
--   source" refused unless sellable stock covers (reserved stock does not count) · rep never sees purchase figures.

\set ON_ERROR_STOP on
select t.autoconfirm_off();

\set own '10800000-0000-0000-0000-000000000001'
\set kp  '10800000-0000-0000-0000-000000000002'
\set rp1 '10800000-0000-0000-0000-000000000003'
\set rp2 '10800000-0000-0000-0000-000000000004'
\set rp3 '10800000-0000-0000-0000-000000000005'

select t.as_owner();
insert into auth.users (id, email) values (:'own', 'owner@e8.test'), (:'kp', 'keeper@e8.test'), (:'rp1', 'rep1@e8.test'), (:'rp2', 'rep2@e8.test'), (:'rp3', 'rep3@e8.test');
select t.as_user(:'own');
select create_organization('شركة الحالات الحدية', 'x', 'EG', 'EGP', 'ar',
  array['products','warehouses','customers','suppliers','sales','purchases','inventory','representatives','treasury','reports']) as id \gset org_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', u.id, r.id, 'active'
from (values (:'kp'::uuid, 'warehouse'), (:'rp1'::uuid, 'sales'), (:'rp2'::uuid, 'sales'), (:'rp3'::uuid, 'sales')) u(id, k)
join roles r on r.key = u.k and r.organization_id is null;

select t.as_user(:'own');
insert into warehouses (organization_id, name) values (:'org_id', 'الرئيسي') returning id as w \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as s \gset
insert into products (organization_id, name, unit) values (:'org_id', 'صنف أ', 'قطعة') returning id as pa \gset
insert into products (organization_id, name, unit) values (:'org_id', 'صنف س', 'قطعة') returning id as ps \gset
insert into products (organization_id, name, unit) values (:'org_id', 'صنف ص', 'قطعة') returning id as pb \gset
insert into products (organization_id, name, unit) values (:'org_id', 'صنف ع', 'قطعة') returning id as pc \gset
insert into product_prices (organization_id, product_id, selling_price) select :'org_id', id, 100 from products where organization_id = :'org_id';
insert into product_costs (product_id, cost) select id, 5 from products where organization_id = :'org_id';
insert into sales_representatives (organization_id, name, user_id, commission_basis, commission_rate) values (:'org_id', 'مندوب 1', :'rp1', 'collected_amount', 10) returning id as rep1 \gset
insert into sales_representatives (organization_id, name, user_id, commission_basis, commission_rate) values (:'org_id', 'مندوب 2', :'rp2', 'net_sales', 5) returning id as rep2 \gset
insert into customers (organization_id, name, sales_rep_id) values (:'org_id', 'عميل 1', :'rep1') returning id as c1 \gset
insert into customers (organization_id, name, sales_rep_id) values (:'org_id', 'عميل 2', :'rep2') returning id as c2 \gset
insert into customers (organization_id, name) values (:'org_id', 'عميل بلا مندوب') returning id as c3 \gset

-- opening stock the old, auto-confirmed way: A 100, S 10
select t.as_owner();
select t.autoconfirm_on();
select t.as_user(:'own');
select create_purchase_invoice(:'org_id', :'s', :'w', 'OPEN', '2026-01-01', jsonb_build_array(
  jsonb_build_object('product_id', :'pa', 'quantity', 100, 'unit_cost', 5, 'discount_pct', 0),
  jsonb_build_object('product_id', :'ps', 'quantity', 10, 'unit_cost', 5, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset open_
select t.as_owner();
select t.autoconfirm_off();

-- ============================================================
-- 1. COLLECTIONS
-- ============================================================
select t.as_user(:'rp1');
select create_sales_invoice(:'org_id', :'c1', :'w', 'S-1', '2026-02-01',
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 10, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset s1_
select t.as_owner();
select t.eq((select total from sales_invoices where id = :'s1_id'), 1000::numeric, 'the invoice is worth 1000');
delete from notifications;

-- 1a. the rep collects 400
select t.as_user(:'rp1');
select record_customer_collection(:'org_id', :'c1', :'s1_id', 400, '2026-02-02', 'نقدًا', null, null) as id \gset k1_
select t.as_owner();
select t.eq((select amount_paid from sales_invoices where id = :'s1_id'), 400::numeric, 'invoice amount_paid = 400');
select t.eq_text((select payment_status from sales_invoices where id = :'s1_id'), 'partial', 'status = partial');
select t.eq(sales_invoice_remaining(:'s1_id'), 600::numeric, 'outstanding balance on the invoice = 600');
select t.eq((select amount from treasury_movements where source_type = 'customer_collection' and source_id = :'k1_id'), 400::numeric, 'one treasury movement of 400 tied to the collection');
select t.eq_text((select direction from treasury_movements where source_id = :'k1_id'), 'in', '... as an incoming movement');
select t.eq((select commission_amount from sales_invoices where id = :'s1_id'), 40::numeric, 'commission recomputed on the collected amount (10% of 400)');
select t.as_owner();
select t.eq((select count(*) from notifications where type = 'customer_payment' and recipient_user_id = :'own'), 1::bigint::numeric, 'the owner is notified of the rep''s collection');
select t.as_owner();
select t.eq((select (payload->>'amount')::numeric from notifications where type = 'customer_payment' and recipient_user_id = :'own'), 400::numeric, '... with the amount');
select t.as_owner();
select t.eq((select count(*) from notifications where type = 'rep_payment'), 0::numeric, 'the rep is not told about his own collection');

-- 1b. never more than what remains
select t.as_user(:'rp1');
select t.throws(format('select record_customer_collection(%L, %L, %L, 700, ''2026-02-03'', ''نقدًا'', null, null)', :'org_id', :'c1', :'s1_id'), 'أكبر من المتبقي', 'collecting 700 when 600 remains is refused');
select t.throws(format('select record_customer_collection(%L, %L, %L, 600.006, ''2026-02-03'', ''نقدًا'', null, null)', :'org_id', :'c1', :'s1_id'), 'أكبر من المتبقي', 'a sub-cent overshoot (600.006 rounds to 600.01) is measured on the rounded amount');
select t.throws(format('select record_customer_collection(%L, %L, %L, 0.004, ''2026-02-03'', ''نقدًا'', null, null)', :'org_id', :'c1', :'s1_id'), 'أكبر من صفر', 'an amount that rounds to 0.00 is refused');
select t.as_owner();
select t.eq((select amount_paid from sales_invoices where id = :'s1_id'), 400::numeric, 'refused attempts changed nothing');

-- 1c. who may collect
select t.as_user(:'rp2');
select t.throws(format('select record_customer_collection(%L, %L, %L, 10, ''2026-02-03'', ''نقدًا'', null, null)', :'org_id', :'c1', :'s1_id'), 'عملائك', 'rep 2 cannot collect from rep 1''s customer');
select t.throws(format('select record_customer_collection(%L, %L, null, 10, ''2026-02-03'', ''نقدًا'', null, null)', :'org_id', :'c3'), 'عملائك', 'nor from a customer nobody is assigned to');
select t.as_user(:'rp3');
select t.throws(format('select record_customer_collection(%L, %L, %L, 10, ''2026-02-03'', ''نقدًا'', null, null)', :'org_id', :'c1', :'s1_id'), 'غير مربوط', 'a sales user with no rep record is refused');
select t.as_user(:'kp');
select t.throws(format('select record_customer_collection(%L, %L, %L, 10, ''2026-02-03'', ''نقدًا'', null, null)', :'org_id', :'c1', :'s1_id'), 'صلاحية', 'a storekeeper is refused');
select t.as_user(:'rp1');
select t.throws('insert into customer_collections (organization_id, customer_id, amount, collection_date) values (''' || :'org_id' || ''', ''' || :'c1' || ''', 5, current_date)', 'permission denied', 'no direct write to the collections table');
select t.as_owner();
update sales_representatives set is_active = false where id = :'rep2';
select t.as_user(:'rp2');
select t.throws(format('select record_customer_collection(%L, %L, null, 10, ''2026-02-03'', ''نقدًا'', null, null)', :'org_id', :'c2'), 'مربوط', 'a deactivated rep can no longer collect');
select t.as_owner();
update sales_representatives set is_active = true where id = :'rep2';

-- 1d. the owner collects the rest: paid, commission, rep notified
select t.as_user(:'own');
select record_customer_collection(:'org_id', :'c1', :'s1_id', 600, '2026-02-05', 'نقدًا', null, null) as id \gset k2_
select t.as_owner();
select t.eq_text((select payment_status from sales_invoices where id = :'s1_id'), 'paid', 'fully paid');
select t.eq(sales_invoice_remaining(:'s1_id'), 0::numeric, 'nothing outstanding');
select t.eq((select commission_amount from sales_invoices where id = :'s1_id'), 100::numeric, 'commission follows the full collection (10% of 1000)');
select t.eq((select sum(amount) from treasury_movements where source_type = 'customer_collection' and source_id in (:'k1_id', :'k2_id')), 1000::numeric, 'treasury holds exactly the 1000 collected, no more');
select t.eq((select count(*) from treasury_movements where source_type = 'customer_collection' and source_id in (:'k1_id', :'k2_id')), 2::numeric, '... in two movements (one per payment)');
select t.as_owner();
select t.eq((select count(*) from notifications where type = 'rep_payment' and recipient_user_id = :'rp1'), 1::numeric, 'the rep is told when the OWNER collects from his customer');
select t.as_owner();
select t.eq((select count(*) from notifications where type = 'customer_payment' and recipient_user_id = :'own'), 1::numeric, 'the owner is not notified of his own collection (still just the rep''s one)');
select t.as_user(:'own');
select t.throws(format('select record_customer_collection(%L, %L, %L, 1, ''2026-02-06'', ''نقدًا'', null, null)', :'org_id', :'c1', :'s1_id'), 'أكبر من المتبقي', 'a paid invoice accepts nothing more');
select t.as_owner();

-- ============================================================
-- 2. SHORTAGE REPORTS
-- ============================================================
-- report: rep 1 needs 100 of S, 10 available
select t.as_user(:'rp1');
select (report_stock_shortage(:'org_id', :'ps', :'w', 100, null)->>'report_id') as r1 \gset
select t.as_user(:'own');
select t.eq((shortage_purchase_precheck(:'org_id', :'r1'::uuid)->>'remaining')::numeric, 90::numeric, 'precheck: nothing coming yet -> 90 still missing (100 needed, 10 available)');
select t.ok(not (shortage_purchase_precheck(:'org_id', :'r1'::uuid)->>'covered')::boolean, 'precheck: not covered');
select t.as_user(:'rp1');
select t.throws(format('select shortage_purchase_precheck(%L, %L)', :'org_id', :'r1'::uuid), 'ليس لديك صلاحية', 'a rep cannot call the owner precheck');

-- purchase A: 60 units (pending)
select t.as_user(:'own');
select create_purchase_invoice(:'org_id', :'s', :'w', 'PA', '2026-03-01', jsonb_build_array(jsonb_build_object('product_id', :'ps', 'quantity', 60, 'unit_cost', 5, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset pa_
select link_shortage_to_purchase(:'org_id', :'r1'::uuid, :'pa_id'::uuid);
select t.as_owner();
select t.eq_text((select status from stock_shortage_reports where id = :'r1'::uuid), 'in_progress', 'linking moves the report to «جاري التجهيز»');
select t.as_user(:'own');
select t.eq((select incoming_qty from list_stock_shortage_reports(:'org_id', 'open') where id = :'r1'::uuid), 60::numeric, 'owner list: 60 on the way');
select t.eq((select remaining_qty from list_stock_shortage_reports(:'org_id', 'open') where id = :'r1'::uuid), 30::numeric, 'owner list: remaining shortage 30 (100 - 10 - 60)');
select t.as_owner();
select t.ok((select owner_note like '%ما زال ينقص 30%' from stock_shortage_reports where id = :'r1'::uuid), 'the report note states what is still missing');
select t.as_user(:'own');
select t.as_user(:'rp1');
select t.ok((select incoming_qty is null and remaining_qty is null and current_available = 10 from list_stock_shortage_reports(:'org_id', 'open') where id = :'r1'::uuid), 'the rep sees only the stock available now, never purchase figures');

-- purchase B: 30 more — a LEGITIMATE additional purchase (60 coming + 10 = 70 < 100): no confirmation needed
select t.as_user(:'own');
select create_purchase_invoice(:'org_id', :'s', :'w', 'PB', '2026-03-02', jsonb_build_array(jsonb_build_object('product_id', :'ps', 'quantity', 30, 'unit_cost', 5, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset pb_
select link_shortage_to_purchase(:'org_id', :'r1'::uuid, :'pb_id'::uuid);
select t.as_owner();
select t.eq((select count(*) from stock_shortage_purchase_links where report_id = :'r1'::uuid), 2::numeric, 'a second purchase that does not yet cover the need links freely');
select t.as_user(:'own');
select t.ok((shortage_purchase_precheck(:'org_id', :'r1'::uuid)->>'covered')::boolean, 'precheck now says the need is covered by what is on its way');

-- purchase C: 20 more would be a DUPLICATE (10 + 60 + 30 = 100 already covers it)
select create_purchase_invoice(:'org_id', :'s', :'w', 'PC', '2026-03-03', jsonb_build_array(jsonb_build_object('product_id', :'ps', 'quantity', 20, 'unit_cost', 5, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset pc_
select t.throws(format('select link_shortage_to_purchase(%L, %L, %L)', :'org_id', :'r1'::uuid, :'pc_id'::uuid), 'يوجد بالفعل فاتورة شراء قائمة', 'a purchase that duplicates what is already coming is refused');
select t.as_owner();
select t.eq((select count(*) from stock_shortage_purchase_links where report_id = :'r1'::uuid), 2::numeric, '... and was not linked');
select t.as_user(:'own');
select link_shortage_to_purchase(:'org_id', :'r1'::uuid, :'pc_id'::uuid, true);
select t.as_owner();
select t.eq((select count(*) from stock_shortage_purchase_links where report_id = :'r1'::uuid), 3::numeric, 'with an explicit confirmation the extra purchase is linked');
select t.as_user(:'own');
select link_shortage_to_purchase(:'org_id', :'r1'::uuid, :'pc_id'::uuid);
select t.as_owner();
select t.eq((select count(*) from stock_shortage_purchase_links where report_id = :'r1'::uuid), 3::numeric, 're-linking the same invoice is harmless (no duplicate row, no error)');
select t.as_user(:'own');

-- the storekeeper receives A in full: stock +60 exactly once
select t.as_user(:'kp');
select t.eq((select quantity from inventory_stock where product_id = :'ps' and warehouse_id = :'w'), 10::numeric, 'before receiving: 10 on hand');
select confirm_purchase_receipt(:'org_id', :'pa_id'::uuid) as j \gset ra_
select t.eq((select quantity from inventory_stock where product_id = :'ps' and warehouse_id = :'w'), 70::numeric, 'receipt adds 60 -> 70');
select t.throws(format('select confirm_purchase_receipt(%L, %L)', :'org_id', :'pa_id'::uuid), 'تم استلام', 'receiving the same invoice again is refused');
select t.eq((select quantity from inventory_stock where product_id = :'ps' and warehouse_id = :'w'), 70::numeric, 'stock still 70: added exactly once');
select t.as_owner();
select t.as_owner();
select t.eq_text((select status from stock_shortage_reports where id = :'r1'::uuid), 'in_progress', '70 sellable < 100 needed: the report is NOT closed');
select t.as_user(:'own');
select t.eq((select incoming_qty from list_stock_shortage_reports(:'org_id', 'open') where id = :'r1'::uuid), 50::numeric, 'still coming: B 30 + C 20');
select t.eq((select remaining_qty from list_stock_shortage_reports(:'org_id', 'open') where id = :'r1'::uuid), 0::numeric, 'nothing more to order: 70 + 50 covers 100');

-- partial receipt of B: 10 of 30
select t.as_user(:'kp');
select confirm_purchase_receipt(:'org_id', :'pb_id'::uuid,
  jsonb_build_array(jsonb_build_object('line_id', (select (l->>'line_id') from warehouse_purchase_orders(:'org_id', 'open', null, 50, 0, :'pb_id'::uuid) o, jsonb_array_elements(o.lines) l limit 1), 'quantity', 10)), null) as j \gset rb_
select t.as_owner();
select t.eq((select quantity from inventory_stock where product_id = :'ps' and warehouse_id = :'w'), 80::numeric, 'partial receipt: +10 -> 80');
select t.eq_text((select receipt_status from purchase_invoices where id = :'pb_id'::uuid), 'partial', 'invoice B is partially received');
select t.as_owner();
select t.eq_text((select status from stock_shortage_reports where id = :'r1'::uuid), 'in_progress', 'the report stays open');
select t.as_user(:'own');
select t.eq((select incoming_qty from list_stock_shortage_reports(:'org_id', 'open') where id = :'r1'::uuid), 40::numeric, 'coming now 20 (rest of B) + 20 (C)');
select t.eq((select remaining_qty from list_stock_shortage_reports(:'org_id', 'open') where id = :'r1'::uuid), 0::numeric, 'and the remaining shortage is still 0');

-- cancel C (return the 20 units that never arrived): another live purchase exists -> report stays in progress
select id as pitc from purchase_invoice_items where purchase_invoice_id = :'pc_id'::uuid limit 1 \gset
select create_purchase_return(:'org_id', :'pc_id'::uuid, '2026-03-10', jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', :'pitc', 'quantity', 20)), 0, null, false);
select t.as_owner();
select t.eq_text((select receipt_status from purchase_invoices where id = :'pc_id'::uuid), 'cancelled', 'invoice C is cancelled');
select t.as_owner();
select t.eq_text((select status from stock_shortage_reports where id = :'r1'::uuid), 'in_progress', 'B is still coming: the report stays «جاري التجهيز»');
select t.as_user(:'own');
select t.eq((select incoming_qty from list_stock_shortage_reports(:'org_id', 'open') where id = :'r1'::uuid), 20::numeric, 'coming is now 20 (only the rest of B)');

-- cancel the rest of B too: nothing is coming, 80 sellable < 100 -> still open, with the exact remaining shortage
select id as pitb from purchase_invoice_items where purchase_invoice_id = :'pb_id'::uuid limit 1 \gset
select create_purchase_return(:'org_id', :'pb_id'::uuid, '2026-03-11', jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', :'pitb', 'quantity', 20)), 0, null, false);
select t.eq((select incoming_qty from list_stock_shortage_reports(:'org_id', 'open') where id = :'r1'::uuid), 0::numeric, 'nothing is coming any more');
select t.eq((select remaining_qty from list_stock_shortage_reports(:'org_id', 'open') where id = :'r1'::uuid), 20::numeric, 'remaining shortage = 100 - 80 = 20 (accurate after the partial + cancelled purchases)');
select t.as_owner();
select t.ok((select owner_note like '%أقل من المطلوب%' from stock_shortage_reports where id = :'r1'::uuid), 'the note explains the report is still short');
select t.as_user(:'own');

-- ---- "provided from another source": closing by hand needs SELLABLE stock that covers the need
select t.throws(format('select set_stock_shortage_status(%L, %L, ''resolved'', null)', :'org_id', :'r1'::uuid), 'المتاح للبيع الآن', 'cannot be closed by hand while 80 < 100');
select t.as_owner();
select t.eq_text((select status from stock_shortage_reports where id = :'r1'::uuid), 'in_progress', '... and stayed open');
select t.as_user(:'own');
-- stock arrives from ANOTHER source (an unlinked purchase), but part of it is promised to an open sale
select t.as_owner();
select t.as_user(:'own');
select create_purchase_invoice(:'org_id', :'s', :'w', 'PD', '2026-03-12', jsonb_build_array(jsonb_build_object('product_id', :'ps', 'quantity', 30, 'unit_cost', 5, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset pd_
select t.as_user(:'kp');
select confirm_purchase_receipt(:'org_id', :'pd_id'::uuid) as j \gset rd_
select t.as_user(:'own');
select create_sales_invoice(:'org_id', :'c3', :'w', 'S-RES', '2026-03-13',
  jsonb_build_array(jsonb_build_object('product_id', :'ps', 'quantity', 20, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset sres_
select t.eq((select quantity from inventory_stock where product_id = :'ps' and warehouse_id = :'w'), 110::numeric, 'on hand = 110');
select t.throws(format('select set_stock_shortage_status(%L, %L, ''resolved'', null)', :'org_id', :'r1'::uuid), 'الآن (90)', 'on hand 110 but 20 promised to an open sale: sellable is 90 -> still refused');
select t.as_owner();
select t.eq_text((select status from stock_shortage_reports where id = :'r1'::uuid), 'in_progress', 'still open');
select t.as_user(:'own');
-- more arrives, now 110 are sellable
select create_purchase_invoice(:'org_id', :'s', :'w', 'PE', '2026-03-14', jsonb_build_array(jsonb_build_object('product_id', :'ps', 'quantity', 20, 'unit_cost', 5, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset pe_
select t.as_user(:'kp');
select confirm_purchase_receipt(:'org_id', :'pe_id'::uuid) as j \gset re_
select t.as_user(:'own');
select set_stock_shortage_status(:'org_id', :'r1'::uuid, 'resolved', null);
select t.as_owner();
select t.eq_text((select status from stock_shortage_reports where id = :'r1'::uuid), 'resolved', 'closed by hand once 110 are sellable');
select t.as_user(:'own');
select t.as_owner();
select t.ok((select owner_note like '%يغطي المطلوب%' from stock_shortage_reports where id = :'r1'::uuid), 'the note records that stock covers the need');
select t.as_user(:'own');
select t.as_owner();
select t.as_owner();
select t.eq((select (after_data->>'available')::numeric from audit_logs where entity_id = :'r1'::uuid and action = 'stock_shortage.status_changed' order by created_at desc limit 1), 110::numeric, 'the audit row keeps the measured available quantity');

-- ---- a report whose only purchase is cancelled goes back to «جديد»
select t.as_user(:'rp2');
select (report_stock_shortage(:'org_id', :'pb', :'w', 50, null)->>'report_id') as r2 \gset
select t.as_user(:'own');
select create_purchase_invoice(:'org_id', :'s', :'w', 'PF', '2026-03-15', jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 50, 'unit_cost', 5, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset pf_
select link_shortage_to_purchase(:'org_id', :'r2'::uuid, :'pf_id'::uuid);
select t.as_owner();
select t.eq_text((select status from stock_shortage_reports where id = :'r2'::uuid), 'in_progress', 'linked: in progress');
select t.as_user(:'own');
select id as pitf from purchase_invoice_items where purchase_invoice_id = :'pf_id'::uuid limit 1 \gset
select create_purchase_return(:'org_id', :'pf_id'::uuid, '2026-03-16', jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', :'pitf', 'quantity', 50)), 0, null, false);
select t.as_owner();
select t.eq_text((select status from stock_shortage_reports where id = :'r2'::uuid), 'new', 'the only purchase was cancelled: the report is «جديد» again');
select t.as_user(:'own');
select t.as_owner();
select t.ok((select owner_note like '%أُلغيت%' from stock_shortage_reports where id = :'r2'::uuid), 'and says why');
select t.as_user(:'own');
select t.throws(format('select link_shortage_to_purchase(%L, %L, %L)', :'org_id', :'r2'::uuid, :'pf_id'::uuid), 'ملغاة', 'a cancelled invoice cannot be linked');

-- ---- a purchase that fully covers the need closes the report by itself, exactly once
select t.as_user(:'rp1');
select (report_stock_shortage(:'org_id', :'pc', :'w', 30, null)->>'report_id') as r3 \gset
select t.as_user(:'own');
select create_purchase_invoice(:'org_id', :'s', :'w', 'PG', '2026-03-17', jsonb_build_array(jsonb_build_object('product_id', :'pc', 'quantity', 30, 'unit_cost', 5, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset pg_
select link_shortage_to_purchase(:'org_id', :'r3'::uuid, :'pg_id'::uuid);
select t.as_user(:'kp');
select confirm_purchase_receipt(:'org_id', :'pg_id'::uuid) as j \gset rg_
select t.as_owner();
select t.as_owner();
select t.eq_text((select status from stock_shortage_reports where id = :'r3'::uuid), 'resolved', 'received in full and covering the need: closed automatically');
select t.eq((select quantity from inventory_stock where product_id = :'pc' and warehouse_id = :'w'), 30::numeric, 'stock = 30, added once');
select t.as_owner();
select t.eq((select count(*) from audit_logs where entity_id = :'r3'::uuid and action = 'stock_shortage.resolved_by_purchase'), 1::numeric, 'closed (and audited) exactly once');

-- ---- a report in another warehouse is not covered by stock received elsewhere
insert into warehouses (organization_id, name) values (:'org_id', 'الفرع') returning id as w2 \gset
select t.as_user(:'rp2');
select (report_stock_shortage(:'org_id', :'pa', :'w2', 5, null)->>'report_id') as r4 \gset
select t.as_user(:'own');
select create_purchase_invoice(:'org_id', :'s', :'w', 'PH', '2026-03-18', jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 5, 'unit_cost', 5, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset ph_
select link_shortage_to_purchase(:'org_id', :'r4'::uuid, :'ph_id'::uuid);
select t.eq((shortage_purchase_precheck(:'org_id', :'r4'::uuid)->>'incoming')::numeric, 0::numeric, 'stock coming into ANOTHER warehouse does not count as coming for this report');
select t.as_user(:'kp');
select confirm_purchase_receipt(:'org_id', :'ph_id'::uuid) as j \gset rh_
select t.as_owner();
select t.as_owner();
select t.eq_text((select status from stock_shortage_reports where id = :'r4'::uuid), 'in_progress', 'received into the wrong warehouse: the report is not closed');
