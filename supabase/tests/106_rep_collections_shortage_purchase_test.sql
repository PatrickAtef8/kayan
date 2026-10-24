-- 0050: (1) a sales rep registers collections for HIS OWN customers only  (2) shortage reports are covered through a purchase invoice
-- Covers: rep collects against an invoice / standalone · cannot collect for another rep's customer · cannot exceed what is owed ·
-- needs the permission · storekeeper still refused · owner unchanged · treasury movement per collection ·
-- shortage -> link purchase invoice (owner only, invoice must contain the product) -> report «in progress» ->
-- storekeeper receives -> report closes only when the sellable quantity covers the need.
-- (The test-only auto-confirm trigger is OFF for the receiving part: everything goes through the real receiving RPC.)

\set ON_ERROR_STOP on
select t.autoconfirm_off();

select t.as_owner();
insert into auth.users (id, email) values
  ('10600000-0000-0000-0000-000000000001', 'owner@coll.test'),
  ('10600000-0000-0000-0000-000000000002', 'keeper@coll.test'),
  ('10600000-0000-0000-0000-000000000003', 'rep1@coll.test'),
  ('10600000-0000-0000-0000-000000000004', 'rep2@coll.test');

select t.as_user('10600000-0000-0000-0000-000000000001');
select create_organization('شركة التحصيل', 'x', 'EG', 'EGP', 'ar',
  array['products','warehouses','customers','suppliers','sales','purchases','inventory','representatives','treasury','reports']) as id \gset org_

select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', '10600000-0000-0000-0000-000000000002', id, 'active' from roles where key = 'warehouse' and organization_id is null;
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', u, id, 'active' from roles, (values ('10600000-0000-0000-0000-000000000003'::uuid), ('10600000-0000-0000-0000-000000000004'::uuid)) v(u)
where key = 'sales' and organization_id is null;

select t.as_user('10600000-0000-0000-0000-000000000001');
insert into warehouses (organization_id, name) values (:'org_id', 'المخزن الرئيسي') returning id as w \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as s \gset
insert into products (organization_id, name, unit) values (:'org_id', 'صنف أ', 'قطعة') returning id as p \gset
insert into products (organization_id, name, unit) values (:'org_id', 'صنف ب', 'قطعة') returning id as pb \gset
insert into product_prices (organization_id, product_id, selling_price) select :'org_id', id, 20 from products where organization_id = :'org_id';
insert into product_costs (product_id, cost) select id, 8 from products where organization_id = :'org_id';
insert into sales_representatives (organization_id, name, user_id, commission_basis, commission_rate) values (:'org_id', 'مندوب 1', '10600000-0000-0000-0000-000000000003', 'net_sales', 5) returning id as rep1 \gset
insert into sales_representatives (organization_id, name, user_id, commission_basis, commission_rate) values (:'org_id', 'مندوب 2', '10600000-0000-0000-0000-000000000004', 'net_sales', 5) returning id as rep2 \gset
insert into customers (organization_id, name, sales_rep_id) values (:'org_id', 'عميل 1', :'rep1') returning id as c1 \gset
insert into customers (organization_id, name, sales_rep_id) values (:'org_id', 'عميل 2', :'rep2') returning id as c2 \gset

-- opening stock (old, auto-confirmed way): A 100, B 10
select t.as_owner();
select t.autoconfirm_on();
select t.as_user('10600000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'s', :'w', 'OPEN-1', '2026-01-01', jsonb_build_array(
  jsonb_build_object('product_id', :'p', 'quantity', 100, 'unit_cost', 8, 'discount', 0),
  jsonb_build_object('product_id', :'pb', 'quantity', 10, 'unit_cost', 8, 'discount', 0)), 0, 0, 0, 'نقدًا', null) as id \gset leg_
select t.as_owner();
select t.autoconfirm_off();

-- ------------------------------------------------------------------
-- 1. Collections by the rep
-- ------------------------------------------------------------------
select t.as_user('10600000-0000-0000-0000-000000000003');   -- rep 1
select create_sales_invoice(:'org_id', :'c1', :'w', 'S-1', '2026-02-05', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 10, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset si1_
select create_sales_invoice(:'org_id', :'c1', :'w', 'S-1B', '2026-02-06', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 5, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset si1b_

select record_customer_collection(:'org_id', :'c1', :'si1_id', 50, '2026-02-07', 'نقدًا', null, null) as id \gset col1_
select t.eq((select amount_paid from sales_invoices where id = :'si1_id'), 50, 'rep 1 collected 50 on his own customer''s invoice');
select t.eq_text((select payment_status from sales_invoices where id = :'si1_id'), 'partial', 'the invoice is now partially paid');
select t.eq((select count(*) from customer_collections where id = :'col1_id'), 1, 'the rep sees the collection he registered');

select record_customer_collection(:'org_id', :'c1', null, 5, '2026-02-07', 'نقدًا', null, null) as id \gset col2_
select t.ok(:'col2_id' is not null, 'a standalone collection (no invoice) for his own customer is allowed too');

select t.throws(format($q$select record_customer_collection(%L, %L, %L, 5000, '2026-02-07', 'نقدًا', null, null)$q$, :'org_id', :'c1', :'si1_id'), 'أكبر من المتبقي', 'a rep cannot collect more than what is still owed');
select t.throws(format($q$select record_customer_collection(%L, %L, null, 10, '2026-02-07', 'نقدًا', null, null)$q$, :'org_id', :'c2'), 'عملائك', 'a rep cannot collect from ANOTHER rep''s customer');
select t.throws(format($q$select record_customer_collection(%L, %L, %L, 10, '2026-02-07', 'نقدًا', null, null)$q$, :'org_id', :'c2', :'si1_id'), 'عملائك', 'nor with an invoice id that is not his customer''s');
select t.throws(format($q$select record_customer_collection(%L, %L, %L, 10, '2026-02-07', 'نقدًا', null, null)$q$, :'org_id', :'c1', gen_random_uuid()), 'لا تخص', 'an unknown invoice is rejected');

-- treasury: one movement per collection, written by the same function
select t.as_owner();
select t.eq((select count(*) from treasury_movements where source_type = 'customer_collection' and source_id in (:'col1_id'::uuid, :'col2_id'::uuid)), 2, 'every collection created its own treasury movement');
select t.eq((select sum(amount) from treasury_movements where source_type = 'customer_collection' and source_id in (:'col1_id'::uuid, :'col2_id'::uuid)), 55, 'for the exact amounts collected');

-- without the permission the rep is refused (the permission, not the role, is what opens the door)
delete from role_permissions where permission_key = 'collections.record' and role_id = (select id from roles where key = 'sales' and organization_id is null);
select t.as_user('10600000-0000-0000-0000-000000000003');
select t.throws(format($q$select record_customer_collection(%L, %L, %L, 10, '2026-02-07', 'نقدًا', null, null)$q$, :'org_id', :'c1', :'si1b_id'), 'صلاحية', 'without collections.record the rep is refused');
select t.as_owner();
insert into role_permissions (role_id, permission_key) select id, 'collections.record' from roles where key = 'sales' and organization_id is null;

-- the storekeeper still cannot collect; the owner still can, for anyone
select t.as_user('10600000-0000-0000-0000-000000000002');
select t.throws(format($q$select record_customer_collection(%L, %L, null, 10, '2026-02-07', 'نقدًا', null, null)$q$, :'org_id', :'c1'), 'صلاحية', 'the storekeeper cannot register collections');
select t.as_user('10600000-0000-0000-0000-000000000001');
select record_customer_collection(:'org_id', :'c2', null, 10, '2026-02-08', 'نقدًا', null, null) as id \gset col3_
select t.ok(:'col3_id' is not null, 'the owner can collect from any customer');
select record_customer_collection(:'org_id', :'c1', :'si1b_id', 100, '2026-02-08', 'نقدًا', null, null) as id \gset col4_
select t.eq_text((select payment_status from sales_invoices where id = :'si1b_id'), 'paid', 'the owner settles an invoice in full');

-- ------------------------------------------------------------------
-- 2. Shortage report -> purchase invoice
-- ------------------------------------------------------------------
select t.as_user('10600000-0000-0000-0000-000000000003');
select report_stock_shortage(:'org_id', :'pb', :'w', 40, 'العميل يحتاج 40') ->> 'report_id' as r1 \gset
select t.as_user('10600000-0000-0000-0000-000000000004');
select report_stock_shortage(:'org_id', :'pb', :'w', 100, 'طلب كبير') ->> 'report_id' as r2 \gset

-- purchase invoices (receiving is pending until the storekeeper confirms)
select t.as_user('10600000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'s', :'w', 'PB-1', '2026-02-10', jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 30, 'unit_cost', 8, 'discount', 0)), 0, 0, 0, 'نقدًا', null) as id \gset pi1_
select create_purchase_invoice(:'org_id', :'s', :'w', 'PA-1', '2026-02-10', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 5, 'unit_cost', 8, 'discount', 0)), 0, 0, 0, 'نقدًا', null) as id \gset pia_

select t.throws(format($q$select link_shortage_to_purchase(%L, %L, %L)$q$, :'org_id', :'r1', :'pia_id'), 'لا تحتوي', 'an invoice that does not contain the missing product cannot be linked');
select t.throws(format($q$select link_shortage_to_purchase(%L, %L, %L)$q$, :'org_id', :'r1', gen_random_uuid()), 'غير موجودة', 'an unknown invoice is rejected');

select t.as_user('10600000-0000-0000-0000-000000000003');
select t.throws(format($q$select link_shortage_to_purchase(%L, %L, %L)$q$, :'org_id', :'r1', :'pi1_id'), 'للمالك فقط', 'a rep cannot link a purchase invoice');
select t.throws(format($q$select list_shortage_report_links(%L, array[%L]::uuid[])$q$, :'org_id', :'r1'), 'صلاحية', 'a rep cannot list purchase invoices');

select t.as_user('10600000-0000-0000-0000-000000000001');
select link_shortage_to_purchase(:'org_id', :'r1', :'pi1_id') as j \gset l1_
select t.eq_text((select status from list_stock_shortage_reports(:'org_id', 'in_progress') where id = :'r1'::uuid), 'in_progress', 'linking moves the report to «جاري التجهيز» (not resolved: nothing arrived yet)');
select t.eq((select count(*) from list_shortage_report_links(:'org_id', array[:'r1'::uuid]) where purchase_invoice_id = :'pi1_id'::uuid and receipt_status = 'pending'), 1, 'the owner sees the linked invoice, still waiting for receiving');
select t.eq((select quantity from inventory_stock where product_id = :'pb' and warehouse_id = :'w'), 10, 'no stock was added by creating/linking the invoice');

-- storekeeper receives PB-1 -> 40 sellable >= 40 needed -> the report closes by itself
select t.as_user('10600000-0000-0000-0000-000000000002');
select confirm_purchase_receipt(:'org_id', :'pi1_id') as j \gset rc1_
select t.as_owner();
select t.eq((select quantity from inventory_stock where product_id = :'pb' and warehouse_id = :'w'), 40, 'the quantity was added to stock by the receiving confirmation');
select t.eq_text((select status from stock_shortage_reports where id = :'r1'::uuid), 'resolved', 'the report closed automatically once the quantity covers the need');

-- a purchase that does NOT cover the need keeps the report open
select t.as_user('10600000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'s', :'w', 'PB-2', '2026-02-12', jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 10, 'unit_cost', 8, 'discount', 0)), 0, 0, 0, 'نقدًا', null) as id \gset pi2_
select link_shortage_to_purchase(:'org_id', :'r2', :'pi2_id') as j \gset l2_
select t.as_user('10600000-0000-0000-0000-000000000002');
select confirm_purchase_receipt(:'org_id', :'pi2_id') as j \gset rc2_
select t.as_owner();
select t.eq_text((select status from stock_shortage_reports where id = :'r2'::uuid), 'in_progress', 'received 10 (50 available) is still below the 100 needed: the report stays open');
select t.ok((select owner_note like '%أقل من المطلوب%' from stock_shortage_reports where id = :'r2'::uuid), 'and says why');

select t.as_user('10600000-0000-0000-0000-000000000001');   -- the call must run as the owner, otherwise the (correct) 'log in first' error fires instead
select t.throws(format($q$select link_shortage_to_purchase(%L, %L, %L)$q$, :'org_id', :'r1', :'pi2_id'), 'تم توفير', 'a resolved report cannot be linked again');
