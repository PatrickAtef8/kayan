-- 0054: a purchase invoice created FROM a shortage report and its link to that report are ONE transaction.
-- Covers: success saves invoice + link + report «in progress» together · every refusal of the link step leaves NOTHING behind
-- (no invoice, no lines, no stock-in order, no notification, no supplier balance change, no number consumed) ·
-- a rep cannot use it · the plain create_purchase_invoice path is unchanged.

\set ON_ERROR_STOP on
select t.autoconfirm_off();

select t.as_owner();
insert into auth.users (id, email) values
  ('11000000-0000-0000-0000-000000000001', 'owner@atom.test'),
  ('11000000-0000-0000-0000-000000000003', 'rep@atom.test');
select t.as_user('11000000-0000-0000-0000-000000000001');
select create_organization('شركة الذرّية', 'x', 'EG', 'EGP', 'ar',
  array['products','warehouses','customers','suppliers','sales','purchases','inventory','representatives']) as id \gset org_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', '11000000-0000-0000-0000-000000000003', id, 'active' from roles where key = 'sales' and organization_id is null;

select t.as_user('11000000-0000-0000-0000-000000000001');
insert into warehouses (organization_id, name) values (:'org_id', 'المخزن') returning id as w \gset
insert into suppliers (organization_id, name) values (:'org_id', 'المورد') returning id as s \gset
insert into products (organization_id, name, unit) values (:'org_id', 'ناقص', 'قطعة') returning id as pshort \gset
insert into products (organization_id, name, unit) values (:'org_id', 'آخر', 'قطعة') returning id as pother \gset
insert into sales_representatives (organization_id, name, user_id, commission_basis, commission_rate) values (:'org_id', 'مندوب', '11000000-0000-0000-0000-000000000003', 'net_sales', 5);

select t.as_user('11000000-0000-0000-0000-000000000003');
select report_stock_shortage(:'org_id', :'pshort', :'w', 40, 'العميل يحتاج 40') ->> 'report_id' as r1 \gset

select t.as_owner();
create or replace function t.line(p uuid, q numeric) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('product_id', p, 'quantity', q, 'unit_cost', 8, 'discount', 0))
$$;
grant execute on function t.line(uuid, numeric) to authenticated;

create or replace function t.snapshot() returns text language sql as $$
  select concat_ws('|',
    (select count(*) from purchase_invoices), (select count(*) from purchase_invoice_items),
    (select count(*) from notifications), (select count(*) from stock_shortage_purchase_links),
    (select coalesce(sum(last_value), 0) from document_counters where kind = 'purchase_invoice'),
    (select count(*) from inventory_movements), (select count(*) from audit_logs))
$$;

-- =====================================================================
-- 1. Success: invoice + link + report status, together
-- =====================================================================
select t.as_user('11000000-0000-0000-0000-000000000001');
select create_purchase_invoice_for_shortage(:'org_id', :'r1', :'s', :'w', 'ATOM-1', '2026-03-01', t.line(:'pshort', 40), 0, 0, 0, 'نقدًا', null, 0, '[]'::jsonb, null) ->> 'purchase_invoice_id' as inv \gset ok_
select t.as_owner();
select t.eq((select count(*) from purchase_invoices where id = :'ok_inv'), 1, 'success: the invoice is saved');
select t.eq((select count(*) from stock_shortage_purchase_links where report_id = :'r1' and purchase_invoice_id = :'ok_inv'), 1, 'success: and linked to the report');
select t.eq_text((select status from stock_shortage_reports where id = :'r1'), 'in_progress', 'success: the report moved to «جاري التجهيز»');

-- =====================================================================
-- 2. Every way the link step can refuse leaves NOTHING behind
-- =====================================================================
select t.snapshot() as before_all \gset

-- (a) the invoice does not contain the product the report is about  -> link refuses, AFTER the invoice was created inside
select t.as_user('11000000-0000-0000-0000-000000000001');
select t.throws(format($q$select create_purchase_invoice_for_shortage(%L, %L, %L, %L, 'ATOM-BAD', '2026-03-02', t.line(%L, 5), 0, 0, 0, 'نقدًا', null, 0, '[]'::jsonb, null)$q$, :'org_id', :'r1', :'s', :'w', :'pother'),
  'لا تحتوي', '(a) wrong product: the link is refused');
select t.as_owner();
select t.eq_text(t.snapshot(), :'before_all', '(a) ... and NOTHING was left behind: no invoice, lines, notifications, links, number, stock rows or audit rows');
select t.eq((select count(*) from purchase_invoices where invoice_number = 'ATOM-BAD'), 0, '(a) the invoice number is not in the database');

-- (b) the report was resolved meanwhile
update stock_shortage_reports set status = 'resolved' where id = :'r1';
-- (changing the status by hand is itself notified; compare from here)
select t.snapshot() as b_before \gset
select t.as_user('11000000-0000-0000-0000-000000000001');
select t.throws(format($q$select create_purchase_invoice_for_shortage(%L, %L, %L, %L, 'ATOM-RES', '2026-03-03', t.line(%L, 5), 0, 0, 0, 'نقدًا', null, 0, '[]'::jsonb, null)$q$, :'org_id', :'r1', :'s', :'w', :'pshort'),
  'تم توفير', '(b) resolved report: refused');
select t.as_owner();
select t.eq_text(t.snapshot(), :'b_before', '(b) ... nothing left behind');
update stock_shortage_reports set status = 'in_progress' where id = :'r1';
select t.snapshot() as c_before \gset

-- (c) a purchase already on its way covers the shortage and the owner did not confirm another one
select t.as_user('11000000-0000-0000-0000-000000000001');
select t.throws(format($q$select create_purchase_invoice_for_shortage(%L, %L, %L, %L, 'ATOM-DUP', '2026-03-04', t.line(%L, 5), 0, 0, 0, 'نقدًا', null, 0, '[]'::jsonb, null)$q$, :'org_id', :'r1', :'s', :'w', :'pshort'),
  'تغطي العجز', '(c) already covered: refused without explicit confirmation');
select t.as_owner();
select t.eq_text(t.snapshot(), :'c_before', '(c) ... nothing left behind');
-- with the explicit confirmation it is saved AND linked, together
select t.as_user('11000000-0000-0000-0000-000000000001');
select create_purchase_invoice_for_shortage(:'org_id', :'r1', :'s', :'w', 'ATOM-EXTRA', '2026-03-04', t.line(:'pshort', 5), 0, 0, 0, 'نقدًا', null, 0, '[]'::jsonb, null, true) ->> 'purchase_invoice_id' as inv \gset extra_
select t.as_owner();
select t.eq((select count(*) from stock_shortage_purchase_links where report_id = :'r1' and purchase_invoice_id = :'extra_inv'), 1, '(c) with confirm_additional: saved and linked together');
select t.snapshot() as after_extra \gset

-- (d) unknown report
select t.as_user('11000000-0000-0000-0000-000000000001');
select t.throws(format($q$select create_purchase_invoice_for_shortage(%L, %L, %L, %L, 'ATOM-GHOST', '2026-03-05', t.line(%L, 5), 0, 0, 0, 'نقدًا', null, 0, '[]'::jsonb, null)$q$, :'org_id', gen_random_uuid(), :'s', :'w', :'pshort'),
  'البلاغ غير موجود', '(d) unknown report: refused');
select t.as_owner();
select t.eq_text(t.snapshot(), :'after_extra', '(d) ... nothing left behind');

-- (e) the invoice itself is invalid (unknown product): no link attempted, still nothing left
select t.as_user('11000000-0000-0000-0000-000000000001');
select t.throws(format($q$select create_purchase_invoice_for_shortage(%L, %L, %L, %L, 'ATOM-NOPROD', '2026-03-06', t.line(%L, 5), 0, 0, 0, 'نقدًا', null, 0, '[]'::jsonb, null)$q$, :'org_id', :'r1', :'s', :'w', gen_random_uuid()),
  '', '(e) invalid invoice: refused');
select t.as_owner();
select t.eq_text(t.snapshot(), :'after_extra', '(e) ... nothing left behind');

-- =====================================================================
-- 3. Who may use it, and the ordinary path is untouched
-- =====================================================================
select t.as_user('11000000-0000-0000-0000-000000000003');
select t.throws(format($q$select create_purchase_invoice_for_shortage(%L, %L, %L, %L, 'ATOM-REP', '2026-03-07', t.line(%L, 5), 0, 0, 0, 'نقدًا', null, 0, '[]'::jsonb, null)$q$, :'org_id', :'r1', :'s', :'w', :'pshort'),
  'للمالك فقط', 'a rep cannot create/link a purchase this way');
select t.as_anon();
select t.throws(format($q$select create_purchase_invoice_for_shortage(%L, %L, %L, %L, 'ATOM-ANON', '2026-03-07', t.line(%L, 5), 0, 0, 0, 'نقدًا', null, 0, '[]'::jsonb, null)$q$, :'org_id', :'r1', :'s', :'w', :'pshort'),
  '', 'an anonymous caller is refused');
select t.as_owner();
select t.eq_text(t.snapshot(), :'after_extra', 'refused callers left nothing behind');

select t.as_user('11000000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'s', :'w', 'PLAIN-1', '2026-03-08', t.line(:'pother', 3), 0, 0, 0, 'نقدًا', null) as id \gset plain_
select t.as_owner();
select t.eq((select count(*) from purchase_invoices where id = :'plain_id'), 1, 'the ordinary purchase (no report) still saves exactly as before');
select t.eq((select count(*) from stock_shortage_purchase_links where purchase_invoice_id = :'plain_id'), 0, '... and is linked to nothing');

select 'ATOMIC SHORTAGE PURCHASE: ALL PASSED' as result;
