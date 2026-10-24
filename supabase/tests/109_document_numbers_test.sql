-- 0053: every invoice has a real, stable number; notification links and search open the RIGHT invoice.
-- Covers: system-issued numbers on every insert path (RPC and direct), typed numbers kept / trimmed / de-duplicated
-- (sales per organization, purchases per supplier), gap-free numbering after a rolled-back save, the double-submit
-- guard, immutability, NOT NULL, notifications for owner / storekeeper / rep (stored number in title and payload,
-- link by invoice id, never an id fragment, never a text search), that each link really opens that invoice for the
-- role that receives it (and not for a rep who does not own it), global search (title = number, literal wildcards,
-- partial numbers) and cross-organization isolation.

\set ON_ERROR_STOP on
select t.autoconfirm_off();

select t.as_owner();
insert into auth.users (id, email) values
  ('10900000-0000-0000-0000-000000000001', 'owner@num.test'),
  ('10900000-0000-0000-0000-000000000003', 'keeper@num.test'),
  ('10900000-0000-0000-0000-000000000005', 'rep1@num.test'),
  ('10900000-0000-0000-0000-000000000006', 'rep2@num.test'),
  ('10900000-0000-0000-0000-000000000007', 'other-owner@num.test');

select t.as_user('10900000-0000-0000-0000-000000000001');
select create_organization('شركة الأرقام', 'x', 'EG', 'EGP', 'ar',
  array['products','warehouses','customers','suppliers','sales','purchases','inventory','representatives','treasury','reports']) as id \gset org_
select t.as_user('10900000-0000-0000-0000-000000000007');
select create_organization('شركة أخرى', 'x', 'EG', 'EGP', 'ar', array['products','warehouses','customers','suppliers','sales','purchases']) as id \gset oth_

select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', u.id, r.id, 'active'
from (values ('10900000-0000-0000-0000-000000000003'::uuid, 'warehouse'), ('10900000-0000-0000-0000-000000000005', 'sales'),
             ('10900000-0000-0000-0000-000000000006', 'sales')) u(id, k)
join roles r on r.key = u.k and r.organization_id is null;

select t.as_user('10900000-0000-0000-0000-000000000001');
insert into warehouses (organization_id, name) values (:'org_id', 'المخزن') returning id as w \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد 1') returning id as s1 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد 2') returning id as s2 \gset
insert into products (organization_id, name, unit) values (:'org_id', 'صنف', 'قطعة') returning id as p \gset
insert into product_prices (organization_id, product_id, selling_price) values (:'org_id', :'p', 20);
insert into product_costs (product_id, cost) values (:'p', 8);
insert into sales_representatives (organization_id, name, user_id, commission_basis, commission_rate) values (:'org_id', 'مندوب 1', '10900000-0000-0000-0000-000000000005', 'net_sales', 5) returning id as rep1 \gset
insert into sales_representatives (organization_id, name, user_id, commission_basis, commission_rate) values (:'org_id', 'مندوب 2', '10900000-0000-0000-0000-000000000006', 'net_sales', 5) returning id as rep2 \gset
insert into customers (organization_id, name, sales_rep_id) values (:'org_id', 'عميل 1', :'rep1') returning id as c1 \gset
insert into customers (organization_id, name, sales_rep_id) values (:'org_id', 'عميل 2', :'rep2') returning id as c2 \gset

-- opening stock (auto-confirmed), then a clean notification table
select t.as_owner(); select t.autoconfirm_on(); select t.as_user('10900000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'s1', :'w', 'OPEN-1', '2026-01-01',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 500, 'unit_cost', 8, 'discount', 0)), 0, 0, 0, 'نقدًا', null) as id \gset open_
select t.as_owner(); select t.autoconfirm_off();
delete from notifications;

create or replace function t.items(p_org uuid, p_qty numeric) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('product_id', (select id from products where organization_id = p_org limit 1), 'quantity', p_qty, 'unit_price', 20, 'discount', 0))
$$;
create or replace function t.pitems(p_org uuid, p_qty numeric) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('product_id', (select id from products where organization_id = p_org limit 1), 'quantity', p_qty, 'unit_cost', 8, 'discount', 0))
$$;
grant execute on function t.items(uuid, numeric), t.pitems(uuid, numeric) to authenticated;

-- =====================================================================
-- 1. Numbers are issued by the system, whatever the path
-- =====================================================================
select t.as_user('10900000-0000-0000-0000-000000000005');
select create_sales_invoice(:'org_id', :'c1', :'w', '', '2026-02-01', t.items(:'org_id', 5), 0, 0, 0, 'نقدًا', null, null) as id \gset a_
select t.as_user('10900000-0000-0000-0000-000000000005');
select create_sales_invoice(:'org_id', :'c1', :'w', null, '2026-02-02', t.items(:'org_id', 3), 0, 0, 0, 'نقدًا', null, null) as id \gset b_
select t.as_owner();
select invoice_number as a_no from sales_invoices where id = :'a_id' \gset
select invoice_number as b_no from sales_invoices where id = :'b_id' \gset
select t.ok(:'a_no' ~ '^S-[0-9]{6}$', 'a sales invoice saved with an empty number gets a system number (S-000000 style)');
select t.ok(:'b_no' ~ '^S-[0-9]{6}$' and :'b_no' <> :'a_no', 'a NULL number gets one too, and it is a different one');
select t.eq((substr(:'b_no', 3))::numeric - (substr(:'a_no', 3))::numeric, 1, 'numbers are consecutive');

-- a raw insert (service role / import / future code path) is numbered as well: the rule lives in the table
insert into sales_invoices (organization_id, customer_id, warehouse_id, invoice_date) values (:'org_id', :'c1', :'w', '2026-02-03') returning invoice_number as raw_no \gset
select t.ok(:'raw_no' ~ '^S-[0-9]{6}$', 'a direct insert without a number is numbered by the database');
insert into sales_invoices (organization_id, customer_id, warehouse_id, invoice_date, invoice_number) values (:'org_id', :'c1', :'w', '2026-02-10', '   ') returning invoice_number as blank_no \gset
select t.ok(:'blank_no' ~ '^S-[0-9]{6}$', 'whitespace only counts as empty');

select t.as_user('10900000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'s1', :'w', '', '2026-02-04', t.pitems(:'org_id', 10), 0, 0, 0, 'نقدًا', null) as id \gset pa_
select t.as_owner();
select invoice_number as pa_no from purchase_invoices where id = :'pa_id' \gset
select t.ok(:'pa_no' ~ '^P-[0-9]{6}$', 'a purchase invoice with an empty number gets P-000000 style');
select t.eq((select count(*) from sales_invoices where invoice_number is null or btrim(invoice_number) = ''), 0, 'no sales invoice anywhere is without a number');
select t.eq((select count(*) from purchase_invoices where invoice_number is null or btrim(invoice_number) = ''), 0, 'no purchase invoice anywhere is without a number');
select t.throws($$update sales_invoices set invoice_number = null where id = '$$ || :'a_id' || $$'$$, 'null value', 'the column cannot go back to NULL');

-- =====================================================================
-- 2. Typed numbers: kept (trimmed), never duplicated
-- =====================================================================
select t.as_user('10900000-0000-0000-0000-000000000005');
select create_sales_invoice(:'org_id', :'c1', :'w', '  A-77 ', '2026-02-05', t.items(:'org_id', 1), 0, 0, 0, 'نقدًا', null, null) as id \gset t_
select t.as_owner();
select t.eq_text((select invoice_number from sales_invoices where id = :'t_id'), 'A-77', 'a typed number is kept, trimmed');
select t.as_user('10900000-0000-0000-0000-000000000005');
select t.throws($$select create_sales_invoice('$$ || :'org_id' || $$', '$$ || :'c1' || $$', '$$ || :'w' || $$', 'a-77', '2026-02-06', t.items('$$ || :'org_id' || $$', 1), 0, 0, 0, 'نقدًا', null, null)$$,
  'مستخدم من قبل', 'the same typed number (any case) cannot be used twice for sales');
select t.as_user('10900000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'s1', :'w', 'SUP-100', '2026-02-07', t.pitems(:'org_id', 1), 0, 0, 0, 'نقدًا', null) as id \gset ps1_
select create_purchase_invoice(:'org_id', :'s2', :'w', 'SUP-100', '2026-02-07', t.pitems(:'org_id', 1), 0, 0, 0, 'نقدًا', null) as id \gset ps2_
select t.ok(:'ps1_id' <> :'ps2_id', 'two different suppliers may both have their own invoice SUP-100');
select t.throws($$select create_purchase_invoice('$$ || :'org_id' || $$', '$$ || :'s1' || $$', '$$ || :'w' || $$', 'sup-100', '2026-02-08', t.pitems('$$ || :'org_id' || $$', 1), 0, 0, 0, 'نقدًا', null)$$,
  'لنفس المورد', 'but the same supplier cannot repeat a number');

-- another organization: its own numbering, and the same typed number is fine there
select t.as_owner();
insert into customers (organization_id, name) values (:'oth_id', 'عميل خارجي') returning id as oc \gset
insert into warehouses (organization_id, name) values (:'oth_id', 'مخزن خارجي') returning id as ow \gset
insert into sales_invoices (organization_id, customer_id, warehouse_id, invoice_date, invoice_number) values (:'oth_id', :'oc', :'ow', '2026-02-05', 'A-77');
insert into sales_invoices (organization_id, customer_id, warehouse_id, invoice_date) values (:'oth_id', :'oc', :'ow', '2026-02-11') returning invoice_number as oth_no \gset
select t.eq_text(:'oth_no', 'S-000001', 'another organization starts its own sequence, and may reuse a typed number');

-- =====================================================================
-- 3. Gap-free, double-submit guard, frozen once issued
-- =====================================================================
select last_value as before_fail from document_counters where organization_id = :'org_id' and kind = 'sales_invoice' \gset
select t.as_user('10900000-0000-0000-0000-000000000005');
select t.throws($$select create_sales_invoice('$$ || :'org_id' || $$', '$$ || :'c1' || $$', '$$ || :'w' || $$', '', '2026-02-09', '[{"product_id":"00000000-0000-0000-0000-00000000dead","quantity":1,"unit_price":20,"discount":0}]'::jsonb, 0, 0, 0, 'نقدًا', null, null)$$,
  '', 'a save that fails is rejected');
select t.as_owner();
select t.eq((select last_value from document_counters where organization_id = :'org_id' and kind = 'sales_invoice'), :before_fail, 'a failed save does not burn a number (no gaps)');

select t.as_user('10900000-0000-0000-0000-000000000005');
select create_sales_invoice(:'org_id', :'c1', :'w', '', '2026-03-01', t.items(:'org_id', 1), 0, 0, 0, 'نقدًا', null, null) as id \gset d1_
select t.throws($$select create_sales_invoice('$$ || :'org_id' || $$', '$$ || :'c1' || $$', '$$ || :'w' || $$', '', '2026-03-01', t.items('$$ || :'org_id' || $$', 1), 0, 0, 0, 'نقدًا', null, null)$$,
  'تم تسجيل عملية مطابقة', 'double-clicking save on a numberless invoice is still caught');

-- the API role has no UPDATE on invoices, so test the trigger the way a future SECURITY DEFINER function acting for a
-- signed-in user would hit it: table owner, but carrying a signed-in user's claims
select t.as_owner();
select set_config('request.jwt.claims', json_build_object('sub', '10900000-0000-0000-0000-000000000001')::text, false);
select t.throws($$update sales_invoices set invoice_number = 'HACK-1' where id = '$$ || :'a_id' || $$'$$, 'لا يمكن تعديله', 'an issued number cannot be edited on behalf of a signed-in user (sales)');
select t.throws($$update purchase_invoices set invoice_number = 'HACK-2' where id = '$$ || :'pa_id' || $$'$$, 'لا يمكن تعديله', '... nor on a purchase invoice');
select t.as_owner();

-- =====================================================================
-- 4. Notifications: real number, link by id, and the link opens THAT invoice for whoever receives it
-- =====================================================================
-- the "12 also matches 123" case: two typed numbers where one contains the other
select t.as_user('10900000-0000-0000-0000-000000000005');
select create_sales_invoice(:'org_id', :'c1', :'w', '12', '2026-03-02', t.items(:'org_id', 1), 0, 0, 0, 'نقدًا', null, null) as id \gset n12_
select create_sales_invoice(:'org_id', :'c1', :'w', '123', '2026-03-03', t.items(:'org_id', 1), 0, 0, 0, 'نقدًا', null, null) as id \gset n123_
-- a number with characters that used to break the link
select create_sales_invoice(:'org_id', :'c1', :'w', 'A&B #5 100%', '2026-03-04', t.items(:'org_id', 1), 0, 0, 0, 'نقدًا', null, null) as id \gset odd_
-- a second rep's invoice
select t.as_user('10900000-0000-0000-0000-000000000006');
select create_sales_invoice(:'org_id', :'c2', :'w', '', '2026-03-05', t.items(:'org_id', 1), 0, 0, 0, 'نقدًا', null, null) as id \gset r2_
-- a purchase waiting for the storekeeper
select t.as_user('10900000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'s2', :'w', '', '2026-03-06', t.pitems(:'org_id', 4), 0, 0, 0, 'نقدًا', null) as id \gset pb_
select t.as_owner();
select invoice_number as pb_no from purchase_invoices where id = :'pb_id' \gset

select t.eq((select count(*) from notifications where organization_id = :'org_id' and entity_type in ('sales_invoice', 'purchase_invoice', 'sales', 'purchase')), (select count(*) from notifications where organization_id = :'org_id' and entity_type in ('sales_invoice', 'purchase_invoice', 'sales', 'purchase') and href ~ '[?&]inv=[0-9a-f-]{36}$'), 'every invoice notification links by invoice id')
  where true;
select t.empty($$select 1 from notifications where organization_id = '$$ || :'org_id' || $$' and entity_type in ('sales_invoice','purchase_invoice','sales','purchase') and href ~ '[?&]q='$$, 'no invoice notification uses a text search link any more');
select t.empty($$select 1 from notifications where organization_id = '$$ || :'org_id' || $$' and entity_id is not null and (title like '%' || left(entity_id::text, 8) || '%' or coalesce(payload->>'invoice_number', '') = left(entity_id::text, 8))$$, 'no notification shows a fragment of an id as an invoice number');
select t.empty($$select 1 from notifications n join sales_invoices i on i.id = n.entity_id where n.organization_id = '$$ || :'org_id' || $$' and n.payload ? 'invoice_number' and n.payload->>'invoice_number' <> i.invoice_number$$, 'the number in every sales notification is the invoice''s stored number');

-- owner
select t.ok(exists (select 1 from notifications where recipient_user_id = '10900000-0000-0000-0000-000000000001' and entity_id = :'a_id' and href = '/dashboard/sales?inv=' || :'a_id' and title like '%' || :'a_no' || '%'), 'owner: notification for a rep''s invoice carries its real number and links to it');
-- storekeeper
select t.ok(exists (select 1 from notifications where recipient_user_id = '10900000-0000-0000-0000-000000000003' and entity_id = :'a_id' and href = '/dashboard/warehouse-orders?tab=sales&status=all&inv=' || :'a_id' and title like '%' || :'a_no' || '%'), 'storekeeper: dispatch order notification carries the real number and opens that order');
select t.ok(exists (select 1 from notifications where recipient_user_id = '10900000-0000-0000-0000-000000000003' and entity_id = :'pb_id' and href = '/dashboard/warehouse-orders?tab=purchase&status=all&inv=' || :'pb_id'), 'storekeeper: receipt notification links to the purchase order by id');
select t.ok(exists (select 1 from notifications where recipient_user_id = '10900000-0000-0000-0000-000000000003' and entity_id = :'odd_id' and href = '/dashboard/warehouse-orders?tab=sales&status=all&inv=' || :'odd_id'), 'a number containing & # % does not break the link');

-- following every sales link as the person who received it
select t.as_user('10900000-0000-0000-0000-000000000001');
select t.eq((select count(*) from sales_invoices where id = substring((select href from notifications where recipient_user_id = '10900000-0000-0000-0000-000000000001' and entity_id = :'n12_id' limit 1) from '[0-9a-f-]{36}$')::uuid), 1, 'owner: the link for invoice "12" opens exactly one invoice');
select t.eq_text((select invoice_number from sales_invoices where id = substring((select href from notifications where recipient_user_id = '10900000-0000-0000-0000-000000000001' and entity_id = :'n12_id' limit 1) from '[0-9a-f-]{36}$')::uuid), '12', '… and it is "12", not "123"');
select t.as_user('10900000-0000-0000-0000-000000000003');
select t.eq((select count(*) from warehouse_sales_orders(:'org_id', 'all', null, 50, 0, :'a_id')), 1, 'storekeeper: the order link opens exactly that order (status=all)');
select t.eq_text((select invoice_number from warehouse_sales_orders(:'org_id', 'all', null, 50, 0, :'a_id')), :'a_no', '… showing the real number');
select t.eq_text((select invoice_number from warehouse_sales_orders(:'org_id', 'all', null, 50, 0, :'odd_id')), 'A&B #5 100%', 'storekeeper: the odd-looking number is shown as typed');
select t.eq_text((select invoice_number from warehouse_purchase_orders(:'org_id', 'all', null, 50, 0, :'pb_id')), :'pb_no', 'storekeeper: purchase order opens by id with its real number');
-- rep 1 follows his own link; he cannot open rep 2's invoice by id
select t.as_user('10900000-0000-0000-0000-000000000005');
select t.eq((select count(*) from sales_invoices where id = :'a_id'), 1, 'rep: opens his own invoice from the link');
select t.eq((select count(*) from sales_invoices where id = :'r2_id'), 0, 'rep: another rep''s invoice does not open by id (row-level security)');
select t.as_owner();

-- =====================================================================
-- 5. Search
-- =====================================================================
select t.as_user('10900000-0000-0000-0000-000000000001');
select t.ok((select count(*) from global_search(:'org_id', 'S-0000') where entity_type = 'sales_invoice') >= 3, 'owner: a partial number finds the invoices');
select t.ok(exists (select 1 from global_search(:'org_id', :'a_no') where entity_type = 'sales_invoice' and entity_id = :'a_id' and title = :'a_no'), 'owner: the result is titled with the number and carries the id the link uses');
select t.empty($$select 1 from global_search('$$ || :'org_id' || $$', 'S-0') where entity_type in ('sales_invoice', 'purchase_invoice') and title !~ '^[A-Za-z0-9&# %-]+$'$$, 'invoice results never show an id as their title');
select t.eq((select count(*) from global_search(:'org_id', 'S_0000') where entity_type = 'sales_invoice'), 0, '"_" in what you type is literal, not "any character"');
select t.eq((select count(*) from global_search(:'org_id', '%%') where entity_type = 'sales_invoice'), 0, '"%" in what you type is literal, not "everything"');
select t.eq((select count(*) from global_search(:'org_id', '100%') where entity_type = 'sales_invoice'), 1, 'a number containing "%" is found by typing it');
select t.as_user('10900000-0000-0000-0000-000000000006');
select t.empty($$select 1 from global_search('$$ || :'org_id' || $$', 'S-0') where entity_id = '$$ || :'a_id' || $$'$$, 'rep 2 cannot find rep 1''s invoice');
select t.ok(exists (select 1 from global_search(:'org_id', 'S-0') where entity_id = :'r2_id'), 'rep 2 finds his own');
select t.as_user('10900000-0000-0000-0000-000000000007');
select t.empty($$select 1 from global_search('$$ || :'oth_id' || $$', 'S-0') where entity_id = '$$ || :'a_id' || $$'$$, 'another organization''s owner cannot find these invoices');
select t.as_owner();

select 'DOCUMENT NUMBERS: ALL PASSED' as result;
