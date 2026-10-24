-- 0046: stored, role-scoped notifications.
-- Covers: who is notified of what (owner / storekeeper / rep), the storekeeper's no-money guarantee, read vs
-- resolved, mark one / mark all, partial dispatch & receiving (remaining quantities), returns, payments,
-- shortage reports, de-duplication, RLS / role isolation (also after a role change), cross-organization
-- isolation, that a notification failure never aborts a sale, and that stock is never deducted twice.
-- (The test-only auto-confirm trigger is OFF: everything goes through the real confirm_* RPCs.)

\set ON_ERROR_STOP on
select t.autoconfirm_off();

select t.as_owner();
insert into auth.users (id, email) values
  ('10300000-0000-0000-0000-000000000001', 'owner1@ntf.test'),
  ('10300000-0000-0000-0000-000000000002', 'owner2@ntf.test'),
  ('10300000-0000-0000-0000-000000000003', 'keeper1@ntf.test'),
  ('10300000-0000-0000-0000-000000000004', 'keeper2@ntf.test'),
  ('10300000-0000-0000-0000-000000000005', 'rep1@ntf.test'),
  ('10300000-0000-0000-0000-000000000006', 'rep2@ntf.test'),
  ('10300000-0000-0000-0000-000000000007', 'other-org-owner@ntf.test');

select t.as_user('10300000-0000-0000-0000-000000000001');
select create_organization('شركة الإشعارات', 'x', 'EG', 'EGP', 'ar',
  array['products','warehouses','customers','suppliers','sales','purchases','inventory','representatives','treasury','reports']) as id \gset org_
select t.as_user('10300000-0000-0000-0000-000000000007');
select create_organization('شركة أخرى', 'x', 'EG', 'EGP', 'ar', array['products','sales','customers']) as id \gset oth_

select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', u.id, r.id, 'active'
from (values ('10300000-0000-0000-0000-000000000002'::uuid, 'owner'), ('10300000-0000-0000-0000-000000000003', 'warehouse'),
             ('10300000-0000-0000-0000-000000000004', 'warehouse'), ('10300000-0000-0000-0000-000000000005', 'sales'),
             ('10300000-0000-0000-0000-000000000006', 'sales')) u(id, k)
join roles r on r.key = u.k and r.organization_id is null;

select t.as_user('10300000-0000-0000-0000-000000000001');
insert into warehouses (organization_id, name) values (:'org_id', 'المخزن الرئيسي') returning id as w \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد النيل') returning id as s \gset
insert into products (organization_id, name, unit) values (:'org_id', 'صنف أ', 'قطعة') returning id as p \gset
insert into products (organization_id, name, unit) values (:'org_id', 'صنف ب', 'كرتونة') returning id as p2 \gset
insert into product_prices (organization_id, product_id, selling_price) values (:'org_id', :'p', 20), (:'org_id', :'p2', 50);
insert into product_costs (product_id, cost) values (:'p', 8), (:'p2', 30);
insert into sales_representatives (organization_id, name, user_id, commission_basis, commission_rate) values (:'org_id', 'مندوب ١', '10300000-0000-0000-0000-000000000005', 'net_sales', 5) returning id as rep1 \gset
insert into sales_representatives (organization_id, name, user_id, commission_basis, commission_rate) values (:'org_id', 'مندوب ٢', '10300000-0000-0000-0000-000000000006', 'net_sales', 5) returning id as rep2 \gset
insert into customers (organization_id, name, sales_rep_id) values (:'org_id', 'عميل المندوب ١', :'rep1') returning id as c1 \gset
insert into customers (organization_id, name, sales_rep_id) values (:'org_id', 'عميل المندوب ٢', :'rep2') returning id as c2 \gset

-- Opening stock the OLD way (auto-confirmed): 200 x p, 100 x p2.  Nobody must be notified about legacy-style setup noise
-- beyond what a real purchase produces, so we clear the table afterwards and start every scenario from zero.
select t.as_owner();
select t.autoconfirm_on();
select t.as_user('10300000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'s', :'w', 'OPEN-1', '2026-01-01',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 200, 'unit_cost', 8, 'discount', 0),
                    jsonb_build_object('product_id', :'p2', 'quantity', 100, 'unit_cost', 30, 'discount', 0)), 0, 0, 0, 'نقدًا', null) as id \gset open_
select t.as_owner();
select t.autoconfirm_off();
delete from notifications;
select t.eq((select count(*) from notifications), 0, 'start: empty notification table');

-- convenient counters (run as the table owner, who bypasses RLS)
create or replace function t.n(p_user text, p_type text) returns bigint language sql as $$
  select count(*) from notifications where recipient_user_id = ('10300000-0000-0000-0000-00000000000' || p_user)::uuid and type = p_type
$$;
create or replace function t.nall(p_user text) returns bigint language sql as $$
  select count(*) from notifications where recipient_user_id = ('10300000-0000-0000-0000-00000000000' || p_user)::uuid
$$;
grant execute on function t.n(text, text), t.nall(text) to authenticated;

-- =====================================================================
-- 1. A REP posts a sale (100 collected at the counter)
-- =====================================================================
select t.as_user('10300000-0000-0000-0000-000000000005');
select create_sales_invoice(:'org_id', :'c1', :'w', 'S-1', '2026-02-01',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 5, 'unit_price', 20, 'discount', 0),
                    jsonb_build_object('product_id', :'p2', 'quantity', 2, 'unit_price', 50, 'discount', 0)), 0, 0, 100, 'نقدًا', null, null) as id \gset s1_
select t.as_owner();
select t.eq(t.n('1', 'sales_invoice_created'), 1, 'owner 1 is told about the rep''s invoice');
select t.eq(t.n('2', 'sales_invoice_created'), 1, 'owner 2 too (every owner)');
select t.eq((select (payload->>'total')::numeric from notifications where recipient_user_id = '10300000-0000-0000-0000-000000000001' and type = 'sales_invoice_created'), 200, 'the owner sees the invoice total');
select t.eq((select (payload->>'amount_paid')::numeric from notifications where recipient_user_id = '10300000-0000-0000-0000-000000000001' and type = 'sales_invoice_created'), 100, 'and what was paid');
select t.eq_text((select payload->>'by' from notifications where recipient_user_id = '10300000-0000-0000-0000-000000000001' and type = 'sales_invoice_created'), 'مندوب ١ (rep1@ntf.test)', 'and who did it: name + email');
select t.eq(t.nall('5'), 0, 'the rep is not notified about his own action');
select t.eq(t.nall('6'), 0, 'another rep hears nothing about it');
select t.eq(t.n('3', 'warehouse_dispatch_needed'), 1, 'storekeeper 1 gets a dispatch task');
select t.eq(t.n('4', 'warehouse_dispatch_needed'), 1, 'storekeeper 2 too');
select t.eq(t.n('1', 'customer_payment'), 0, 'the payment taken with the invoice is NOT a second notification');
select t.eq((select jsonb_array_length(payload->'lines') from notifications where recipient_user_id = '10300000-0000-0000-0000-000000000003' and type = 'warehouse_dispatch_needed'), 2, 'the task lists both items');
select t.eq((select sum((l->>'remaining')::numeric) from notifications n, jsonb_array_elements(n.payload->'lines') l where n.recipient_user_id = '10300000-0000-0000-0000-000000000003'), 7, 'with their quantities (5 + 2)');
select t.ok((select resolved_at is null and read_at is null from notifications where recipient_user_id = '10300000-0000-0000-0000-000000000003'), 'new task: unread and open');

-- the storekeeper payload holds no money and no party, whatever the keys
select t.ok((select bool_and(_ntf_warehouse_payload_ok(payload)) from notifications where type like 'warehouse%'), 'storekeeper payload passes the whitelist');
select t.ok((select not bool_or(payload::text ~* '(total|price|amount|balance|cost|discount|customer|supplier|عميل|مورد)') from notifications where type like 'warehouse%'), 'storekeeper payload has no financial or party field');
select t.ok((select not bool_or(title ~ '[0-9]+\.[0-9]{2}') from notifications where type like 'warehouse%'), 'nor a money figure in the title');

-- =====================================================================
-- 2. Row-level security: you only ever read your own rows, of your own role's types
-- =====================================================================
select t.as_user('10300000-0000-0000-0000-000000000003');
select t.eq((select count(*) from notifications), 1, 'storekeeper 1 reads exactly his own task');
select t.ok((select bool_and(type like 'warehouse%') from notifications), 'and only storekeeper types');
select t.eq((select count(*) from list_my_notifications(:'org_id')), 1, 'the list function agrees');
select t.throws('update notifications set read_at = now()', 'permission denied', 'no direct UPDATE');
select t.throws('delete from notifications', 'permission denied', 'no direct DELETE');
select t.throws($q$insert into notifications (organization_id, recipient_user_id, type, title, dedupe_key) values ('$q$ || :'org_id' || $q$', '10300000-0000-0000-0000-000000000003', 'warehouse_dispatch_needed', 'forged', 'forged')$q$, 'permission denied', 'no forged INSERT');
select t.throws(format('select list_my_notifications(%L)', :'oth_id'), 'لست عضوًا', 'cannot list another organization''s notifications');
select t.as_user('10300000-0000-0000-0000-000000000006');
select t.eq((select count(*) from notifications), 0, 'rep 2 reads nothing');
select t.as_user('10300000-0000-0000-0000-000000000007');
select t.eq((select count(*) from notifications), 0, 'an owner of ANOTHER organization reads nothing');
select t.as_anon();
select t.throws('select count(*) from notifications', 'permission denied', 'anonymous callers have no access');
select t.throws(format('select my_unread_notification_count(%L)', :'org_id'), 'permission denied', 'nor the RPCs');

-- =====================================================================
-- 3. Read is not done:  open / mark one / mark all / idempotence / not someone else's
-- =====================================================================
select t.as_user('10300000-0000-0000-0000-000000000001');
select t.eq(my_unread_notification_count(:'org_id'), 1, 'owner 1: one unread');
select id as n_owner from list_my_notifications(:'org_id') limit 1 \gset
select t.as_user('10300000-0000-0000-0000-000000000003');
select t.eq(my_unread_notification_count(:'org_id'), 1, 'storekeeper 1: one unread (the task)');
select id as n_keeper from list_my_notifications(:'org_id') limit 1 \gset
select t.eq(mark_notification_read(:'org_id', :'n_owner'), 1, 'marking SOMEONE ELSE''s notification changes nothing for me (still 1 unread)');
select t.as_owner();
select t.ok((select read_at is null from notifications where id = :'n_owner'), 'and the owner''s row is still unread');
select t.as_user('10300000-0000-0000-0000-000000000003');
select t.eq(mark_notification_read(:'org_id', :'n_keeper'), 0, 'marking mine: unread count drops to 0');
select t.eq(mark_notification_read(:'org_id', :'n_keeper'), 0, 'marking it again is harmless');
select t.as_owner();
select t.ok((select read_at is not null and resolved_at is null from notifications where id = :'n_keeper'), 'READ does not mean DONE: the task is still open');
select t.eq_text((select dispatch_status from sales_invoices where id = :'s1_id'), 'pending', 'and the invoice still waits for dispatch');
select t.eq(t.n('4', 'warehouse_dispatch_needed'), 1, 'storekeeper 2 still has his own, unaffected');
select t.ok((select read_at is null from notifications where recipient_user_id = '10300000-0000-0000-0000-000000000004'), 'storekeeper 2''s card is still unread');

-- =====================================================================
-- 4. Partial dispatch, then the rest.  Stock is deducted exactly once.
-- =====================================================================
select t.as_user('10300000-0000-0000-0000-000000000003');
select confirm_sales_dispatch(:'org_id', :'s1_id',
  jsonb_build_array(jsonb_build_object('line_id', (select (l->>'line_id') from warehouse_sales_orders(:'org_id', 'open') o, jsonb_array_elements(o.lines) l where l->>'product_name' = 'صنف أ'), 'quantity', 3)), 'أول دفعة') as j \gset d1_
select t.eq_text((:'d1_j'::jsonb) ->> 'status', 'partial', 'partial dispatch');
select t.as_owner();
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 197, 'stock: only the 3 dispatched units left the shelf');
select t.eq(t.n('1', 'dispatch_confirmed'), 1, 'owner 1 is told about the partial dispatch');
select t.eq(t.n('2', 'dispatch_confirmed'), 1, 'owner 2 too');
select t.eq_text((select payload->>'status' from notifications where recipient_user_id = '10300000-0000-0000-0000-000000000001' and type = 'dispatch_confirmed'), 'partial', 'it says partial');
select t.eq((select sum((x->>'qty')::numeric) from notifications n, jsonb_array_elements(n.payload->'done') x where n.recipient_user_id = '10300000-0000-0000-0000-000000000001' and n.type = 'dispatch_confirmed'), 3, 'with what was dispatched (3)');
select t.eq((select sum((x->>'remaining')::numeric) from notifications n, jsonb_array_elements(n.payload->'left') x where n.recipient_user_id = '10300000-0000-0000-0000-000000000001' and n.type = 'dispatch_confirmed'), 4, 'and what is left (2 of a, 2 of b = 4)');
select t.eq(t.n('5', 'rep_dispatch_update'), 1, 'the invoice''s rep is told it was partly dispatched');
select t.eq(t.n('6', 'rep_dispatch_update'), 0, 'the other rep is not');
select t.eq(t.nall('4') - t.n('4', 'warehouse_dispatch_needed'), 0, 'storekeeper 2 gets no extra notification for his colleague''s dispatch');
-- the task cards follow the remaining quantities, for BOTH storekeepers
select t.eq((select sum((l->>'remaining')::numeric) from notifications n, jsonb_array_elements(n.payload->'lines') l where n.recipient_user_id = '10300000-0000-0000-0000-000000000004'), 4, 'storekeeper 2''s card now shows 4 remaining');
select t.eq((select sum((l->>'remaining')::numeric) from notifications n, jsonb_array_elements(n.payload->'lines') l where n.recipient_user_id = '10300000-0000-0000-0000-000000000003'), 4, 'and so does storekeeper 1''s');
select t.ok((select bool_and(resolved_at is null) from notifications where type = 'warehouse_dispatch_needed'), 'still open');
select t.ok((select read_at is null from notifications where recipient_user_id = '10300000-0000-0000-0000-000000000004'), 'a colleague''s progress does not mark MY card read');

-- the rest, then a repeat
select t.as_user('10300000-0000-0000-0000-000000000003');
select confirm_sales_dispatch(:'org_id', :'s1_id') as j \gset d2_
select t.eq_text((:'d2_j'::jsonb) ->> 'status', 'dispatched', 'second confirmation completes it');
select t.throws(format('select confirm_sales_dispatch(%L, %L)', :'org_id', :'s1_id'), 'تم صرف', 'a third attempt is refused');
select t.as_owner();
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 195, 'stock: 5 units gone in total, never more');
select t.eq((select quantity from inventory_stock where product_id = :'p2' and warehouse_id = :'w'), 98, 'and 2 of the second item');
select t.eq(t.n('1', 'dispatch_confirmed'), 2, 'owner 1 has one notification per confirmation (2), none for the refused repeat');
select t.ok((select bool_and(resolved_at is not null) from notifications where type = 'warehouse_dispatch_needed'), 'both task cards are now DONE');
select t.ok((select bool_and(sum_left = 0) from (select (select sum((l->>'remaining')::numeric) from jsonb_array_elements(n.payload->'lines') l) sum_left from notifications n where n.type = 'warehouse_dispatch_needed') z), 'with nothing remaining');
select t.eq_text((select payload->>'status' from notifications where recipient_user_id = '10300000-0000-0000-0000-000000000003' and type = 'warehouse_dispatch_needed'), 'dispatched', 'status follows the invoice');
select t.ok((select read_at is not null from notifications where recipient_user_id = '10300000-0000-0000-0000-000000000003'), 'the keeper who acted has the card marked read');
select t.ok((select read_at is null from notifications where recipient_user_id = '10300000-0000-0000-0000-000000000004'), 'DONE does not mean READ: the colleague''s card is still unread');
select t.eq(t.n('5', 'rep_dispatch_update'), 2, 'the rep followed both steps');
-- the dispatch does not touch money
select t.eq((select total from sales_invoices where id = :'s1_id'), 200, 'invoice total unchanged by notifications');

-- =====================================================================
-- 5. Owner-created invoice for a rep: the REP is told, the owner (actor) is not
-- =====================================================================
select t.as_user('10300000-0000-0000-0000-000000000001');
select create_sales_invoice(:'org_id', :'c1', :'w', 'S-2', '2026-02-02',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 10, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, :'rep1') as id \gset s2_
select t.as_owner();
select t.eq(t.n('5', 'rep_invoice_created'), 1, 'rep 1 is told an invoice was posted for him');
select t.eq((select (payload->>'total')::numeric from notifications where recipient_user_id = '10300000-0000-0000-0000-000000000005' and type = 'rep_invoice_created'), 200, 'with the invoice total (his own invoice)');
select t.eq(t.n('1', 'sales_invoice_created'), 1, 'owner 1 is not told about his own invoice (still only the rep''s S-1)');
select t.eq(t.n('2', 'sales_invoice_created'), 2, 'but owner 2 is (another owner acted)');
select t.eq(t.n('6', 'rep_invoice_created'), 0, 'rep 2 hears nothing');

-- =====================================================================
-- 6. Purchases: posted by owner 2 -> owner 1 + storekeepers; receiving in two steps
-- =====================================================================
select t.as_user('10300000-0000-0000-0000-000000000002');
select create_purchase_invoice(:'org_id', :'s', :'w', 'P-1', '2026-02-03',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 50, 'unit_cost', 10, 'discount', 0)), 0, 0, 20, 'نقدًا', null) as id \gset pi1_
select t.as_owner();
select t.eq(t.n('1', 'purchase_invoice_created'), 1, 'owner 1 is told about the purchase owner 2 posted');
select t.eq(t.n('2', 'purchase_invoice_created'), 0, 'owner 2 (actor) is not');
select t.eq(t.n('1', 'supplier_payment'), 0, 'the payment taken with the purchase is not a second notification');
select t.eq(t.n('3', 'warehouse_receipt_needed'), 1, 'storekeeper 1 gets a receiving task');
select t.ok((select not (payload::text ~* '(total|cost|amount|supplier|مورد)') from notifications where recipient_user_id = '10300000-0000-0000-0000-000000000003' and type = 'warehouse_receipt_needed'), 'with no cost, total or supplier');
select t.as_user('10300000-0000-0000-0000-000000000004');
select confirm_purchase_receipt(:'org_id', :'pi1_id', jsonb_build_array(jsonb_build_object('line_id', (select (l->>'line_id') from warehouse_purchase_orders(:'org_id', 'open') o, jsonb_array_elements(o.lines) l limit 1), 'quantity', 30))) as j \gset r1_
select t.as_owner();
select t.eq(t.n('1', 'receipt_confirmed'), 1, 'owner 1 is told about the partial receipt');
select t.eq((select sum((x->>'remaining')::numeric) from notifications n, jsonb_array_elements(n.payload->'left') x where n.recipient_user_id = '10300000-0000-0000-0000-000000000001' and n.type = 'receipt_confirmed'), 20, 'with 20 remaining');
select t.eq((select sum((l->>'remaining')::numeric) from notifications n, jsonb_array_elements(n.payload->'lines') l where n.recipient_user_id = '10300000-0000-0000-0000-000000000003' and n.type = 'warehouse_receipt_needed'), 20, 'the open task shows 20 remaining');
select t.as_user('10300000-0000-0000-0000-000000000004');
select confirm_purchase_receipt(:'org_id', :'pi1_id') as j \gset r2_
select t.as_owner();
select t.ok((select bool_and(resolved_at is not null) from notifications where type = 'warehouse_receipt_needed'), 'receiving task is DONE after the second receipt');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 245, 'stock: 195 + the 50 received (once)');

-- =====================================================================
-- 7. Payments (owner 2 collects from rep 1's customer, pays the supplier)
-- =====================================================================
select t.as_user('10300000-0000-0000-0000-000000000002');
select record_customer_collection(:'org_id', :'c1', null, 50, '2026-02-10', 'نقدًا', null, null) as id \gset col1_
select record_customer_collection(:'org_id', :'c2', null, 25, '2026-02-10', 'نقدًا', null, null) as id \gset col2_
select record_supplier_payment(:'org_id', :'s', null, 40, '2026-02-10', 'نقدًا', null, null) as id \gset sp1_
select t.as_owner();
select t.eq(t.n('1', 'customer_payment'), 2, 'owner 1 is told about both collections');
select t.eq(t.n('2', 'customer_payment'), 0, 'owner 2 (the actor) is not');
select t.eq(t.n('5', 'rep_payment'), 1, 'rep 1 is told about the collection from HIS customer');
select t.eq(t.n('6', 'rep_payment'), 1, 'rep 2 about his customer');
select t.eq((select (payload->>'amount')::numeric from notifications where recipient_user_id = '10300000-0000-0000-0000-000000000005' and type = 'rep_payment'), 50, 'rep 1 sees 50, not rep 2''s 25');
select t.ok((select not (payload ? 'by') from notifications where type = 'rep_payment' limit 1), 'a rep is not shown who processed it internally');
select t.eq(t.n('1', 'supplier_payment'), 1, 'owner 1 is told about the supplier payment');
select t.eq(t.nall('3') + t.nall('4') - t.n('3', 'warehouse_dispatch_needed') - t.n('4', 'warehouse_dispatch_needed') - t.n('3', 'warehouse_receipt_needed') - t.n('4', 'warehouse_receipt_needed'), 0, 'storekeepers get no payment notifications');

-- =====================================================================
-- 8. Returns: a return on a not-yet-dispatched invoice releases the task
-- =====================================================================
select t.as_user('10300000-0000-0000-0000-000000000005');
select create_sales_invoice(:'org_id', :'c1', :'w', 'S-3', '2026-02-11',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 4, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset s3_
select t.as_owner();
select t.eq(t.n('3', 'warehouse_dispatch_needed'), 3, 'keeper 1 now has S-1, S-2, S-3 cards');
select t.as_user('10300000-0000-0000-0000-000000000002');
select create_sales_return(:'org_id', :'s3_id', '2026-02-12', '[]'::jsonb, 0, null, true, 'resalable') as id \gset sr_
select t.as_owner();
select t.ok((select resolved_at is not null from notifications where recipient_user_id = '10300000-0000-0000-0000-000000000003' and type = 'warehouse_dispatch_needed' and payload->>'invoice_number' = 'S-3'), 'full return before dispatch: the storekeeper''s task is closed');
select t.eq_text((select payload->>'status' from notifications where recipient_user_id = '10300000-0000-0000-0000-000000000003' and type = 'warehouse_dispatch_needed' and payload->>'invoice_number' = 'S-3'), 'cancelled', 'as cancelled');
select t.eq(t.n('1', 'sales_return_created'), 1, 'owner 1 is told about the return');
select t.eq(t.n('5', 'rep_return'), 1, 'the invoice''s rep is told');
select t.eq(t.n('6', 'rep_return'), 0, 'the other rep is not');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 245, 'stock untouched by a return of never-dispatched goods');

-- =====================================================================
-- 9. Shortage reports
-- =====================================================================
select t.as_user('10300000-0000-0000-0000-000000000005');
select report_stock_shortage(:'org_id', :'p', :'w', 500, 'عميل مستني') as j \gset sh1_
select t.as_owner();
select t.eq(t.n('1', 'shortage_reported'), 1, 'owner 1 gets the shortage report');
select t.eq(t.n('2', 'shortage_reported'), 1, 'owner 2 too');
select t.eq(t.nall('3') + t.nall('4') - t.n('3', 'warehouse_dispatch_needed') - t.n('4', 'warehouse_dispatch_needed') - t.n('3', 'warehouse_receipt_needed') - t.n('4', 'warehouse_receipt_needed') - t.n('3', 'warehouse_task_cancelled') - t.n('4', 'warehouse_task_cancelled'), 0, 'storekeepers are not told about shortage reports');
select t.as_user('10300000-0000-0000-0000-000000000005');
select report_stock_shortage(:'org_id', :'p', :'w', 500, 'عميل مستني') as j \gset sh1b_
select t.as_owner();
select t.eq(t.n('1', 'shortage_reported'), 1, 'the identical report again creates NO new notification');
select t.as_user('10300000-0000-0000-0000-000000000005');
select report_stock_shortage(:'org_id', :'p', :'w', 900, 'زادت الكمية') as j \gset sh2_
select t.as_owner();
select t.eq(t.n('1', 'shortage_reported'), 2, 'a changed need is a new report (new notification)');
select t.eq((select count(*) from notifications where type = 'shortage_reported' and recipient_user_id = '10300000-0000-0000-0000-000000000001' and resolved_at is not null), 1, 'and the replaced report''s card is closed');
select t.as_user('10300000-0000-0000-0000-000000000001');
select set_stock_shortage_status(:'org_id', ((:'sh2_j')::jsonb ->> 'report_id')::uuid, 'in_progress', 'جاري التوريد') as j \gset st1_
select t.as_owner();
select t.eq(t.n('5', 'shortage_status'), 1, 'the rep is told it is being prepared');
select t.eq(t.n('6', 'shortage_status'), 0, 'the other rep is not');
-- 0052: closing by hand needs sellable stock covering the need (900): the quantity arrives from another source first
select t.as_owner();
select t.autoconfirm_on();
select t.as_user('10300000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'s', :'w', 'SRC-OTHER', '2026-02-12', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 1000, 'unit_cost', 8, 'discount', 0)), 0, 0, 0, 'نقدًا', null) as id \gset srco_
select t.as_owner();
select t.autoconfirm_off();
select t.as_user('10300000-0000-0000-0000-000000000001');
select set_stock_shortage_status(:'org_id', ((:'sh2_j')::jsonb ->> 'report_id')::uuid, 'resolved', null) as j \gset st2_
select t.as_owner();
select t.eq(t.n('5', 'shortage_status'), 2, 'and when it is provided');
select t.ok((select resolved_at is not null from notifications where recipient_user_id = '10300000-0000-0000-0000-000000000001' and type = 'shortage_reported' and entity_id = ((:'sh2_j')::jsonb ->> 'report_id')::uuid), 'the owner''s shortage card is DONE once provided');
select t.eq(t.n('1', 'shortage_status'), 0, 'the owner who changed the status is not notified of it');

-- =====================================================================
-- 10. Role isolation survives a role change
-- =====================================================================
select t.as_user('10300000-0000-0000-0000-000000000002');
select t.ok((select count(*) from notifications) > 0, 'owner 2 reads his notifications');
select t.as_owner();
update organization_users set role_id = (select id from roles where key = 'warehouse' and organization_id is null)
where organization_id = :'org_id' and user_id = '10300000-0000-0000-0000-000000000002';
select t.as_user('10300000-0000-0000-0000-000000000002');
select t.eq((select count(*) from notifications where type <> 'role_changed'), 0, 'demoted to storekeeper: the old owner notifications (money!) are no longer readable');
select t.eq((select count(*) from list_my_notifications(:'org_id') where type <> 'role_changed'), 0, 'neither through the list function');
select t.eq(my_unread_notification_count(:'org_id'), 1, 'only the (0049) "your role changed" card is counted');
select t.as_owner();
update organization_users set role_id = (select id from roles where key = 'owner' and organization_id is null)
where organization_id = :'org_id' and user_id = '10300000-0000-0000-0000-000000000002';

-- =====================================================================
-- 11. De-duplication and a failure that must never abort a sale
-- =====================================================================
select t.as_owner();
select t.ok(_ntf_send(:'org_id', '10300000-0000-0000-0000-000000000001', null, 'customer_payment', 'اختبار', '/dashboard', 'x', null, '{}'::jsonb, 'dup-key'), 'first send inserts');
select t.ok(not _ntf_send(:'org_id', '10300000-0000-0000-0000-000000000001', null, 'customer_payment', 'اختبار', '/dashboard', 'x', null, '{}'::jsonb, 'dup-key'), 'same key again: nothing inserted');
select t.eq((select count(*) from notifications where dedupe_key = 'dup-key'), 1, 'exactly one row');
select t.ok(not _ntf_send(:'org_id', '10300000-0000-0000-0000-000000000003', null, 'customer_payment', 'اختبار', '/dashboard', 'x', null, '{}'::jsonb, 'wrong-role'), 'an owner-type notification is never delivered to a storekeeper');
select t.ok(not _ntf_send(:'org_id', '10300000-0000-0000-0000-000000000005', null, 'warehouse_dispatch_needed', 'اختبار', '/dashboard', 'x', null, '{"lines": []}'::jsonb, 'wrong-role2'), 'nor a storekeeper-type one to a rep');
select t.throws(format($q$select _ntf_send(%L, '10300000-0000-0000-0000-000000000003', null, 'warehouse_dispatch_needed', 'x', '/dashboard', 'sales', null, '{"total": 5}'::jsonb, 'bad-payload')$q$, :'org_id'), 'non-whitelisted', 'a money field in a storekeeper payload is refused');
select t.throws(format($q$select _ntf_send(%L, '10300000-0000-0000-0000-000000000001', null, 'customer_payment', 'x', 'https://evil.example', 'x', null, '{}'::jsonb, 'bad-href')$q$, :'org_id'), 'notifications_href_check', 'only in-app links are accepted');

-- break the notification insert on purpose: the sale must still be posted
alter table notifications add constraint tmp_break check (false) not valid;
select t.as_user('10300000-0000-0000-0000-000000000005');
select create_sales_invoice(:'org_id', :'c1', :'w', 'S-FAIL', '2026-02-20',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 1, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset sf_
select t.as_owner();
alter table notifications drop constraint tmp_break;
select t.ok((select exists (select 1 from sales_invoices where id = :'sf_id')), 'a broken notification does not abort the sale');
select t.eq((select count(*) from notifications where payload->>'invoice_number' = 'S-FAIL'), 0, 'no notification could be written at that moment');
select t.eq((select count(*) from notification_failures where kind = 'sales_invoice' and ref_id = :'sf_id' and done_at is null), 1, 'but the failure was RECORDED for retry (not lost)');
-- the cause is fixed; the retry delivers it, exactly once
select t.as_user('10300000-0000-0000-0000-000000000001');
select t.eq(process_notification_retries(:'org_id'), 0, 'retry: nothing left pending');
select t.as_owner();
select t.eq((select count(*) from notifications where payload->>'invoice_number' = 'S-FAIL'), 4, 'retry delivered: 2 owners + 2 storekeepers');
select t.eq((select count(*) from notification_failures where ref_id = :'sf_id' and done_at is not null), 1, 'and closed the record');
select t.as_user('10300000-0000-0000-0000-000000000001');
select t.eq(process_notification_retries(:'org_id'), 0, 'a second retry run');
select t.as_owner();
select t.eq((select count(*) from notifications where payload->>'invoice_number' = 'S-FAIL'), 4, 'creates no duplicates');
select t.eq(t.n('5', 'rep_invoice_created'), 1, 'the rep (actor of S-FAIL) was never notified about his own sale; only S-2 counts');
select t.eq((select total from sales_invoices where id = :'sf_id'), 20, 'its totals are intact');

-- =====================================================================
-- 12. Mark all
-- =====================================================================
select t.as_user('10300000-0000-0000-0000-000000000001');
select t.ok(my_unread_notification_count(:'org_id') > 3, 'owner 1 has several unread');
select t.eq(mark_all_notifications_read(:'org_id'), 0, 'mark all -> 0 unread');
select t.eq((select count(*) from list_my_notifications(:'org_id', 'unread')), 0, 'the unread filter is empty');
select t.ok((select count(*) from list_my_notifications(:'org_id', 'all')) > 3, 'but the history is still there');
select t.ok((select count(*) filter (where resolved_at is null) from list_my_notifications(:'org_id')) >= 0 and (select count(*) filter (where resolved_at is not null) from list_my_notifications(:'org_id')) >= 1, 'resolved state is independent of read state');
select t.as_user('10300000-0000-0000-0000-000000000004');
select t.ok(my_unread_notification_count(:'org_id') >= 1, 'storekeeper 2 is unaffected by owner 1''s mark-all');
select t.eq(mark_all_notifications_read(:'org_id'), 0, 'his own mark-all works');
select t.as_owner();
select t.ok((select count(*) from notifications where recipient_user_id = '10300000-0000-0000-0000-000000000005' and read_at is null) > 0, 'and never touched the rep''s');

-- the keyset paging: a smaller limit returns the newest first and p_before continues after it
select t.as_user('10300000-0000-0000-0000-000000000001');
select t.eq((select count(*) from list_my_notifications(:'org_id', 'all', 2)), 2, 'limit works');
select t.ok((select (select created_at from list_my_notifications(:'org_id', 'all', 1)) >= (select max(created_at) from list_my_notifications(:'org_id', 'all', 100) where id not in (select id from list_my_notifications(:'org_id', 'all', 1)))), 'newest first');
select t.as_owner();
