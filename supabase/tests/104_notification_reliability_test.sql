-- 0047: failures are recorded and retried (never lost, never duplicated, never block the sale) and the
-- backfill of dispatch/receiving work that was already open before 0046.
\set ON_ERROR_STOP on
select t.autoconfirm_off();

select t.as_owner();
insert into auth.users (id, email) values
  ('10400000-0000-0000-0000-000000000001', 'owner@rel.test'),
  ('10400000-0000-0000-0000-000000000002', 'keeper1@rel.test'),
  ('10400000-0000-0000-0000-000000000003', 'keeper2@rel.test'),
  ('10400000-0000-0000-0000-000000000004', 'rep@rel.test'),
  ('10400000-0000-0000-0000-000000000005', 'outsider@rel.test');
select t.as_user('10400000-0000-0000-0000-000000000001');
select create_organization('شركة الموثوقية', 'x', 'EG', 'EGP', 'ar', array['products','warehouses','customers','suppliers','sales','purchases','inventory','representatives','treasury','reports']) as id \gset org_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', u.id, r.id, 'active'
from (values ('10400000-0000-0000-0000-000000000002'::uuid, 'warehouse'), ('10400000-0000-0000-0000-000000000003', 'warehouse'), ('10400000-0000-0000-0000-000000000004', 'sales')) u(id, k)
join roles r on r.key = u.k and r.organization_id is null;
select t.as_user('10400000-0000-0000-0000-000000000001');
insert into warehouses (organization_id, name) values (:'org_id', 'المخزن') returning id as w \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as s \gset
insert into products (organization_id, name, unit) values (:'org_id', 'صنف أ', 'قطعة') returning id as p \gset
insert into product_prices (organization_id, product_id, selling_price) values (:'org_id', :'p', 20);
insert into product_costs (product_id, cost) values (:'p', 8);
insert into sales_representatives (organization_id, name, user_id, commission_basis, commission_rate) values (:'org_id', 'مندوب', '10400000-0000-0000-0000-000000000004', 'net_sales', 5) returning id as rep \gset
insert into customers (organization_id, name, sales_rep_id) values (:'org_id', 'عميل', :'rep') returning id as c \gset

select t.as_owner();
select t.autoconfirm_on();
select t.as_user('10400000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'s', :'w', 'OPEN-1', '2026-01-01', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 100, 'unit_cost', 8, 'discount', 0)), 0, 0, 0, 'نقدًا', null) as id \gset open_
select t.as_owner();
select t.autoconfirm_off();

-- =====================================================================
-- A. BACKFILL: work that was open before the notification system existed
-- =====================================================================
select t.as_user('10400000-0000-0000-0000-000000000004');
select create_sales_invoice(:'org_id', :'c', :'w', 'S-A', '2026-02-01', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 10, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset sa_
select create_sales_invoice(:'org_id', :'c', :'w', 'S-B', '2026-02-02', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 4, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset sb_
select create_sales_invoice(:'org_id', :'c', :'w', 'S-C', '2026-02-03', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 2, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset sc_
select t.as_user('10400000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'s', :'w', 'P-A', '2026-02-04', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 30, 'unit_cost', 9, 'discount', 0)), 0, 0, 0, 'نقدًا', null) as id \gset pa_
select t.as_user('10400000-0000-0000-0000-000000000002');
select confirm_sales_dispatch(:'org_id', :'sa_id', jsonb_build_array(jsonb_build_object('line_id', (select (l->>'line_id') from warehouse_sales_orders(:'org_id', 'open', 'S-A') o, jsonb_array_elements(o.lines) l), 'quantity', 6))) as j \gset p1_
-- S-C is fully dispatched: NOT open work
select confirm_sales_dispatch(:'org_id', :'sc_id') as j \gset p2_

select t.as_owner();
create or replace view t.nm as select * from notifications where organization_id = :'org_id';
-- pretend 0046 had just been applied: no notification exists yet
select t.as_owner();
delete from notifications;
delete from notification_failures;
select quantity as stock_before from inventory_stock where product_id = :'p' and warehouse_id = :'w' \gset
select (select coalesce(sum(total), 0) from sales_invoices) as sales_before, (select coalesce(sum(total), 0) from purchase_invoices) as purch_before,
       (select count(*) from inventory_movements) as mov_before, (select count(*) from audit_logs) as audit_before \gset

select _ntf_backfill_open_work();
select t.eq((select count(*) from t.nm), 6, 'backfill: 3 open invoices (S-A partial, S-B, P-A) x 2 storekeepers = 6 cards');
select t.ok((select bool_and(recipient_user_id in ('10400000-0000-0000-0000-000000000002', '10400000-0000-0000-0000-000000000003')) from t.nm), 'only storekeepers get them (no owner / rep)');
select t.ok((select bool_and(read_at is null and resolved_at is null) from t.nm), 'unread and open');
select t.eq((select count(*) from t.nm where payload->>'invoice_number' = 'S-C'), 0, 'the fully dispatched invoice has no task');
select t.eq((select count(*) from t.nm where payload->>'invoice_number' = 'OPEN-1'), 0, 'neither does the legacy/received purchase');
select t.eq((select sum((l->>'remaining')::numeric) from t.nm n, jsonb_array_elements(n.payload->'lines') l where n.recipient_user_id = '10400000-0000-0000-0000-000000000003' and n.payload->>'invoice_number' = 'S-A'), 4, 'S-A shows the REMAINING quantity (10 - 6 = 4)');
select t.ok((select bool_and(created_at = (case when type = 'warehouse_dispatch_needed' then (select created_at from sales_invoices where id = n.entity_id) else (select created_at from purchase_invoices where id = n.entity_id) end)) from t.nm n), 'dated by the invoice, not by the migration');
select t.ok((select bool_and(_ntf_warehouse_payload_ok(payload)) from t.nm), 'quantities only: payload passes the storekeeper whitelist');
select t.ok((select not bool_or(payload::text ~* '(total|price|amount|cost|customer|supplier|عميل|مورد)') from t.nm), 'no money, no party');

select t.eq(_ntf_backfill_open_work(), 0, 're-running the backfill inserts nothing');
select t.eq((select count(*) from t.nm), 6, 'still six');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), :stock_before::numeric, 'stock untouched');
select t.eq((select coalesce(sum(total), 0) from sales_invoices), :sales_before::numeric, 'sales totals untouched');
select t.eq((select coalesce(sum(total), 0) from purchase_invoices), :purch_before::numeric, 'purchase totals untouched');
select t.eq((select count(*) from inventory_movements), :mov_before::numeric, 'no stock movement written');
select t.eq((select count(*) from audit_logs), :audit_before::numeric, 'no audit noise');

-- the same work later flows through the normal triggers WITHOUT duplicates
select t.as_user('10400000-0000-0000-0000-000000000002');
select confirm_sales_dispatch(:'org_id', :'sa_id') as j \gset p3_
select t.as_owner();
select t.eq((select count(*) from t.nm where type = 'warehouse_dispatch_needed' and payload->>'invoice_number' = 'S-A'), 2, 'finishing S-A updates the backfilled card (still one per storekeeper)');
select t.ok((select bool_and(resolved_at is not null) from t.nm where type = 'warehouse_dispatch_needed' and payload->>'invoice_number' = 'S-A'), 'and closes it');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), :stock_before::numeric - 4, 'only the 4 remaining units left the shelf (no double deduction)');

-- =====================================================================
-- B. RETRY: a failure is recorded, retried, delivered once; a payment taken WITH the invoice is not re-announced
-- =====================================================================
select t.as_owner();
delete from notifications;
alter table notifications add constraint tmp_break check (false) not valid;
select t.as_user('10400000-0000-0000-0000-000000000004');
select create_sales_invoice(:'org_id', :'c', :'w', 'S-R', '2026-02-10', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 3, 'unit_price', 20, 'discount', 0)), 0, 0, 20, 'نقدًا', null, null) as id \gset sr_
select t.as_owner();
select t.ok(exists (select 1 from sales_invoices where id = :'sr_id'), 'the sale was posted although notifications were failing');
select t.eq((select amount_paid from sales_invoices where id = :'sr_id'), 20, 'with its payment');
select t.eq((select count(*) from customer_collections where sales_invoice_id = :'sr_id'), 1, 'collection recorded exactly once');
select t.eq((select count(*) from notification_failures where done_at is null), 1, 'recorded for retry: the invoice (its same-transaction payment adds nothing to announce)');
select t.eq((select count(*) from notifications), 0, 'nothing delivered yet');

-- retries that still fail neither throw nor lose the record
select t.as_user('10400000-0000-0000-0000-000000000001');
select t.eq(process_notification_retries(:'org_id'), 1, 'retry while still broken: it stays pending');
select t.as_owner();
select t.ok((select bool_and(attempts = 1 and done_at is null and error is not null) from notification_failures), 'attempts counted, error kept');

alter table notifications drop constraint tmp_break;
select t.as_user('10400000-0000-0000-0000-000000000001');
select t.eq(process_notification_retries(:'org_id'), 0, 'cause fixed: retry clears everything');
select t.as_owner();
select t.eq((select count(*) from notifications where type = 'warehouse_dispatch_needed' and payload->>'invoice_number' = 'S-R'), 2, 'storekeepers got the task');
select t.eq((select count(*) from notifications where type = 'sales_invoice_created'), 1, 'owner got the invoice (rep is the actor)');
select t.eq((select count(*) from notifications where type in ('customer_payment', 'rep_payment')), 0, 'the payment taken with the invoice is NOT announced separately, even on retry');
select t.eq((select count(*) from notification_failures where done_at is null), 0, 'nothing pending');
select t.as_user('10400000-0000-0000-0000-000000000001');
select process_notification_retries(:'org_id');
select t.as_owner();
select t.eq((select count(*) from notifications), 3, 'running retries again creates no duplicates');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), :stock_before::numeric - 4, 'stock still untouched by notifications / retries');

-- a failure that never recovers stops after 10 attempts instead of looping forever, and stays visible
alter table notifications add constraint tmp_break check (false) not valid;
select t.as_user('10400000-0000-0000-0000-000000000004');
select create_sales_invoice(:'org_id', :'c', :'w', 'S-X', '2026-02-11', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 1, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset sx_
select t.as_user('10400000-0000-0000-0000-000000000001');
select process_notification_retries(:'org_id') from generate_series(1, 12);
select t.as_owner();
select t.eq((select attempts from notification_failures where ref_id = :'sx_id'), 10, 'attempts stop at 10');
select t.eq((select count(*) from notification_failures where done_at is null), 1, 'the record stays for an operator');
alter table notifications drop constraint tmp_break;

-- =====================================================================
-- C. Who may call it
-- =====================================================================
select t.as_user('10400000-0000-0000-0000-000000000005');
select t.throws(format('select process_notification_retries(%L)', :'org_id'), 'لست عضوًا', 'an outsider cannot trigger retries');
select t.throws('select * from notification_failures', 'permission denied', 'nor read the failure log');
select t.as_user('10400000-0000-0000-0000-000000000002');
select t.throws('select * from notification_failures', 'permission denied', 'a storekeeper cannot read it either');
select t.ok(process_notification_retries(:'org_id') >= 0, 'but any member may run the retry (it only builds notifications)');
select t.as_anon();
select t.throws(format('select process_notification_retries(%L)', :'org_id'), 'permission denied', 'anonymous: no');
select t.as_owner();
