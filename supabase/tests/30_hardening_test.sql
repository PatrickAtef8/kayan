-- SRS §49 (duplicate submissions) and §11 (disabled modules blocked in the
-- database, not only hidden in the UI).

\set ON_ERROR_STOP on

select t.as_owner();
insert into auth.users (id, email) values ('d0000000-0000-0000-0000-000000000001', 'owner@dup.test');
select t.as_user('d0000000-0000-0000-0000-000000000001');
-- Note: 'sales' and 'representatives' are deliberately left disabled to
-- test §11 below; everything else needed for the duplicate-guard tests is on.
select create_organization('شركة التكرار', 'x', 'EG', 'EGP', 'ar', array['customers','inventory','purchases','suppliers','expenses','treasury','partners']) as id \gset org_
insert into warehouses (organization_id, name) values (:'org_id', 'م') returning id as wh \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as sup \gset
insert into customers (organization_id, name) values (:'org_id', 'عميل') returning id as cus \gset
insert into products (organization_id, name) values (:'org_id', 'منتج') returning id as prod \gset
insert into partners (organization_id, name) values (:'org_id', 'شريك') returning id as par \gset
select id as cat from expense_categories where organization_id = :'org_id' limit 1 \gset

-- ============================================================
-- Duplicate-submission guard (§49)
-- ============================================================
select create_purchase_invoice(:'org_id', :'sup', :'wh', null, '2026-05-01',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 1, 'unit_cost', 10, 'discount', 0)), 0, 0, 0, null, null) as id \gset pi1_
select t.throws(
  format('select create_purchase_invoice(%L, %L, %L, null, %L, %L::jsonb, 0, 0, 0, null, null)', :'org_id', :'sup', :'wh', '2026-05-01',
    jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 1, 'unit_cost', 10, 'discount', 0))::text),
  'تم تسجيل عملية مطابقة', 'an immediate identical purchase invoice (double-click) is rejected');
select t.eq((select count(*) from purchase_invoices where organization_id = :'org_id'), 1, 'only one purchase invoice exists');

-- A genuinely different invoice (different date -> the guard's own key
-- columns differ) goes through fine. Note honestly: the guard compares
-- header columns only (supplier/warehouse/number/date), so two distinct
-- invoices sharing all of those within 5 seconds would also be blocked —
-- that is the documented trade-off, not a bug.
select create_purchase_invoice(:'org_id', :'sup', :'wh', null, '2026-05-04',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 5, 'unit_cost', 10, 'discount', 0)), 0, 0, 0, null, null) as id \gset pi2_
select t.ok(:'pi1_id' <> :'pi2_id', 'a distinct invoice (different date) is not treated as a duplicate');

select record_supplier_payment(:'org_id', :'sup', null, 100, '2026-05-02', 'نقدًا', null, null) as id \gset sp1_
select t.throws(
  format('select record_supplier_payment(%L, %L, null, 100, %L, ''نقدًا'', null, null)', :'org_id', :'sup', '2026-05-02'),
  'تم تسجيل عملية مطابقة', 'a duplicate supplier payment is rejected');
select record_supplier_payment(:'org_id', :'sup', null, 100, '2026-05-03', 'نقدًا', null, null) as id \gset sp2_
select t.ok(:'sp1_id' <> :'sp2_id', 'the same amount/method on a different date is not a duplicate');

select create_expense(:'org_id', :'cat', null, 50, '2026-05-01', 'نقدًا', 'إيجار', null) as id \gset e1_
select t.throws(
  format('select create_expense(%L, %L, null, 50, %L, ''نقدًا'', ''إيجار'', null)', :'org_id', :'cat', '2026-05-01'),
  'تم تسجيل عملية مطابقة', 'a duplicate expense is rejected');

select record_partner_withdrawal(:'org_id', :'par', null, 20, '2026-05-01', 'سحب', null) as id \gset pw1_
select t.throws(
  format('select record_partner_withdrawal(%L, %L, null, 20, %L, ''سحب'', null)', :'org_id', :'par', '2026-05-01'),
  'تم تسجيل عملية مطابقة', 'a duplicate partner withdrawal is rejected');

select record_treasury_movement(:'org_id', null, 'in', 30, '2026-05-01', 'إيراد') as id \gset tm1_
select t.throws(
  format('select record_treasury_movement(%L, null, ''in'', 30, %L, ''إيراد'')', :'org_id', '2026-05-01'),
  'تم تسجيل عملية مطابقة', 'a duplicate manual treasury movement is rejected');

-- After the 5-second window a genuinely repeated payment is accepted (this
-- sleeps for real, so it is worth its ~5s cost to prove the guard expires).
select pg_sleep(5.2);
select record_supplier_payment(:'org_id', :'sup', null, 100, '2026-05-02', 'نقدًا', null, null) as id \gset sp3_
select t.ok(:'sp3_id' is not null, 'the same payment is accepted again once 5 seconds have passed');

-- Two different users performing the "same" action at the same moment are
-- NOT treated as duplicates of each other.
select t.as_owner();
insert into auth.users (id, email) values ('d0000000-0000-0000-0000-000000000002', 'accountant@dup.test');
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', 'd0000000-0000-0000-0000-000000000002', id, 'active' from roles where key = 'accountant' and organization_id is null;
select t.as_user('d0000000-0000-0000-0000-000000000002');
select create_expense(:'org_id', :'cat', null, 50, '2026-05-01', 'نقدًا', 'إيجار', null) as id \gset e2_
select t.ok(:'e1_id' <> :'e2_id', 'the guard is per-user, not per-organization');

-- ============================================================
-- Disabled modules are enforced server-side (§11)
-- ============================================================
select t.as_user('d0000000-0000-0000-0000-000000000001');
select t.throws(format('insert into sales_representatives (organization_id, name) values (%L, ''م'')', :'org_id'), 'غير مفعّلة', 'representatives module disabled: direct insert is refused');
select t.throws(
  format('select create_sales_invoice(%L, %L, %L, null, %L, %L::jsonb, 0, 0, 0, null, null, null)', :'org_id', :'cus', :'wh', '2026-05-01',
    jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 1, 'unit_price', 1, 'discount', 0))::text),
  'غير مفعّلة', 'sales module disabled: create_sales_invoice via RPC is refused too (not just hidden in the UI)');

-- Enable it and the same call now succeeds.
select t.as_owner();
update organization_modules set enabled = true where organization_id = :'org_id' and module_key = 'sales';
insert into organization_modules (organization_id, module_key, enabled) values (:'org_id', 'sales', true) on conflict (organization_id, module_key) do update set enabled = true;
select t.as_user('d0000000-0000-0000-0000-000000000001');
select create_sales_invoice(:'org_id', :'cus', :'wh', null, '2026-05-01',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 1, 'unit_price', 1, 'discount', 0)), 0, 0, 0, null, null, null) as id \gset si1_
select t.ok(:'si1_id' is not null, 'enabling the module allows the same operation to succeed');

-- Core modules (products, warehouses) are never blocked, even if someone
-- never explicitly enabled them.
select t.ok((select not exists (select 1 from organization_modules where organization_id = :'org_id' and module_key = 'products')), 'products was never explicitly enabled for this org');
insert into products (organization_id, name) values (:'org_id', 'منتج آخر') returning id as prod2 \gset
select t.ok(:'prod2' is not null, 'core module (products) is never blocked by the module gate');

-- ============================================================
-- Immutable audit log (§46, §47)
-- ============================================================
select t.eq((select count(*) from audit_logs where organization_id = :'org_id' and entity = 'sales_invoice' and entity_id = :'si1_id'), 1, 'creating a sales invoice writes one audit row');
select t.eq((select (after_data ->> 'total')::numeric from audit_logs where entity = 'sales_invoice' and entity_id = :'si1_id'), 1, 'the audit row captures the invoice''s final total, not the empty header (deferred trigger)');
select t.eq((select count(*) from audit_logs where organization_id = :'org_id' and entity = 'expense'), 2, 'each expense creation writes one audit row');
-- No UPDATE/DELETE grant exists on audit_logs at all (belt), and the
-- immutability trigger would refuse it even if one were mistakenly added
-- later (suspenders) — see the direct trigger-level check further down.
select t.throws(format('delete from audit_logs where organization_id = %L', :'org_id'), 'permission denied', 'audit log rows cannot be deleted, even by the owner');
select t.throws(format('update audit_logs set action = ''x'' where organization_id = %L', :'org_id'), 'permission denied', 'audit log rows cannot be edited, even by the owner');
select t.as_owner();
select t.throws(format('delete from audit_logs where organization_id = %L', :'org_id'), 'لا يمكن تعديله', 'even as table owner (bypassing RLS/grants), the immutability trigger itself refuses a delete');
select t.throws(format('update audit_logs set action = ''x'' where organization_id = %L', :'org_id'), 'لا يمكن تعديله', 'even as table owner, the immutability trigger itself refuses an update');
select t.as_user('d0000000-0000-0000-0000-000000000001');
select t.throws(format('insert into audit_logs (organization_id, action, entity) values (%L, ''x'', ''y'')', :'org_id'), 'permission denied', 'nobody can insert a forged audit row directly');

-- accountant (has audit.view) can read it; a plain sales-only role cannot
select t.as_user('d0000000-0000-0000-0000-000000000002');
select t.ok((select count(*) from audit_logs where organization_id = :'org_id') > 0, 'accountant (audit.view) can read the audit log');

select t.as_owner();
insert into auth.users (id, email) values ('d0000000-0000-0000-0000-000000000003', 'sales@dup.test');
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', 'd0000000-0000-0000-0000-000000000003', id, 'active' from roles where key = 'sales' and organization_id is null;
select t.as_user('d0000000-0000-0000-0000-000000000003');
select t.empty(format('select 1 from audit_logs where organization_id = %L', :'org_id'), 'a plain sales role (no audit.view) reads zero audit rows');

-- ============================================================
-- Manual stock adjustment is real, permission-gated, and audited (§20)
-- ============================================================
select t.as_owner();
select quantity as before_qty from inventory_stock where organization_id = :'org_id' and product_id = :'prod' \gset
select t.as_user('d0000000-0000-0000-0000-000000000001');
select t.throws(format('select adjust_inventory_stock(%L, %L, %L, 5, null)', :'org_id', :'prod', :'wh'), 'سبب التسوية مطلوب', 'a stock adjustment needs a reason');
select adjust_inventory_stock(:'org_id', :'prod', :'wh', 5, 'جرد فعلي') as id \gset adj1_
select t.eq((select quantity from inventory_stock where organization_id = :'org_id' and product_id = :'prod'), :'before_qty'::numeric + 5, 'stock adjustment changes the balance');
select t.eq((select count(*) from audit_logs where organization_id = :'org_id' and entity = 'inventory_adjustment' and entity_id = :'adj1_id'), 1, 'the stock adjustment is audited');
select t.throws(format('select adjust_inventory_stock(%L, %L, %L, %L, ''جرد'')', :'org_id', :'prod', :'wh', -999999), 'سالبًا', 'an adjustment that would make stock negative is refused');

-- accountant has no inventory.adjust permission
select t.as_user('d0000000-0000-0000-0000-000000000002');
select t.throws(format('select adjust_inventory_stock(%L, %L, %L, 1, ''x'')', :'org_id', :'prod', :'wh'), 'صلاحية تسوية المخزون', 'a user without inventory.adjust cannot adjust stock');

select t.as_owner();
