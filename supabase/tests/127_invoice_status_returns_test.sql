-- 0077: an invoice settled by payments AND returns is «paid» (sales and purchases); the stored status can no longer drift
-- from  remaining = total − paid − returns + cash refunded.
\set ON_ERROR_STOP on
select t.autoconfirm_on();

select t.as_owner();
insert into auth.users (id, email) values ('12700000-0000-0000-0000-000000000001', 'st-owner@st.test');
select t.as_user('12700000-0000-0000-0000-000000000001');
select create_organization('شركة الحالة', 'x', 'EG', 'EGP', 'ar', array['sales','customers','inventory','purchases','suppliers','treasury']) as id \gset org_

insert into warehouses (organization_id, name) values (:'org_id', 'المخزن') returning id as wh \gset
insert into suppliers  (organization_id, name) values (:'org_id', 'مورد')  returning id as sup \gset
insert into customers  (organization_id, name) values (:'org_id', 'عميل')  returning id as cus \gset
insert into products   (organization_id, name) values (:'org_id', 'منتج')  returning id as prod \gset

select create_purchase_invoice(:'org_id', :'sup', :'wh', 'P-1', '2026-03-01',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 200, 'unit_cost', 100, 'discount', 0)), 0, 0, 20000, 'نقدًا', null) as id \gset p1_
select t.eq_text((select payment_status from purchase_invoices where id = :'p1_id'), 'paid', 'purchase paid in full at creation is «paid»');

-- ================= the rule itself (pure function) =================
select t.as_owner();
select t.eq_text(_settlement_status(1000,    0,    0,   0), 'unpaid',  'nothing paid, nothing returned → unpaid');
select t.eq_text(_settlement_status(1000,  400,    0,   0), 'partial', 'part paid → partial');
select t.eq_text(_settlement_status(1000, 1000,    0,   0), 'paid',    'paid in full → paid (as before)');
select t.eq_text(_settlement_status(1000,  800,  200,   0), 'paid',    'paid 800 + returned 200 → paid');
select t.eq_text(_settlement_status(1000,  800,  150,   0), 'partial', 'paid 800 + returned 150 → still partial (50 owed)');
select t.eq_text(_settlement_status(1000, 1000,  200, 200), 'paid',    'paid in full, goods returned and refunded in cash → paid');
select t.eq_text(_settlement_status(1000,    0,  300,   0), 'unpaid',  'nothing paid, part returned → unpaid');
select t.eq_text(_settlement_status(1000,    0, 1000,   0), 'paid',    'everything returned, nothing ever paid → settled');
select t.eq_text(_settlement_status(1000, 1200,    0,   0), 'paid',    'over-paid → paid');
select t.as_user('12700000-0000-0000-0000-000000000001');

-- ================= sales: 10 × 200 = 2,000 =================
select create_sales_invoice(:'org_id', :'cus', :'wh', 'S-1', '2026-03-10',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 10, 'unit_price', 200, 'discount', 0)), 0, 0, 0, null, null, null) as id \gset s1_
select id as s1_item from sales_invoice_items where sales_invoice_id = :'s1_id' \gset
select t.eq_text((select payment_status from sales_invoices where id = :'s1_id'), 'unpaid', 'S-1: new unpaid invoice');

select record_customer_collection(:'org_id', :'cus', :'s1_id', 1200, '2026-03-11', 'نقدًا', null, null) as id \gset
select t.eq_text((select payment_status from sales_invoices where id = :'s1_id'), 'partial', 'S-1: 1,200 collected → partial');

select create_sales_return(:'org_id', :'s1_id', '2026-03-12',
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'s1_item', 'quantity', 3, 'condition', 'resalable')), 0, null) as id \gset
select t.as_owner();
select t.eq((select sales_invoice_remaining(id) from sales_invoices where id = :'s1_id'), 200, 'S-1: 600 returned → 200 still owed');
select t.as_user('12700000-0000-0000-0000-000000000001');
select t.eq_text((select payment_status from sales_invoices where id = :'s1_id'), 'partial', 'S-1: still partial while 200 is owed');

select record_customer_collection(:'org_id', :'cus', :'s1_id', 200, '2026-03-13', 'نقدًا', null, null) as id \gset
select t.as_owner();
select t.eq((select sales_invoice_remaining(id) from sales_invoices where id = :'s1_id'), 0, 'S-1: nothing owed any more');
select t.as_user('12700000-0000-0000-0000-000000000001');
select t.eq_text((select payment_status from sales_invoices where id = :'s1_id'), 'paid', 'S-1: 1,400 paid + 600 returned = 2,000 → PAID (it used to stay partial for ever)');

-- a return that is the LAST thing to happen settles the invoice by itself
select create_sales_invoice(:'org_id', :'cus', :'wh', 'S-2', '2026-03-14',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 10, 'unit_price', 200, 'discount', 0)), 0, 0, 0, null, null, null) as id \gset s2_
select id as s2_item from sales_invoice_items where sales_invoice_id = :'s2_id' \gset
select record_customer_collection(:'org_id', :'cus', :'s2_id', 1400, '2026-03-15', 'نقدًا', null, null) as id \gset
select t.eq_text((select payment_status from sales_invoices where id = :'s2_id'), 'partial', 'S-2: 1,400 of 2,000 collected → partial');
select create_sales_return(:'org_id', :'s2_id', '2026-03-16',
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'s2_item', 'quantity', 3, 'condition', 'resalable')), 0, null) as id \gset
select t.eq_text((select payment_status from sales_invoices where id = :'s2_id'), 'paid', 'S-2: the return of 600 settles it → paid, with no further payment');

-- paid in full at the counter, then goods come back and are refunded in cash: still paid
select create_sales_invoice(:'org_id', :'cus', :'wh', 'S-3', '2026-03-17',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 5, 'unit_price', 200, 'discount', 0)), 0, 0, 1000, 'نقدًا', null, null) as id \gset s3_
select id as s3_item from sales_invoice_items where sales_invoice_id = :'s3_id' \gset
select t.eq_text((select payment_status from sales_invoices where id = :'s3_id'), 'paid', 'S-3: paid in full on the spot');
select create_sales_return(:'org_id', :'s3_id', '2026-03-18',
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'s3_item', 'quantity', 2, 'condition', 'resalable')), 400, null) as id \gset
select t.eq_text((select payment_status from sales_invoices where id = :'s3_id'), 'paid', 'S-3: returned and refunded in cash → still paid');

-- never paid, only part returned → unpaid (returns alone do not make it «partial»)
select create_sales_invoice(:'org_id', :'cus', :'wh', 'S-4', '2026-03-19',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 10, 'unit_price', 200, 'discount', 0)), 0, 0, 0, null, null, null) as id \gset s4_
select id as s4_item from sales_invoice_items where sales_invoice_id = :'s4_id' \gset
select create_sales_return(:'org_id', :'s4_id', '2026-03-20',
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'s4_item', 'quantity', 3, 'condition', 'resalable')), 0, null) as id \gset
select t.eq_text((select payment_status from sales_invoices where id = :'s4_id'), 'unpaid', 'S-4: unpaid, 600 of 2,000 returned → still unpaid (1,400 owed)');
select create_sales_return(:'org_id', :'s4_id', '2026-03-21',
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'s4_item', 'quantity', 7, 'condition', 'resalable')), 0, null) as id \gset
select t.eq_text((select payment_status from sales_invoices where id = :'s4_id'), 'paid', 'S-4: everything returned → nothing owed → settled');

-- nobody can set a status the numbers do not support
select create_sales_invoice(:'org_id', :'cus', :'wh', 'S-5', '2026-03-22',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 10, 'unit_price', 200, 'discount', 0)), 0, 0, 0, null, null, null) as id \gset s5_
select t.as_owner();
update sales_invoices set payment_status = 'paid' where id = :'s5_id';
select t.eq_text((select payment_status from sales_invoices where id = :'s5_id'), 'unpaid', 'a hand-written «paid» on an invoice that is owed in full is put back to unpaid');
select t.as_user('12700000-0000-0000-0000-000000000001');

-- ================= purchases: 20 × 100 = 2,000 =================
select create_purchase_invoice(:'org_id', :'sup', :'wh', 'P-2', '2026-03-23',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 20, 'unit_cost', 100, 'discount', 0)), 0, 0, 0, null, null) as id \gset p2_
select id as p2_item from purchase_invoice_items where purchase_invoice_id = :'p2_id' \gset
select t.eq_text((select payment_status from purchase_invoices where id = :'p2_id'), 'unpaid', 'P-2: new unpaid purchase');
select record_supplier_payment(:'org_id', :'sup', :'p2_id', 1500, '2026-03-24', 'تحويل', null, null) as id \gset
select t.eq_text((select payment_status from purchase_invoices where id = :'p2_id'), 'partial', 'P-2: 1,500 paid → partial');
select create_purchase_return(:'org_id', :'p2_id', '2026-03-25',
  jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', :'p2_item', 'quantity', 5)), 0, null, false) as id \gset
select t.as_owner();
select t.eq((select purchase_invoice_remaining(id) from purchase_invoices where id = :'p2_id'), 0, 'P-2: 500 returned to the supplier → nothing owed');
select t.as_user('12700000-0000-0000-0000-000000000001');
select t.eq_text((select payment_status from purchase_invoices where id = :'p2_id'), 'paid', 'P-2: 1,500 paid + 500 returned = 2,000 → PAID');

-- ================= the invoices that existed before the migration =================
-- (the migration ends with a one-off correction; here we prove the stored status of every invoice now equals the rule)
select t.as_owner();
select t.eq((select count(*) from sales_invoices i where i.organization_id = :'org_id' and i.payment_status is distinct from _sales_invoice_status(i.id, i.total, i.amount_paid)), 0, 'every sales invoice of this company carries the status the rule gives');
select t.eq((select count(*) from purchase_invoices i where i.organization_id = :'org_id' and i.payment_status is distinct from _purchase_invoice_status(i.id, i.total, i.amount_paid)), 0, 'every purchase invoice of this company carries the status the rule gives');
