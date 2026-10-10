-- The analysis / debt reports must agree with the core numbers, to the cent.
\set ON_ERROR_STOP on
select t.as_owner();
insert into auth.users (id, email) values
  ('92000000-0000-0000-0000-000000000001', 'owner@an.test'),
  ('92000000-0000-0000-0000-000000000002', 'rep@an.test');
select t.as_user('92000000-0000-0000-0000-000000000001');
select create_organization('شركة التحليل', 'تجارة', 'EG', 'EGP', 'ar',
  array['sales','customers','inventory','purchases','suppliers','expenses','treasury','representatives','partners']) as id \gset org_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', '92000000-0000-0000-0000-000000000002', r.id, 'active' from roles r where r.key = 'sales' and r.organization_id is null;

select t.as_user('92000000-0000-0000-0000-000000000001');
insert into warehouses (organization_id, name) values (:'org_id', 'الرئيسي') returning id as wh \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد 1') returning id as sup \gset
insert into products (organization_id, name, sku, unit) values (:'org_id', 'أ', 'A', 'قطعة') returning id as pa \gset
insert into product_prices (organization_id, product_id, selling_price) values (:'org_id', :'pa', 100);
insert into sales_representatives (organization_id, name, commission_basis, commission_rate, monthly_target, min_target_for_commission, user_id)
values (:'org_id', 'مندوب', 'net_sales', 5, 2000, 1000, '92000000-0000-0000-0000-000000000002') returning id as rep \gset
insert into customers (organization_id, name, sales_rep_id) values (:'org_id', 'عميل 1', :'rep') returning id as c1 \gset
insert into customer_opening_balances (customer_id, organization_id, amount) values (:'c1', :'org_id', 100);
insert into customers (organization_id, name) values (:'org_id', 'عميل بدون مندوب') returning id as c2 \gset
insert into discount_tiers (organization_id, applies_to, min_amount, discount_pct) values (:'org_id', 'sales', 1000, 5);

select create_purchase_invoice(:'org_id', :'sup', :'wh', 'P-1', '2026-07-01',
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 100, 'unit_cost', 40, 'discount_pct', 0)), 2.5, 0, 1000, 'نقدًا', null, 0.5) as id \gset p1_
select create_sales_invoice(:'org_id', :'c1', :'wh', 'S-1', '2026-07-05',
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 12, 'unit_price', 100, 'discount_pct', 2.5)), 5, 0, 500, 'Visa', 'ملاحظة فاتورة', null, 0,
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 1))) as id \gset s1_
select record_customer_collection(:'org_id', :'c1', :'s1_id', 200, '2026-07-08', 'InstaPay', 'ref-1', null) as id \gset e_
select create_sales_return(:'org_id', :'s1_id', '2026-07-09',
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = :'s1_id'), 'quantity', 2, 'condition', 'resalable')), 0, null) as id \gset r1_
select create_sales_invoice(:'org_id', :'c2', :'wh', 'S-2', '2026-07-10',
  jsonb_build_array(jsonb_build_object('product_id', :'pa', 'quantity', 3, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null) as id \gset s2_

-- customer analysis = customer_balances = ledger
select t.eq((report_customer_analysis(:'org_id', :'c1')->'totals'->>'debt')::numeric, (select balance from customer_balances where customer_id = :'c1'), 'customer analysis debt = customer_balances');
select t.eq((report_customer_analysis(:'org_id', :'c1')->'totals'->>'billed')::numeric, (select total from sales_invoices where id = :'s1_id'), 'billed = the invoice total');
select t.eq((report_customer_analysis(:'org_id', :'c1')->'totals'->>'payments')::numeric, 700, 'payments = 500 at sale + 200 later');
select t.eq((report_customer_analysis(:'org_id', :'c1')->'totals'->>'returns')::numeric, (select total from sales_returns where id = :'r1_id'), 'returns = the return');
select t.eq((report_customer_analysis(:'org_id', :'c1')->'totals'->>'discounts')::numeric, 30 + 58.5 + 58.5, 'discounts = line 2.5% (30) + invoice 5% (58.5) + tier 5% (58.5)');
select t.eq((report_customer_analysis(:'org_id', :'c1')->'totals'->>'bonus_units')::numeric, 1, 'bonus units = 1');
select t.eq(jsonb_array_length(report_customer_analysis(:'org_id', :'c1')->'payments'), 2, 'both payments listed');
select t.eq_text(report_customer_analysis(:'org_id', :'c1')->'customer'->>'rep_name', 'مندوب', 'responsible rep shown');
select t.eq((report_customer_analysis(:'org_id', :'c1')->'totals'->>'debt')::numeric,
            100 + (select total from sales_invoices where id = :'s1_id') - 700 - (select total from sales_returns where id = :'r1_id'), 'debt = opening + billed − paid − returned');

-- debts report: grand total (all customers) = receivable in the P&L summary
select t.eq((select grand_total from report_customer_debts(:'org_id', null, null, false) limit 1),
            (report_summary(:'org_id')->'balances'->>'receivable')::numeric, 'customer debts grand total = receivable in report_summary');
select t.eq((select count(*) from report_customer_debts(:'org_id', null, :'rep', true)), 1, 'filter by rep');
select t.eq((select count(*) from report_customer_debts(:'org_id', 'بدون', null, true)), 1, 'search by name');
select t.ok((select last_payment_date from report_customer_debts(:'org_id', 'عميل 1', null, true)) = date '2026-07-08', 'last payment date');
select t.eq((select last_payment_amount from report_customer_debts(:'org_id', 'عميل 1', null, true)), 200, 'last payment amount');

-- supplier analysis & debts
select t.eq((report_supplier_analysis(:'org_id', :'sup')->'totals'->>'debt')::numeric, (select balance from supplier_balances where supplier_id = :'sup'), 'supplier analysis debt = supplier_balances');
select t.eq((report_supplier_analysis(:'org_id', :'sup')->'totals'->>'discounts')::numeric, 100 + 20, 'supplier discounts: 100 (2.5%) invoice level + 20 (0.5%) immediate-payment discount');
