-- Reports package, Phase 5: supplier/customer account reports + sales-channel snapshot.
\set ON_ERROR_STOP on
select t.as_owner();
insert into auth.users (id, email) values
  ('9b000000-0000-0000-0000-000000000001', 'owner@pr99.test'),
  ('9b000000-0000-0000-0000-000000000002', 'other@pr99.test'),
  ('9b000000-0000-0000-0000-000000000003', 'acct@pr99.test'),
  ('9b000000-0000-0000-0000-000000000004', 'rep@pr99.test'),
  ('9b000000-0000-0000-0000-000000000005', 'keeper@pr99.test');
select t.as_user('9b000000-0000-0000-0000-000000000001');
select create_organization('شركة الحسابات', 'تجارة', 'EG', 'EGP', 'ar',
  array['sales','customers','inventory','purchases','suppliers','expenses','treasury','representatives']) as id \gset org_
select t.as_user('9b000000-0000-0000-0000-000000000002');
select create_organization('شركة أخرى', 'تجارة', 'EG', 'EGP', 'ar', array['sales','inventory']) as id \gset orgb_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', v.u, r.id, 'active' from roles r
join (values ('owner', '9b000000-0000-0000-0000-000000000003'::uuid), ('sales', '9b000000-0000-0000-0000-000000000004'::uuid), ('warehouse', '9b000000-0000-0000-0000-000000000005'::uuid)) v(k, u) on v.k = r.key
where r.organization_id is null;

select t.as_user('9b000000-0000-0000-0000-000000000001');
select cairo_today() as d0 \gset
insert into warehouses (organization_id, name) values (:'org_id', 'الرئيسي') returning id as w1 \gset
insert into sales_representatives (organization_id, name, user_id) values (:'org_id', 'مندوب 1', '9b000000-0000-0000-0000-000000000004') returning id as rep1 \gset
insert into sales_representatives (organization_id, name) values (:'org_id', 'مندوب 2') returning id as rep2 \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'X', 'X', 'قطعة') returning id as px \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'Y', 'Y', 'قطعة') returning id as py \gset
insert into product_prices (organization_id, product_id, selling_price) select :'org_id', id, 100 from products where organization_id = :'org_id';
insert into suppliers (organization_id, name, payment_terms_days) values (:'org_id', 'مورد 1 (30 يوم)', 30) returning id as sup1 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد 2 (بدون مدة)') returning id as sup2 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد 3 (رصيد افتتاحي)') returning id as sup3 \gset
insert into customers (organization_id, name, price_tier, sales_rep_id) values (:'org_id', 'عميل 1', 'retail', :'rep1') returning id as c1 \gset
insert into customers (organization_id, name, price_tier, sales_rep_id) values (:'org_id', 'عميل 2', 'wholesale', :'rep1') returning id as c2 \gset
insert into customers (organization_id, name, price_tier, sales_rep_id) values (:'org_id', 'عميل 3', 'retail', :'rep2') returning id as c3 \gset
insert into customers (organization_id, name, price_tier) values (:'org_id', 'عميل 4 (بدون مندوب)', 'retail') returning id as c4 \gset
select t.as_owner();
insert into supplier_opening_balances (supplier_id, amount) values (:'sup3', 500);
insert into customer_opening_balances (customer_id, amount) values (:'c1', 100), (:'c4', -30);
select t.as_user('9b000000-0000-0000-0000-000000000001');

-- =====================================================================
-- 1. Supplier due dates
-- =====================================================================
-- P1: 60 days ago, terms 30 → due 30 days ago (derived by the database, not passed)
select create_purchase_invoice(:'org_id', :'sup1', :'w1', 'P1', :'d0'::date - 60,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 10, 'unit_cost', 10, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset p1_
select t.eq_text((select due_date::text from purchase_invoices where id = :'p1_id'), (:'d0'::date - 30)::text, 'due date derived from the supplier terms (invoice date + 30)');
-- P2: 10 days ago + 4 free units of Y; due derived = +20 days
select create_purchase_invoice(:'org_id', :'sup1', :'w1', 'P2', :'d0'::date - 10,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 20, 'unit_cost', 10, 'discount_pct', 0)), 0, 0, 0, null, null, 0,
  jsonb_build_array(jsonb_build_object('product_id', :'py', 'quantity', 4))) as id \gset p2_
select t.eq_text((select due_date::text from purchase_invoices where id = :'p2_id'), (:'d0'::date + 20)::text, 'P2 due in 20 days');
-- P3: explicit due date overrides the terms; 20 paid on the spot
select create_purchase_invoice(:'org_id', :'sup1', :'w1', 'P3', :'d0'::date - 20,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 5, 'unit_cost', 10, 'discount_pct', 0)), 0, 0, 20, null, null, 0, '[]'::jsonb, (:'d0'::date - 5)) as id \gset p3_
select t.eq_text((select due_date::text from purchase_invoices where id = :'p3_id'), (:'d0'::date - 5)::text, 'an explicit due date wins over the supplier terms');
select t.throws(format($q$select create_purchase_invoice(%L, %L, %L, 'PX', %L::date, jsonb_build_array(jsonb_build_object('product_id', %L, 'quantity', 1, 'unit_cost', 10, 'discount_pct', 0)), 0, 0, 0, null, null, 0, '[]'::jsonb, %L::date)$q$, :'org_id', :'sup1', :'w1', :'d0', :'px', (:'d0'::date - 1)::text), 'لا يمكن أن يسبق تاريخ الفاتورة', 'a due date before the invoice date is refused');
select t.eq((select count(*) from purchase_invoices where invoice_number = 'PX'), 0, 'and leaves no invoice behind');
-- no terms → no due date (undated), and the 12-argument call shape is unchanged
select create_purchase_invoice(:'org_id', :'sup2', :'w1', 'P4', :'d0'::date - 15,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 10, 'unit_cost', 10, 'discount_pct', 0)), 0, 0, 0, null, null, 0) as id \gset p4_
select t.ok((select due_date from purchase_invoices where id = :'p4_id') is null, 'no terms and no date → no due date');
select create_purchase_invoice(:'org_id', :'sup3', :'w1', 'P5', :'d0'::date - 5,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 4, 'unit_cost', 10, 'discount_pct', 0)), 0, 0, 0, null, null, 0, '[]'::jsonb, (:'d0'::date + 10)) as id \gset p5_
-- terms are a snapshot: changing them later does not move existing invoices
update suppliers set payment_terms_days = 60 where id = :'sup1';
select t.eq_text((select due_date::text from purchase_invoices where id = :'p1_id'), (:'d0'::date - 30)::text, 'changing the supplier terms later does not move an existing invoice');
select t.throws(format('update suppliers set payment_terms_days = 400 where id = %L', :'sup1'), 'suppliers_payment_terms_chk', 'terms above 365 days refused');
update suppliers set payment_terms_days = 30 where id = :'sup1';

-- payments / returns -----------------------------------------------------
select t.eq((select count(*) from supplier_payments where purchase_invoice_id = :'p3_id'), 1, 'setup: paying on the spot recorded a payment linked to the invoice');
select record_supplier_payment(:'org_id', :'sup1', :'p2_id', 50, :'d0'::date - 8, 'cash', 'R-P2', null) as id \gset pay1_
select create_purchase_return(:'org_id', :'p1_id', :'d0'::date - 3,
  jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', (select id from purchase_invoice_items where purchase_invoice_id = :'p1_id'), 'quantity', 2)), 0, null) as id \gset pr1_
select record_supplier_payment(:'org_id', :'sup1', null, 60, :'d0'::date - 2, 'bank', 'ON-ACC-1', 'على الحساب') as id \gset pay2_
select record_supplier_payment(:'org_id', :'sup2', null, 130, :'d0'::date - 1, 'cash', 'ON-ACC-2', null) as id \gset pay3_
select record_supplier_payment(:'org_id', :'sup3', null, 100, :'d0'::date, 'cash', 'ON-ACC-3', null) as id \gset pay4_

-- customers ----------------------------------------------------------------
select create_sales_invoice(:'org_id', :'c1', :'w1', 'A', :'d0'::date - 30,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 3, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 100, null, null, null, 0) as id \gset sa_
select t.eq((select count(*) from customer_collections where sales_invoice_id = :'sa_id'), 1, 'setup: paying on the spot recorded a collection linked to the invoice');
select record_customer_collection(:'org_id', :'c1', null, 50, :'d0'::date - 6, 'cash', 'ON-ACC-C1', null) as id \gset col1_
select create_sales_return(:'org_id', :'sa_id', :'d0'::date - 4,
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'sa_id'), 'quantity', 1, 'condition', 'resalable')), 40, null) as id \gset sr1_
select create_sales_invoice(:'org_id', :'c2', :'w1', 'B', :'d0'::date - 5,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 2, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset sb_
select create_sales_invoice(:'org_id', :'c3', :'w1', 'C', :'d0'::date - 3,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 1, 'unit_price', 150, 'discount_pct', 0)), 0, 0, 150, null, null, null, 0) as id \gset sc_
select record_customer_collection(:'org_id', :'c3', null, 25, :'d0'::date - 1, 'cash', 'ON-ACC-C3', null) as id \gset col3_
select create_sales_invoice(:'org_id', :'c4', :'w1', 'D', :'d0'::date - 2,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 1, 'unit_price', 80, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset sd_

-- =====================================================================
-- 2. The engine adds up to the existing balances, for EVERY party
-- =====================================================================
select t.eq((select count(*) from (select party_id, sum(open_amount) s from _open_items(:'org_id', 'supplier') group by 1) o
             join supplier_balances b on b.supplier_id = o.party_id where abs(o.s - b.balance) > 0.005), 0, 'suppliers: Σ open items = supplier_balances.balance for every supplier');
select t.eq((select count(*) from (select party_id, sum(open_amount) s from _open_items(:'org_id', 'customer') group by 1) o
             join customer_balances b on b.customer_id = o.party_id where abs(o.s - b.balance) > 0.005), 0, 'customers: Σ open items = customer_balances.balance for every customer');
select t.eq((select count(*) from supplier_balances b where b.organization_id = :'org_id' and b.balance <> 0 and not exists (select 1 from _open_items(:'org_id', 'supplier') o where o.party_id = b.supplier_id)), 0, 'every supplier with a balance appears');
select t.eq((select count(*) from customer_balances b where b.organization_id = :'org_id' and b.balance <> 0 and not exists (select 1 from _open_items(:'org_id', 'customer') o where o.party_id = b.customer_id)), 0, 'every customer with a balance appears');
select t.eq((select balance from supplier_balances where supplier_id = :'sup1'), 200, 'supplier 1 balance = 100 + 200 + 50 − 50 − 20 − 20 (return) − 60');
select t.eq((select balance from supplier_balances where supplier_id = :'sup2'), -30, 'supplier 2 balance = 100 − 130 (we over-paid)');
select t.eq((select balance from supplier_balances where supplier_id = :'sup3'), 440, 'supplier 3 balance = 500 + 40 − 100');
select t.eq((select balance from customer_balances where customer_id = :'c1'), 190, 'customer 1 balance = 100 + 300 − 100 − 50 − 100 + 40 refund');

-- =====================================================================
-- 3. Invoice-level statement (report_party_open_items)
-- =====================================================================
select t.eq((select remaining from report_party_open_items(:'org_id', 'supplier', :'sup1') where doc_number = 'P1'), 20, 'P1: 100 − 20 return = 80, the 60 on-account payment settles the OLDEST invoice first → 20 left');
select t.eq((select returns_net from report_party_open_items(:'org_id', 'supplier', :'sup1') where doc_number = 'P1'), 20, 'P1 shows its return');
select t.eq((select on_account_applied from report_party_open_items(:'org_id', 'supplier', :'sup1') where doc_number = 'P1'), 60, 'P1 shows the on-account amount applied to it');
select t.eq((select remaining from report_party_open_items(:'org_id', 'supplier', :'sup1') where doc_number = 'P2'), 150, 'P2: 200 − 50 linked payment, untouched by the on-account payment');
select t.eq((select linked_paid from report_party_open_items(:'org_id', 'supplier', :'sup1') where doc_number = 'P2'), 50, 'P2 shows the payment linked to it');
select t.eq((select remaining from report_party_open_items(:'org_id', 'supplier', :'sup1') where doc_number = 'P3'), 30, 'P3: 50 − 20 paid on the spot');
select t.eq_text((select status from report_party_open_items(:'org_id', 'supplier', :'sup1') where doc_number = 'P1'), 'overdue', 'P1 is overdue');
select t.eq((select days_overdue from report_party_open_items(:'org_id', 'supplier', :'sup1') where doc_number = 'P1'), 30, 'P1 is 30 days overdue');
select t.eq((select days_overdue from report_party_open_items(:'org_id', 'supplier', :'sup1') where doc_number = 'P3'), 5, 'P3 is 5 days overdue (explicit due date)');
select t.eq_text((select status from report_party_open_items(:'org_id', 'supplier', :'sup1') where doc_number = 'P2'), 'open', 'P2 is open, not due yet');
select t.ok((select days_overdue from report_party_open_items(:'org_id', 'supplier', :'sup1') where doc_number = 'P2') is null, 'no days_overdue for an invoice not yet due');
select t.eq((select sum(remaining) from report_party_open_items(:'org_id', 'supplier', :'sup1')), 200, 'the statement rows add up to the supplier balance (200)');
-- as-of date moves the classification only, never the amounts
select t.eq_text((select status from report_party_open_items(:'org_id', 'supplier', :'sup1', :'d0'::date + 25) where doc_number = 'P2'), 'overdue', 'as of 25 days ahead, P2 is overdue');
select t.eq((select remaining from report_party_open_items(:'org_id', 'supplier', :'sup1', :'d0'::date + 25) where doc_number = 'P2'), 150, 'with the same remaining amount');
select t.eq_text((select status from report_party_open_items(:'org_id', 'supplier', :'sup1', :'d0'::date - 40) where doc_number = 'P1'), 'open', 'as of 40 days ago, P1 was not yet due');
-- opening balance, credit and settled rows
select t.eq((select remaining from report_party_open_items(:'org_id', 'supplier', :'sup3') where kind = 'opening'), 400, 'supplier 3: the on-account 100 settles the opening balance first (500 → 400)');
select t.eq((select remaining from report_party_open_items(:'org_id', 'supplier', :'sup3') where doc_number = 'P5'), 40, 'supplier 3: P5 untouched');
select t.eq((select remaining from report_party_open_items(:'org_id', 'supplier', :'sup2') where kind = 'credit'), -30, 'supplier 2: the over-payment shows as a −30 credit row');
select t.eq_text((select status from report_party_open_items(:'org_id', 'supplier', :'sup2') where doc_number = 'P4'), 'settled', 'supplier 2: P4 is settled');
select t.eq_text((select kind from report_party_open_items(:'org_id', 'supplier', :'sup3') limit 1), 'opening', 'the opening balance comes first');
select t.eq((select remaining from report_party_open_items(:'org_id', 'customer', :'c1') where kind = 'opening'), 50, 'customer 1: opening 100 − 50 on-account collection');
select t.eq((select remaining from report_party_open_items(:'org_id', 'customer', :'c1') where doc_number = 'A'), 140, 'customer 1: invoice A = 300 − 100 paid − (100 returned − 40 refunded)');
select t.eq((select returns_net from report_party_open_items(:'org_id', 'customer', :'c1') where doc_number = 'A'), 60, 'a cash refund is not a credit: net return = 100 − 40');
select t.eq((select sum(remaining) from report_party_open_items(:'org_id', 'customer', :'c1')), 190, 'customer 1 statement rows = balance 190');
select t.eq((select remaining from report_party_open_items(:'org_id', 'customer', :'c3') where kind = 'credit'), -25, 'customer 3: the extra 25 is an advance');
select t.eq((select remaining from report_party_open_items(:'org_id', 'customer', :'c4') where doc_number = 'D'), 50, 'customer 4: a −30 opening credit reduces the first invoice (80 → 50)');
select t.throws(format($q$select * from report_party_open_items(%L, 'supplier', gen_random_uuid())$q$, :'org_id'), 'المورد غير موجود', 'unknown supplier refused');
select t.throws(format($q$select * from report_party_open_items(%L, 'bogus', %L)$q$, :'org_id', :'sup1'), 'نوع الطرف غير صحيح', 'unknown party type refused');

-- =====================================================================
-- 4. Supplier dues: overdue / not due / undated
-- =====================================================================
select t.eq((select balance from report_supplier_dues(:'org_id') where supplier_id = :'sup1'), 200, 'dues: supplier 1 balance 200');
select t.eq((select overdue from report_supplier_dues(:'org_id') where supplier_id = :'sup1'), 50, 'dues: supplier 1 overdue = P1 20 + P3 30');
select t.eq((select not_due from report_supplier_dues(:'org_id') where supplier_id = :'sup1'), 150, 'dues: supplier 1 not yet due = P2 150');
select t.eq((select undated from report_supplier_dues(:'org_id') where supplier_id = :'sup1'), 0, 'dues: nothing undated for supplier 1');
select t.eq((select overdue_invoices from report_supplier_dues(:'org_id') where supplier_id = :'sup1'), 2, 'dues: two overdue invoices');
select t.eq((select max_days_overdue from report_supplier_dues(:'org_id') where supplier_id = :'sup1'), 30, 'dues: the oldest is 30 days overdue');
select t.eq_text((select oldest_overdue_date::text from report_supplier_dues(:'org_id') where supplier_id = :'sup1'), (:'d0'::date - 30)::text, 'dues: oldest overdue due date');
select t.eq_text((select next_due_date::text from report_supplier_dues(:'org_id') where supplier_id = :'sup1'), (:'d0'::date + 20)::text, 'dues: next due date');
select t.eq((select payment_terms_days from report_supplier_dues(:'org_id') where supplier_id = :'sup1'), 30, 'dues: the supplier terms are shown');
select t.eq_text((select last_payment_date::text from report_supplier_dues(:'org_id') where supplier_id = :'sup1'), (:'d0'::date - 2)::text, 'dues: last payment date');
select t.eq((select last_payment_amount from report_supplier_dues(:'org_id') where supplier_id = :'sup1'), 60, 'dues: last payment amount');
select t.eq((select undated from report_supplier_dues(:'org_id') where supplier_id = :'sup3'), 400, 'dues: an opening balance is undated, never overdue');
select t.eq((select overdue from report_supplier_dues(:'org_id') where supplier_id = :'sup3'), 0, 'dues: supplier 3 has nothing overdue');
select t.eq((select not_due from report_supplier_dues(:'org_id') where supplier_id = :'sup3'), 40, 'dues: supplier 3 P5 not yet due');
select t.eq((select advance from report_supplier_dues(:'org_id', null, null, true) where supplier_id = :'sup2'), 30, 'dues: supplier 2 advance 30');
select t.eq((select balance from report_supplier_dues(:'org_id', null, null, true) where supplier_id = :'sup2'), -30, 'dues: its balance is −30');
select t.eq((select count(*) from report_supplier_dues(:'org_id') where supplier_id = :'sup2'), 1, 'dues: a supplier we have over-paid is still listed (non-zero balance)');
-- identity per supplier: balance = overdue + not due + undated − advance, and = supplier_balances
select t.eq((select count(*) from report_supplier_dues(:'org_id', null, null, true) r
             where abs(r.balance - (r.overdue + r.not_due + r.undated - r.advance)) > 0.005), 0, 'identity: balance = overdue + not due + undated − advance, for every supplier');
select t.eq((select count(*) from report_supplier_dues(:'org_id', null, null, true) r join supplier_balances b on b.supplier_id = r.supplier_id where abs(r.balance - b.balance) > 0.005), 0, 'dues balance = supplier_balances.balance, for every supplier');
-- as-of date
select t.eq((select overdue from report_supplier_dues(:'org_id', :'d0'::date + 25) where supplier_id = :'sup1'), 200, 'as of +25 days everything of supplier 1 is overdue');
select t.eq((select not_due from report_supplier_dues(:'org_id', :'d0'::date + 25) where supplier_id = :'sup1'), 0, 'and nothing is left not-yet-due');
select t.eq((select overdue from report_supplier_dues(:'org_id', :'d0'::date + 25) where supplier_id = :'sup3'), 40, 'as of +25 days P5 (due +10) is overdue too');
select t.eq((select count(*) from report_supplier_dues(:'org_id', null, :'sup1')), 1, 'supplier filter');
-- ordering: most overdue first
select t.eq_text((select supplier_id::text from report_supplier_dues(:'org_id') limit 1), :'sup1', 'sorted by overdue amount, largest first');

-- =====================================================================
-- 5. Customer outstanding per rep and company
-- =====================================================================
select t.eq((select receivable from report_receivables_summary(:'org_id') where group_id = :'rep1'), 390, 'rep 1 receivable = 190 + 200');
select t.eq((select net_balance from report_receivables_summary(:'org_id') where group_id = :'rep1'), 390, 'rep 1 net balance');
select t.eq((select customers from report_receivables_summary(:'org_id') where group_id = :'rep1'), 2, 'rep 1 has 2 customers');
select t.eq((select customers_with_debt from report_receivables_summary(:'org_id') where group_id = :'rep1'), 2, 'both owe money');
select t.eq((select opening from report_receivables_summary(:'org_id') where group_id = :'rep1'), 100, 'rep 1 opening balances');
select t.eq((select sales from report_receivables_summary(:'org_id') where group_id = :'rep1'), 500, 'rep 1 sales 300 + 200');
select t.eq((select collected from report_receivables_summary(:'org_id') where group_id = :'rep1'), 150, 'rep 1 collected 100 + 50');
select t.eq((select returns_net from report_receivables_summary(:'org_id') where group_id = :'rep1'), 60, 'rep 1 returns net of the cash refund');
select t.eq((select advances from report_receivables_summary(:'org_id') where group_id = :'rep2'), 25, 'rep 2: customer 3 is 25 in credit');
select t.eq((select receivable from report_receivables_summary(:'org_id') where group_id = :'rep2'), 0, 'rep 2 owed nothing');
select t.eq((select net_balance from report_receivables_summary(:'org_id') where group_id = :'rep2'), -25, 'rep 2 net balance −25');
select t.eq((select receivable from report_receivables_summary(:'org_id') where group_id = 'none'), 50, 'customers without a rep are grouped, not dropped');
select t.eq_text((select group_label from report_receivables_summary(:'org_id') where group_id = 'none'), 'بدون مندوب', 'with their own label');
select t.eq((select receivable from report_receivables_summary(:'org_id') where is_total), 440, 'company receivable = 390 + 50');
select t.eq((select advances from report_receivables_summary(:'org_id') where is_total), 25, 'company advances');
select t.eq((select net_balance from report_receivables_summary(:'org_id') where is_total), 415, 'company net = opening 70 + sales 730 − collected 325 − returns 60');
select t.eq((select customers from report_receivables_summary(:'org_id') where is_total), 4, 'company customers');
select t.eq((select customers_with_debt from report_receivables_summary(:'org_id') where is_total), 3, 'company customers with debt');
select t.eq((select sum(receivable) from report_receivables_summary(:'org_id') where not is_total), (select receivable from report_receivables_summary(:'org_id') where is_total), 'the reps add up to the company total (receivable)');
select t.eq((select sum(net_balance) from report_receivables_summary(:'org_id') where not is_total), (select net_balance from report_receivables_summary(:'org_id') where is_total), 'the reps add up to the company total (net)');
select t.eq((select net_balance from report_receivables_summary(:'org_id') where is_total), (select sum(balance) from customer_balances where organization_id = :'org_id'), 'company net = Σ customer_balances.balance');
select t.eq((select receivable from report_receivables_summary(:'org_id') where is_total), (select grand_total from report_customer_debts(:'org_id', null, null, true, 1, 0) limit 1), 'company receivable = the existing debts report grand total');
select t.eq((select net_balance from report_receivables_summary(:'org_id') where is_total), (select sum(remaining) from report_party_open_items(:'org_id', 'customer', :'c1')) + (select sum(remaining) from report_party_open_items(:'org_id', 'customer', :'c2')) + (select sum(remaining) from report_party_open_items(:'org_id', 'customer', :'c3')) + (select sum(remaining) from report_party_open_items(:'org_id', 'customer', :'c4')), 'company net = the sum of every customer''s invoice-level statement');
select t.eq((select count(*) from report_receivables_summary(:'org_id', :'rep1')), 2, 'rep filter: that rep + a total row');
select t.eq((select receivable from report_receivables_summary(:'org_id', :'rep1') where is_total), 390, 'rep filter: the total follows the filter');
select t.eq_text((select group_id from report_receivables_summary(:'org_id') where not is_total limit 1), :'rep1', 'reps ordered by receivable, largest first');
select t.ok((select is_total from report_receivables_summary(:'org_id') order by 1 desc nulls last limit 1) is not null, 'sanity: rows returned');
select t.eq_text((select group_id from report_receivables_summary(:'org_id') offset 3 limit 1), 'total', 'the company total is the last row');

-- =====================================================================
-- 6. Payment register
-- =====================================================================
select t.eq((select count(*) from report_party_payments(:'org_id', 'supplier')), (select count(*) from supplier_payments where organization_id = :'org_id'), 'supplier register lists every payment once');
select t.eq((select total_amount from report_party_payments(:'org_id', 'supplier') limit 1), (select sum(amount) from supplier_payments where organization_id = :'org_id'), 'supplier register total = Σ payments');
select t.eq((select total_count from report_party_payments(:'org_id', 'supplier') limit 1), (select count(*) from supplier_payments where organization_id = :'org_id'), 'total_count');
select t.eq_text((select doc_number from report_party_payments(:'org_id', 'supplier', null, null, :'sup1') where reference = 'R-P2'), 'P2', 'a linked payment names its invoice');
select t.ok((select doc_number from report_party_payments(:'org_id', 'supplier', null, null, :'sup1') where reference = 'ON-ACC-1') is null, 'an on-account payment has no invoice');
select t.eq((select count(*) from report_party_payments(:'org_id', 'supplier', null, null, :'sup1')), 3, 'supplier 1: 20 on the spot + 50 + 60');
select t.eq((select total_amount from report_party_payments(:'org_id', 'supplier', null, null, :'sup1') limit 1), 130, 'supplier 1 payments total 130');
select t.eq((select count(*) from report_party_payments(:'org_id', 'supplier', :'d0'::date - 5, :'d0'::date)), 3, 'date range: only the three payments of the last 5 days (60, 130, 100)');
select t.eq((select count(*) from report_party_payments(:'org_id', 'supplier', :'d0'::date - 8, :'d0'::date - 8)), 1, 'date range is inclusive on both ends (the 50 paid 8 days ago)');
select t.eq_text((select payment_date::text from report_party_payments(:'org_id', 'supplier') limit 1), :'d0', 'newest first');
select t.eq((select count(*) from report_party_payments(:'org_id', 'supplier', null, null, null, null, 2, 0)), 2, 'limit');
select t.eq((select total_count from report_party_payments(:'org_id', 'supplier', null, null, null, null, 2, 0) limit 1), (select count(*) from supplier_payments where organization_id = :'org_id'), 'total_count ignores the limit');
select t.eq((select count(*) from report_party_payments(:'org_id', 'customer')), (select count(*) from customer_collections where organization_id = :'org_id'), 'customer register lists every collection once');
select t.eq((select total_amount from report_party_payments(:'org_id', 'customer') limit 1), 325, 'customer collections total 100 + 50 + 150 + 25');
select t.eq((select count(*) from report_party_payments(:'org_id', 'customer', null, null, null, :'rep1')), 2, 'rep filter: rep 1''s customers collected twice (100 on the spot + 50)');
select t.eq((select total_amount from report_party_payments(:'org_id', 'customer', null, null, :'c1') limit 1), 150, 'customer filter: customer 1 paid 150');
select t.eq_text((select rep_name from report_party_payments(:'org_id', 'customer', null, null, :'c1') limit 1), 'مندوب 1', 'the customer''s rep is shown');
select t.eq_text((select doc_number from report_party_payments(:'org_id', 'customer', null, null, :'c1') where reference is not distinct from null limit 1), 'A', 'a payment made on the spot names its invoice');
select t.throws(format($q$select * from report_party_payments(%L, 'bogus')$q$, :'org_id'), 'نوع الطرف غير صحيح', 'unknown type refused');

-- =====================================================================
-- 7. Items bought from suppliers
-- =====================================================================
select t.eq((select purchased_qty from report_supplier_items(:'org_id', null, null, :'sup1') where product_name = 'X'), 35, 'supplier 1 sold us 10 + 20 + 5 X');
select t.eq((select returned_qty from report_supplier_items(:'org_id', null, null, :'sup1') where product_name = 'X'), 2, 'we returned 2');
select t.eq((select received_qty from report_supplier_items(:'org_id', null, null, :'sup1') where product_name = 'X'), 33, 'net received = 35 − 2');
select t.eq((select free_qty from report_supplier_items(:'org_id', null, null, :'sup1') where product_name = 'Y'), 4, 'the 4 free Y units are reported as free');
select t.eq((select purchased_qty from report_supplier_items(:'org_id', null, null, :'sup1') where product_name = 'Y'), 0, 'and not as purchased');
select t.eq((select received_qty from report_supplier_items(:'org_id', null, null, :'sup1') where product_name = 'Y'), 4, 'but they were received');
select t.eq((select invoices from report_supplier_items(:'org_id', null, null, :'sup1') where product_name = 'X'), 3, 'X appears on 3 invoices');
select t.eq((select returned_value from report_supplier_items(:'org_id', null, null, :'sup1') where product_name = 'X'), 20, 'returned value 2 × 10');
select t.eq((select net_value from report_supplier_items(:'org_id', null, null, :'sup1') where product_name = 'X'), (select purchased_value from report_supplier_items(:'org_id', null, null, :'sup1') where product_name = 'X') - 20, 'net value = purchased − returned');
select t.eq((select sum(purchased_value) from report_supplier_items(:'org_id')), (select sum(subtotal - discount_total) from purchase_invoices where organization_id = :'org_id'), 'purchased value over all suppliers = invoices (subtotal − discounts): nothing doubled by the item join');
select t.eq((select sum(returned_value) from report_supplier_items(:'org_id')), (select sum(total - tax_reversed) from purchase_returns where organization_id = :'org_id'), 'returned value = the return documents');
select t.eq((select sum(received_qty) from report_supplier_items(:'org_id')), (select sum(quantity_delta) from inventory_movements where organization_id = :'org_id' and movement_type in ('purchase', 'purchase_return')), 'net received = the stock ledger''s purchase and purchase-return movements (units that really arrived)');
select t.eq_text((select last_purchase_date::text from report_supplier_items(:'org_id', null, null, :'sup1') where product_name = 'X'), (:'d0'::date - 10)::text, 'last purchase date');
select t.eq((select count(*) from report_supplier_items(:'org_id', :'d0'::date - 12, :'d0'::date, :'sup1')), 2, 'date range (P2 only → X and Y)');
select t.eq((select purchased_qty from report_supplier_items(:'org_id', :'d0'::date - 12, :'d0'::date, :'sup1') where product_name = 'X'), 20, 'date range: X = 20');
select t.eq((select count(distinct supplier_id) from report_supplier_items(:'org_id')), 3, 'all three suppliers appear');
select t.eq((select count(*) from report_supplier_items(:'org_id', null, null, null, 1, 0)), 1, 'limit');

-- =====================================================================
-- 8. Permissions
-- =====================================================================
select t.as_user('9b000000-0000-0000-0000-000000000003');   -- second owner: view_financial + balance permissions
select t.eq((select count(*) from report_supplier_dues(:'org_id')), 3, 'second owner can read supplier dues (all three have a non-zero balance)');
select t.eq((select receivable from report_receivables_summary(:'org_id') where is_total), 440, 'second owner can read the receivables summary');
select t.ok((select count(*) from report_party_payments(:'org_id', 'supplier')) > 0, 'second owner can read the payment register');
select t.ok((select count(*) from report_supplier_items(:'org_id')) > 0, 'second owner can read supplier items');
select t.ok((select count(*) from report_party_open_items(:'org_id', 'customer', :'c1')) > 0, 'second owner can read a statement');
select t.as_user('9b000000-0000-0000-0000-000000000004');   -- restricted sales rep: no balance permission
select t.ok((select count(*) from report_receivables_summary(:'org_id')) >= 0, 'a rep can read the receivables summary (of his own customers only, by RLS)');
select t.ok((select count(*) from report_party_payments(:'org_id', 'customer')) >= 0, 'a rep can read the collections register of his customers');
select t.throws(format($q$select * from _open_items(%L, 'supplier')$q$, :'org_id'), 'صلاحية', 'the engine cannot be called directly to read supplier balances');
select t.throws(format('select * from report_supplier_dues(%L)', :'org_id'), 'ليس لديك صلاحية', 'a rep cannot read supplier dues');
select t.throws(format('select * from report_supplier_items(%L)', :'org_id'), 'ليس لديك صلاحية', 'a rep cannot read supplier items');
select t.as_user('9b000000-0000-0000-0000-000000000005');   -- warehouse keeper
select t.throws(format('select * from report_supplier_dues(%L)', :'org_id'), 'صلاحية عرض البيانات المالية', 'a storekeeper cannot read supplier dues');
select t.throws(format('select * from report_receivables_summary(%L)', :'org_id'), 'صلاحية عرض البيانات المالية', 'nor receivables');
select t.throws(format($q$select * from _open_items(%L, 'supplier')$q$, :'org_id'), 'صلاحية عرض البيانات المالية', 'nor the engine');
select t.as_user('9b000000-0000-0000-0000-000000000002');   -- another organization
select t.throws(format('select * from report_supplier_dues(%L)', :'org_id'), 'لست عضوًا', 'another organization cannot read my supplier dues');
select t.throws(format('select * from report_receivables_summary(%L)', :'org_id'), 'لست عضوًا', 'nor my receivables');
select t.throws(format($q$select * from report_party_open_items(%L, 'supplier', %L)$q$, :'org_id', :'sup1'), 'لست عضوًا', 'nor a statement');
select t.throws(format($q$select * from report_party_payments(%L, 'supplier')$q$, :'org_id'), 'لست عضوًا', 'nor payments');
select t.throws(format('select * from report_supplier_items(%L)', :'org_id'), 'لست عضوًا', 'nor items');
select t.eq((select count(*) from report_supplier_dues(:'orgb_id')), 0, 'its own organization is simply empty');
select t.as_anon();
select t.throws(format('select * from report_supplier_dues(%L)', :'org_id'), 'permission denied', 'anonymous callers cannot run the dues report');
select t.throws(format($q$select * from _open_items(%L, 'customer')$q$, :'org_id'), 'permission denied', 'nor the engine');
select t.as_user('9b000000-0000-0000-0000-000000000001');

-- =====================================================================
-- 9. Sales channel is a SNAPSHOT
-- =====================================================================
-- invoice 'A' (customer 1, retail) was created with no channel chosen → the database stored 'retail'
select t.eq_text((select sales_channel from sales_invoices where id = :'sa_id'), 'retail', 'a new invoice stores its channel when it is created');
select t.eq((select invoices from report_sales_by(:'org_id', 'channel') where group_id = 'retail' and invoices > 0), (select count(*) from sales_invoices where organization_id = :'org_id' and sales_channel = 'retail'), 'setup: the report agrees with the stored values');
select net_revenue as retail_before from report_sales_by(:'org_id', 'channel') where group_id = 'retail' \gset
select net_revenue as whole_before from report_sales_by(:'org_id', 'channel') where group_id = 'wholesale' \gset
-- the customer becomes a wholesale customer: history must not move
update customers set price_tier = 'wholesale' where id = :'c1';
update customers set price_tier = 'retail' where id = :'c2';
select t.eq_text((select sales_channel from sales_invoices where id = :'sa_id'), 'retail', 'changing the customer tier does not change the stored channel');
select t.eq((select net_revenue from report_sales_by(:'org_id', 'channel') where group_id = 'retail'), :retail_before::numeric, 'retail history is unchanged after the tier change');
select t.eq((select net_revenue from report_sales_by(:'org_id', 'channel') where group_id = 'wholesale'), :whole_before::numeric, 'wholesale history is unchanged after the tier change');
-- but NEW invoices follow the new tier
select create_sales_invoice(:'org_id', :'c1', :'w1', 'A2', :'d0'::date,
  jsonb_build_array(jsonb_build_object('product_id', :'px', 'quantity', 1, 'unit_price', 90, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) as id \gset sa2_
select t.eq_text((select sales_channel from sales_invoices where id = :'sa2_id'), 'wholesale', 'a NEW invoice for the same customer takes the new tier');
update customers set price_tier = 'retail' where id = :'c1';
update customers set price_tier = 'wholesale' where id = :'c2';
-- the migration plan: freeze legacy (NULL-channel) invoices WITHOUT touching them
select t.as_owner();
update sales_invoices set sales_channel = null where id = :'sb_id';   -- make invoice B look like a pre-0040 invoice (customer 2 is wholesale now)
delete from sales_invoice_channel_snapshot where sales_invoice_id = :'sb_id';
-- (a) not frozen yet: the report falls back to the LIVE tier
select t.as_user('9b000000-0000-0000-0000-000000000001');
select t.eq((select invoices from report_sales_by(:'org_id', 'channel', null, null, null, :'rep1', 'wholesale') where group_id = 'wholesale'), 2, 'unfrozen legacy invoice B follows the live tier (wholesale) — plus A2, stored wholesale (the behaviour the migration removes)');
select t.as_owner();
-- (b) the migration's freeze statement (identical to 0041) — idempotent, inserts only, never updates an invoice
select count(*) as legacy_before from sales_invoices where sales_channel is null \gset
insert into sales_invoice_channel_snapshot (sales_invoice_id, organization_id, sales_channel)
select i.id, i.organization_id, case c.price_tier when 'retail' then 'retail' else 'wholesale' end
from sales_invoices i join customers c on c.id = i.customer_id
where i.sales_channel is null
on conflict (sales_invoice_id) do nothing;
select t.eq((select count(*) from sales_invoices where sales_channel is null), :legacy_before::bigint, 'freezing does not touch any invoice row (still NULL)');
select t.eq_text((select sales_channel from sales_invoice_channel_snapshot where sales_invoice_id = :'sb_id'), 'wholesale', 'the snapshot holds the classification as of the migration');
select t.eq_text((select source from sales_invoice_channel_snapshot where sales_invoice_id = :'sb_id'), 'tier_at_migration', 'and says it was inferred, not chosen');
select t.eq((select count(*) from sales_invoice_channel_snapshot s where s.sales_channel is null), 0, 'no snapshot without a channel');
-- (c) after the freeze, a tier change can no longer move it
update customers set price_tier = 'retail' where id = :'c2';
select t.as_user('9b000000-0000-0000-0000-000000000001');
select t.eq((select invoices from report_sales_by(:'org_id', 'channel', null, null, null, :'rep1', 'wholesale') where group_id = 'wholesale'), 2, 'frozen legacy invoice B stays wholesale (with A2) after its customer becomes retail');
select t.eq((select invoices from report_sales_by(:'org_id', 'channel', null, null, null, :'rep1', 'retail') where group_id = 'retail' and invoices > 0), (select count(*) from sales_invoices where organization_id = :'org_id' and sales_rep_id = :'rep1' and coalesce(sales_channel, (select s.sales_channel from sales_invoice_channel_snapshot s where s.sales_invoice_id = sales_invoices.id)) = 'retail'), 'channel counts follow stored/frozen values only');
select t.throws(format($q$insert into sales_invoice_channel_snapshot (sales_invoice_id, organization_id, sales_channel) values (%L, %L, 'retail')$q$, :'sb_id', :'org_id'), 'permission denied', 'nobody can write the snapshot directly');
select t.as_user('9b000000-0000-0000-0000-000000000002');
select t.eq((select count(*) from sales_invoice_channel_snapshot), 0, 'another organization cannot read the snapshot');
select t.as_user('9b000000-0000-0000-0000-000000000004');   -- restricted rep sees only his own invoices' snapshot rows
select t.ok(not exists (select 1 from sales_invoice_channel_snapshot where sales_invoice_id = :'sc_id'), 'a rep cannot read the snapshot of another rep''s invoice');
select t.as_owner();
