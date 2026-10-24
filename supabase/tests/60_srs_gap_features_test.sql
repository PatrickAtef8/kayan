-- Phase 9-15 features: purchase returns, custom roles, warehouse transfers,
-- price tiers, global search, attachments isolation, opening balances.

\set ON_ERROR_STOP on

select t.as_owner();
insert into auth.users (id, email) values
  ('c6000000-0000-0000-0000-000000000001', 'owner@gap.test'),
  ('c6000000-0000-0000-0000-000000000002', 'sales@gap.test'),
  ('c6000000-0000-0000-0000-000000000003', 'other-owner@gap.test');

select t.as_user('c6000000-0000-0000-0000-000000000001');
select create_organization('شركة الفجوات', 'x', 'EG', 'EGP', 'ar', array['sales','customers','inventory','purchases','suppliers','expenses','treasury']) as id \gset org_
select t.as_user('c6000000-0000-0000-0000-000000000003');
select create_organization('شركة أخرى', 'x', 'EG', 'EGP', 'ar', array['sales','customers','inventory','purchases','suppliers']) as id \gset other_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', 'c6000000-0000-0000-0000-000000000002', id, 'active' from roles where key = 'sales' and organization_id is null;
select t.as_user('c6000000-0000-0000-0000-000000000001');

insert into warehouses (organization_id, name) values (:'org_id', 'مخزن 1') returning id as wh1 \gset
insert into warehouses (organization_id, name) values (:'org_id', 'مخزن 2') returning id as wh2 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as sup \gset
insert into customers (organization_id, name) values (:'org_id', 'عميل') returning id as cus \gset
insert into products (organization_id, name) values (:'org_id', 'منتج أ') returning id as prod \gset

-- ============================================================
-- Purchase returns (§20/§23/§27)
-- ============================================================
-- 100 @ 100 = 10,000, paid 4,000 → payable 6,000
select create_purchase_invoice(:'org_id', :'sup', :'wh1', 'P-1', '2026-04-01',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 100, 'unit_cost', 100, 'discount', 0)),
  0, 0, 4000, 'نقدًا', null) as id \gset p1_
select id as p1_item from purchase_invoice_items where purchase_invoice_id = :'p1_id' \gset

select t.eq((select balance from supplier_balances where supplier_id = :'sup'), 6000, 'payable before any return = 10,000 − 4,000');

-- A plain sales role has no purchases.approve
select t.as_user('c6000000-0000-0000-0000-000000000002');
select t.throws(
  format('select create_purchase_return(%L, %L, %L, %L::jsonb, 0, null)', :'org_id', :'p1_id', '2026-04-05',
    jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', :'p1_item', 'quantity', 1))::text),
  'صلاحية', 'a role without purchases.approve cannot create a purchase return');
select t.as_user('c6000000-0000-0000-0000-000000000001');

select create_purchase_return(:'org_id', :'p1_id', '2026-04-05',
  jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', :'p1_item', 'quantity', 30)), 0, 'عيب تصنيع') as id \gset r1_

select t.eq((select quantity from inventory_stock where product_id = :'prod' and warehouse_id = :'wh1'), 70, 'return takes 30 units out of stock');
select t.eq((select avg_cost from t.stock_with_cost where product_id = :'prod' and warehouse_id = :'wh1'), 100, 'return leaves the weighted-average cost untouched');
select t.eq((select total from purchase_returns where id = :'r1_id'), 3000, 'return value = 30 × 100 at the original line cost');
select t.eq((select balance from supplier_balances where supplier_id = :'sup'), 3000, 'payable drops by the return: 6,000 − 3,000');
select t.eq((select total_returned from supplier_balances where supplier_id = :'sup'), 3000, 'supplier_balances exposes total_returned');
select t.eq((select count(*) from inventory_movements where reference_id = :'r1_id' and movement_type = 'purchase_return' and quantity_delta = -30), 1, 'a purchase_return inventory movement is written');
select t.eq((select returnable from get_returnable_purchase_items(:'org_id', :'p1_id')), 70, 'returnable = 100 − 30');
select t.eq((select count(*) from audit_logs where entity = 'purchase_return' and organization_id = :'org_id'), 1, 'creating a purchase return is audited');

select t.throws(
  format('select create_purchase_return(%L, %L, %L, %L::jsonb, 0, null)', :'org_id', :'p1_id', '2026-04-06',
    jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', :'p1_item', 'quantity', 71))::text),
  'أكبر من المتاح', 'cannot return more than the remaining purchased quantity');
select t.throws(
  format('select create_purchase_return(%L, %L, %L, %L::jsonb, 5000, null)', :'org_id', :'p1_id', '2026-04-06',
    jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', :'p1_item', 'quantity', 1))::text),
  'أكبر من قيمة المرتجع', 'a cash refund larger than the return is refused');

-- Cash refund posts its own treasury movement
select create_purchase_return(:'org_id', :'p1_id', '2026-04-07',
  jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', :'p1_item', 'quantity', 5)), 200, null) as id \gset r2_
select t.eq((select count(*) from treasury_movements where source_id = :'r2_id' and category = 'purchase_return' and direction = 'in' and amount = 200), 1, 'a cash refund from the supplier is a treasury inflow');
-- 0028: the 200 cash the supplier handed back consumes 200 of the 500 credit, so payable = 6,000 − 3,000 − 500 + 200.
select t.eq((select balance from supplier_balances where supplier_id = :'sup'), 2700, 'payable = 6,000 − 3,000 − 500 + 200 cash refunded');

-- Ledger shows the return as a decrease
select t.eq((select decrease from report_party_ledger(:'org_id', 'supplier', :'sup') where entry_type = 'return' order by entry_date limit 1), 3000, 'supplier ledger lists the return as a decrease');
select t.eq((select balance from (select balance, row_number() over () as rn from report_party_ledger(:'org_id', 'supplier', :'sup')) x order by rn desc limit 1), 2700, 'ledger running balance ends at the supplier balance');

-- On-hand cap: sell most of the stock, then try to return more than is left
select create_sales_invoice(:'org_id', :'cus', :'wh1', 'S-G1', '2026-04-10',
  jsonb_build_array(jsonb_build_object('product_id', :'prod', 'quantity', 63, 'unit_price', 150, 'discount', 0)),
  0, 0, 0, null, null, null) as id \gset sg1_
select t.eq((select quantity from inventory_stock where product_id = :'prod' and warehouse_id = :'wh1'), 2, 'only 2 units left after selling 63');
select t.throws(
  format('select create_purchase_return(%L, %L, %L, %L::jsonb, 0, null)', :'org_id', :'p1_id', '2026-04-11',
    jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', :'p1_item', 'quantity', 10))::text),
  'أقل من كمية المرتجع', 'cannot return units that are no longer physically on hand');

-- Tenant isolation
select t.as_user('c6000000-0000-0000-0000-000000000003');
select t.throws(
  format('select create_purchase_return(%L, %L, %L, %L::jsonb, 0, null)', :'other_id', :'p1_id', '2026-04-11',
    jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', :'p1_item', 'quantity', 1))::text),
  'لا تنتمي', 'another organization cannot return against this org''s invoice');
select t.empty('select 1 from purchase_returns', 'other org sees no purchase returns');
select t.as_user('c6000000-0000-0000-0000-000000000001');

-- ============================================================
-- Warehouse transfers (§19): cost basis travels with the goods
-- ============================================================
insert into products (organization_id, name) values (:'org_id', 'منتج ب') returning id as prod2 \gset
select create_purchase_invoice(:'org_id', :'sup', :'wh1', 'P-2', '2026-04-12',
  jsonb_build_array(jsonb_build_object('product_id', :'prod2', 'quantity', 10, 'unit_cost', 100, 'discount', 0)), 0, 0, 0, 'نقدًا', null) as id \gset p2_
select create_purchase_invoice(:'org_id', :'sup', :'wh2', 'P-3', '2026-04-12',
  jsonb_build_array(jsonb_build_object('product_id', :'prod2', 'quantity', 10, 'unit_cost', 200, 'discount', 0)), 0, 0, 0, 'نقدًا', null) as id \gset p3_

select create_stock_transfer(:'org_id', :'wh1', :'wh2', '2026-04-13',
  jsonb_build_array(jsonb_build_object('product_id', :'prod2', 'quantity', 10)), 'إعادة توزيع') as id \gset tr1_
select t.eq((select quantity from inventory_stock where product_id = :'prod2' and warehouse_id = :'wh1'), 0, 'source warehouse emptied');
select t.eq((select quantity from inventory_stock where product_id = :'prod2' and warehouse_id = :'wh2'), 20, 'destination now holds 20');
select t.eq((select avg_cost from t.stock_with_cost where product_id = :'prod2' and warehouse_id = :'wh2'), 150, 'destination average = (10×200 + 10×100) / 20');
select t.eq((select total_value from stock_transfer_costs where transfer_id = :'tr1_id'), 1000, 'transfer value at source cost');
select t.eq((select count(*) from inventory_movements where reference_id = :'tr1_id'), 2, 'one transfer_out and one transfer_in movement');
select t.eq((select sum(quantity_delta) from inventory_movements where reference_id = :'tr1_id'), 0, 'the two movements net to zero');
select t.eq((select count(*) from audit_logs where entity = 'stock_transfer'), 1, 'transfers are audited');

select t.throws(format('select create_stock_transfer(%L, %L, %L, %L, %L::jsonb, null)', :'org_id', :'wh1', :'wh2', '2026-04-14',
  jsonb_build_array(jsonb_build_object('product_id', :'prod2', 'quantity', 1))::text), 'أقل من كمية النقل', 'cannot transfer more than the source holds');
select t.throws(format('select create_stock_transfer(%L, %L, %L, %L, %L::jsonb, null)', :'org_id', :'wh2', :'wh2', '2026-04-14',
  jsonb_build_array(jsonb_build_object('product_id', :'prod2', 'quantity', 1))::text), 'نفس المخزن', 'cannot transfer to the same warehouse');
select t.as_user('c6000000-0000-0000-0000-000000000002');
select t.throws(format('select create_stock_transfer(%L, %L, %L, %L, %L::jsonb, null)', :'org_id', :'wh2', :'wh1', '2026-04-14',
  jsonb_build_array(jsonb_build_object('product_id', :'prod2', 'quantity', 1))::text), 'صلاحية', 'a role without inventory.adjust cannot transfer stock');
select t.as_user('c6000000-0000-0000-0000-000000000001');

-- ============================================================
-- Roles are fixed (0043): owner / sales / warehouse. The custom-role builder is gone for good.
-- ============================================================
select t.eq((select count(*) from roles), 3, 'exactly three roles exist');
select t.eq((select count(*) from roles where key in ('owner', 'sales', 'warehouse') and organization_id is null), 3, 'owner, sales and warehouse');
select t.throws(format('select create_custom_role(%L, %L, array[''sales.create''])', :'org_id', 'x'), 'does not exist', 'the custom-role RPC no longer exists');
select t.throws(format('insert into roles (organization_id, name, key) values (%L, ''x'', ''custom_1'')', :'org_id'), 'permission denied', 'nobody can insert a role through the API');
select t.as_owner();
select t.throws(format('insert into roles (organization_id, name, key) values (%L, ''x'', ''custom_1'')', :'org_id'), 'roles_only_three', 'not even the table owner can add a fourth role (check constraint)');
select t.as_user('c6000000-0000-0000-0000-000000000001');
select t.throws(format('update roles set name = ''x'' where key = ''owner'''), 'permission denied', 'role names cannot be edited through the API');
select t.throws('delete from role_permissions', 'permission denied', 'role permissions cannot be edited through the API');

-- ============================================================
-- Price tiers (§17)
-- ============================================================
insert into product_prices (organization_id, product_id, selling_price, wholesale_price, distributor_price)
values (:'org_id', :'prod', 150, 130, null) on conflict (organization_id, product_id) do update set wholesale_price = 130, selling_price = 150;
select t.eq((select wholesale_price from product_prices where product_id = :'prod'), 130, 'wholesale price stored');
select t.ok((select distributor_price is null from product_prices where product_id = :'prod'), 'unset tier stays NULL (falls back to retail in the UI)');
select t.eq_text((select price_tier from customers where id = :'cus'), 'retail', 'customers default to the retail tier');
select t.throws(format('update customers set price_tier = ''vip'' where id = %L', :'cus'), 'check', 'an unknown price tier is rejected');

-- ============================================================
-- Opening balances (§56)
-- ============================================================
insert into customers (organization_id, name) values (:'org_id', 'عميل بعهدة') returning id as ocus \gset
insert into customer_opening_balances (customer_id, organization_id, amount) values (:'ocus', :'org_id', 500);
insert into suppliers (organization_id, name) values (:'org_id', 'مورد بعهدة') returning id as osup \gset
insert into supplier_opening_balances (supplier_id, organization_id, amount) values (:'osup', :'org_id', 800);
select t.eq((select balance from customer_balances where customer_id = :'ocus'), 500, 'customer balance starts at the opening balance');
select t.eq((select balance from supplier_balances where supplier_id = :'osup'), 800, 'supplier balance starts at the opening balance');
select t.eq((select total_sales from customer_balances where customer_id = :'ocus'), 0, 'opening balance is not counted as sales');

select create_sales_invoice(:'org_id', :'ocus', :'wh2', 'S-OB', '2026-04-20',
  jsonb_build_array(jsonb_build_object('product_id', :'prod2', 'quantity', 2, 'unit_price', 300, 'discount', 0)),
  0, 0, 100, 'نقدًا', null, null) as id \gset sob_
select t.eq((select balance from customer_balances where customer_id = :'ocus'), 1000, 'balance = 500 opening + 600 sale − 100 collected');
select t.eq((select balance from report_party_ledger(:'org_id', 'customer', :'ocus') where entry_type = 'sale'), 1100, 'ledger: after the sale the running balance = 500 opening + 600');
select t.eq((select balance from report_party_ledger(:'org_id', 'customer', :'ocus') where entry_type = 'collection'), 1000, 'ledger: after the collection it lands on the customer balance (1000)');
select t.eq((select balance from report_party_ledger(:'org_id', 'customer', :'ocus', '2026-04-19') where entry_type = 'opening'), 500, 'ledger opening row for a later period carries the opening balance');

-- ============================================================
-- Global search (§44)
-- ============================================================
select t.ok((select count(*) from global_search(:'org_id', 'عميل')) >= 2, 'search finds customers by name');
select t.ok(exists (select 1 from global_search(:'org_id', 'S-OB') where entity_type = 'sales_invoice'), 'search finds a sales invoice by number');
select t.ok(exists (select 1 from global_search(:'org_id', 'P-1') where entity_type = 'purchase_invoice'), 'search finds a purchase invoice by number');
select t.eq((select count(*) from global_search(:'org_id', 'ع')), 0, 'a 1-character query returns nothing');
select t.as_user('c6000000-0000-0000-0000-000000000003');
select t.throws(format('select * from global_search(%L, %L)', :'org_id', 'عميل'), 'لست عضوًا', 'search refuses a non-member');
select t.eq((select count(*) from global_search(:'other_id', 'عميل')), 0, 'other org''s search never surfaces this org''s records');
select t.as_user('c6000000-0000-0000-0000-000000000001');

-- ============================================================
-- Attachments (§55): tenant isolation on the metadata table
-- ============================================================
insert into attachments (organization_id, entity_type, entity_id, storage_path, file_name, file_size)
values (:'org_id', 'customer', :'cus', :'org_id' || '/customer/' || :'cus' || '/a.pdf', 'a.pdf', 1234);
select t.eq((select count(*) from attachments where entity_id = :'cus'), 1, 'a member can attach a file to a record');
select t.as_user('c6000000-0000-0000-0000-000000000003');
select t.empty('select 1 from attachments', 'another org cannot see this org''s attachments');
select t.throws(format('insert into attachments (organization_id, entity_type, entity_id, storage_path, file_name) values (%L, ''customer'', %L, ''x'', ''x'')', :'org_id', :'cus'), 'row-level security', 'another org cannot attach files into this org');
select t.as_user('c6000000-0000-0000-0000-000000000001');
delete from attachments where entity_id = :'cus';
select t.eq((select count(*) from audit_logs where entity = 'attachment' and organization_id = :'org_id'), 1, 'deleting an attachment is audited');

select t.as_owner();

-- ============================================================
-- Alerts (§45): outstanding collections + large expenses
-- ============================================================
select t.as_user('c6000000-0000-0000-0000-000000000001');
-- 'عميل' owes 15,000 from the S-G1 sale dated 2026-04-10 and has paid nothing.
-- Both 'عميل' (never collected) and 'عميل بعهدة' (its only collection was
-- embedded in the S-OB invoice, dated back at invoice time — not recent)
-- have an old sale, a positive balance, and no payment in the last 30 days.
select t.eq((select customer_count from report_overdue_collections(:'org_id', 30)), 2, 'both customers with an old unpaid balance and no recent payment are overdue');
select t.eq((select total_balance from report_overdue_collections(:'org_id', 30)),
  (select balance from customer_balances where customer_id = :'cus') + (select balance from customer_balances where customer_id = :'ocus'),
  'overdue total = the sum of both balances');

-- A recent collection takes a customer out of the overdue set.
select record_customer_collection(:'org_id', :'cus', null, 100, current_date, 'نقدًا', null, null);
select t.eq((select customer_count from report_overdue_collections(:'org_id', 30)), 1, 'a collection in the last 30 days clears that one customer''s overdue flag');

-- Large expenses: 5 small ones establish an average, then one big one.
select t.eq((select expense_count from report_large_expenses(:'org_id', 7)), 0, 'no large expenses while there are fewer than 5 to average');
select create_expense(:'org_id', null, null, 100, current_date, 'نقدًا', 'صغير 1', null);
select create_expense(:'org_id', null, null, 100, current_date, 'نقدًا', 'صغير 2', null);
select create_expense(:'org_id', null, null, 100, current_date, 'نقدًا', 'صغير 3', null);
select create_expense(:'org_id', null, null, 100, current_date, 'نقدًا', 'صغير 4', null);
select create_expense(:'org_id', null, null, 100, current_date, 'نقدًا', 'صغير 5', null);
select t.eq((select expense_count from report_large_expenses(:'org_id', 7)), 0, 'uniform expenses are not flagged');
select create_expense(:'org_id', null, null, 5000, current_date, 'نقدًا', 'كبير', null);
select t.eq((select expense_count from report_large_expenses(:'org_id', 7)), 1, 'an expense at >= 3x the average is flagged');
select t.eq((select largest_amount from report_large_expenses(:'org_id', 7)), 5000, 'and reported as the largest');

-- Financial-only and tenant-scoped.
select t.as_user('c6000000-0000-0000-0000-000000000002');
select t.throws(format('select * from report_overdue_collections(%L, 30)', :'org_id'), 'البيانات المالية', 'overdue collections need financial access');
select t.throws(format('select * from report_large_expenses(%L, 7)', :'org_id'), 'البيانات المالية', 'large expenses need financial access');
select t.as_user('c6000000-0000-0000-0000-000000000003');
select t.throws(format('select * from report_overdue_collections(%L, 30)', :'org_id'), 'لست عضوًا', 'another org cannot read this org''s overdue collections');
select t.as_owner();
