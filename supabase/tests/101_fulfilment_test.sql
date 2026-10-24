-- 0044: stock moves when the STOREKEEPER confirms.
-- Covers the whole cycle: purchases -> receiving, sales -> dispatch, reservations (no double selling),
-- partial / excess / repeated confirmations, returns before and after confirmation, transfers/adjustments
-- against reserved stock, the books (stock value in transit), legacy data, and who may do what.
-- (The test-only auto-confirm trigger from 01_helpers is switched OFF here: everything goes through the real RPCs.)

\set ON_ERROR_STOP on
select t.autoconfirm_off();

select t.as_owner();
insert into auth.users (id, email) values
  ('10100000-0000-0000-0000-000000000001', 'owner@fulfil.test'),
  ('10100000-0000-0000-0000-000000000002', 'keeper@fulfil.test'),
  ('10100000-0000-0000-0000-000000000003', 'rep@fulfil.test'),
  ('10100000-0000-0000-0000-000000000004', 'outsider@fulfil.test');

select t.as_user('10100000-0000-0000-0000-000000000001');
select create_organization('شركة الصرف', 'x', 'EG', 'EGP', 'ar',
  array['products','warehouses','customers','suppliers','sales','purchases','inventory','representatives','treasury','reports']) as id \gset org_

select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', '10100000-0000-0000-0000-000000000002', id, 'active' from roles where key = 'warehouse' and organization_id is null;
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', '10100000-0000-0000-0000-000000000003', id, 'active' from roles where key = 'sales' and organization_id is null;

select t.as_user('10100000-0000-0000-0000-000000000001');
insert into warehouses (organization_id, name) values (:'org_id', 'المخزن الرئيسي') returning id as w \gset
insert into warehouses (organization_id, name) values (:'org_id', 'مخزن فرعي') returning id as w2 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as s \gset
insert into products (organization_id, name, unit) values (:'org_id', 'منتج أ', 'قطعة') returning id as p \gset
insert into products (organization_id, name, unit, track_inventory) values (:'org_id', 'خدمة', 'مرة', false) returning id as svc \gset
insert into product_prices (organization_id, product_id, selling_price) values (:'org_id', :'p', 20), (:'org_id', :'svc', 50);
insert into product_costs (product_id, cost) values (:'p', 8);
insert into sales_representatives (organization_id, name, user_id, commission_basis, commission_rate) values (:'org_id', 'مندوب', '10100000-0000-0000-0000-000000000003', 'net_sales', 5) returning id as rep \gset
insert into customers (organization_id, name, sales_rep_id) values (:'org_id', 'عميل', :'rep') returning id as c \gset

-- ------------------------------------------------------------------
-- 0. Existing stock = already confirmed. Build it the OLD way (confirm-at-posting, via the test trigger):
--    100 units @ 8.  Nothing here may ever be asked of the storekeeper.
-- ------------------------------------------------------------------
select t.as_owner();
select t.autoconfirm_on();
select t.as_user('10100000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'s', :'w', 'LEGACY-1', '2026-01-01', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 100, 'unit_cost', 8, 'discount', 0)), 0, 0, 0, 'نقدًا', null) as id \gset leg_
select t.as_owner();
select t.autoconfirm_off();
select t.as_user('10100000-0000-0000-0000-000000000001');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 100, 'legacy: 100 units on hand');
select t.eq_text((select receipt_status from purchase_invoices where id = :'leg_id'), 'received', 'legacy purchase counts as received');
select t.eq((select count(*) from warehouse_purchase_orders(:'org_id', 'open')), 0, 'legacy: nothing is waiting for the storekeeper');

-- ------------------------------------------------------------------
-- 1. PURCHASE: posting moves NO stock, books the payable, records what is expected
-- ------------------------------------------------------------------
select create_purchase_invoice(:'org_id', :'s', :'w', 'P-1', '2026-02-01', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 50, 'unit_cost', 10, 'discount', 0)), 0, 0, 0, 'نقدًا', null) as id \gset pi1_
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 100, 'purchase posted: stock did NOT move');
select t.eq((select avg_cost from stock_costs sc join inventory_stock st on st.id = sc.stock_id where st.product_id = :'p' and st.warehouse_id = :'w'), 8, 'purchase posted: average cost unchanged');
select t.eq_text((select receipt_status from purchase_invoices where id = :'pi1_id'), 'pending', 'purchase waits for receiving');
select t.eq((select total from purchase_invoices where id = :'pi1_id'), 500, 'the invoice total (the payable) is booked at posting: 50 x 10');
select t.eq((select balance from supplier_balances where supplier_id = :'s'), 500 + 800, 'supplier balance = both invoices (legacy 100x8 + new 50x10)');
select t.eq((select incoming from inventory_reservations(:'org_id') where product_id = :'p'), 50, 'incoming = 50 units on the way');
-- books: 100 on hand @ 8 + 50 in transit @ 10  =  1300
select t.eq((select (report_financial_position(:'org_id') ->> 'inventory_value')::numeric), 1300, 'books: stock value counts the goods in transit (100x8 + 50x10)');

-- storekeeper: sees quantities, never money
select t.as_user('10100000-0000-0000-0000-000000000002');
select t.eq((select count(*) from warehouse_purchase_orders(:'org_id', 'open')), 1, 'storekeeper sees the one purchase waiting');
select t.ok((select not (to_jsonb(o) ?| array['total', 'subtotal', 'amount_paid', 'unit_cost', 'discount_total', 'notes']) from warehouse_purchase_orders(:'org_id', 'open') o limit 1), 'the order row carries no money columns');
select t.ok((select bool_and(not (l ?| array['unit_cost', 'unit_price', 'net_total', 'line_total', 'total'])) from warehouse_purchase_orders(:'org_id', 'open') o, jsonb_array_elements(o.lines) l), 'and neither do its lines');
select t.empty('select 1 from purchase_invoices', 'storekeeper cannot read purchase invoices directly');
select t.empty('select 1 from purchase_invoice_items', 'nor their items');
select t.empty('select 1 from suppliers', 'nor suppliers');
select t.throws(format('select confirm_purchase_receipt(%L, %L, ''[{"line_id": "%s", "quantity": 60}]'')', :'org_id', :'pi1_id', (select (l->>'line_id') from warehouse_purchase_orders(:'org_id', 'open') o, jsonb_array_elements(o.lines) l limit 1)), 'كمية زائدة', 'receiving MORE than invoiced is refused');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 100, 'a refused confirmation changes nothing');

-- partial receipt: 30 of 50
select confirm_purchase_receipt(:'org_id', :'pi1_id', jsonb_build_array(jsonb_build_object('line_id', (select (l->>'line_id') from warehouse_purchase_orders(:'org_id', 'open') o, jsonb_array_elements(o.lines) l limit 1), 'quantity', 30)), 'وصلت أول شحنة') as j \gset r1_
select t.eq_text((:'r1_j'::jsonb) ->> 'status', 'partial', 'partial receipt: status is partial');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 130, 'only the 30 received units entered stock');
-- average cost: (100x8 + 30x10) / 130
select t.as_user('10100000-0000-0000-0000-000000000001');
select t.eq((select avg_cost from stock_costs sc join inventory_stock st on st.id = sc.stock_id where st.product_id = :'p' and st.warehouse_id = :'w'), round((100 * 8 + 30 * 10)::numeric / 130, 6), 'average cost moved at RECEIPT, by the received quantity');
select t.as_user('10100000-0000-0000-0000-000000000002');
select t.eq((select count(*) from warehouse_purchase_orders(:'org_id', 'open')), 1, 'still waiting: 20 units open');
select t.eq((select (l->>'open')::numeric from warehouse_purchase_orders(:'org_id', 'open') o, jsonb_array_elements(o.lines) l limit 1), 20, 'open = 20');
select t.eq((select count(*) from inventory_movements where reference_id = :'pi1_id'), 1, 'one stock movement for the 30 units');

-- the rest, in a second confirmation (null = everything still open)
select confirm_purchase_receipt(:'org_id', :'pi1_id') as j \gset r2_
select t.eq_text((:'r2_j'::jsonb) ->> 'status', 'received', 'second confirmation completes the invoice');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 150, '150 on hand');
select t.as_user('10100000-0000-0000-0000-000000000001');
select t.eq((select avg_cost from stock_costs sc join inventory_stock st on st.id = sc.stock_id where st.product_id = :'p' and st.warehouse_id = :'w'), round((100 * 8 + 50 * 10)::numeric / 150, 6), 'final average cost = (800 + 500) / 150');
select t.as_user('10100000-0000-0000-0000-000000000002');
select t.throws(format('select confirm_purchase_receipt(%L, %L)', :'org_id', :'pi1_id'), 'تم استلام', 'the same invoice cannot be received twice');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 150, 'the refused repeat added nothing');
select t.as_user('10100000-0000-0000-0000-000000000001');
select t.eq_text((select receipt_status from purchase_invoices where id = :'pi1_id'), 'received', 'owner sees: received');
select t.eq_text((select received_by::text from purchase_invoices where id = :'pi1_id'), '10100000-0000-0000-0000-000000000002', 'who confirmed: the storekeeper');
select t.ok((select received_at is not null from purchase_invoices where id = :'pi1_id'), 'and when');
select t.eq((select count(*) from warehouse_purchase_orders(:'org_id', 'all', null, 50, 0, :'pi1_id') o, jsonb_array_elements(o.history) h where h->>'type' = 'confirm'), 2, 'history lists both confirmations');
select t.eq((select sum((h->>'quantity')::numeric) from warehouse_purchase_orders(:'org_id', 'all', null, 50, 0, :'pi1_id') o, jsonb_array_elements(o.history) h), 50, 'requested 50 = received 30 + 20');
select t.eq((select (report_financial_position(:'org_id') ->> 'inventory_value')::numeric), 1300, 'books: nothing in transit now, value unchanged = 150 x 8.6667');

-- ------------------------------------------------------------------
-- 2. SALES: posting reserves; money/cost/profit are fixed at posting; no double selling
-- ------------------------------------------------------------------
select t.as_user('10100000-0000-0000-0000-000000000003');   -- the rep
select create_sales_invoice(:'org_id', :'c', :'w', 'S-1', '2026-02-05', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 40, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset si1_
select t.as_user('10100000-0000-0000-0000-000000000001');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 150, 'sale posted: stock did NOT move');
select t.eq((select reserved from inventory_reservations(:'org_id') where product_id = :'p' and warehouse_id = :'w'), 40, '40 units are reserved for the sale');
select t.eq_text((select dispatch_status from sales_invoices where id = :'si1_id'), 'pending', 'sale waits for dispatch');
select t.eq((select total from sales_invoices where id = :'si1_id'), 800, 'the invoice total is booked at posting');
select t.ok((select f.cost_total between 346 and 347 from sales_item_financials f join sales_invoice_items i on i.id = f.sales_invoice_item_id where i.sales_invoice_id = :'si1_id'), 'COGS is fixed at posting from the average cost (40 x 8.6667)');

-- no double selling: 150 on hand, 40 reserved -> 110 available
select t.as_user('10100000-0000-0000-0000-000000000003');
select t.throws(format('select create_sales_invoice(%L, %L, %L, ''S-X'', ''2026-02-06'', %L::jsonb, 0, 0, 0, ''نقدًا'', null, null)', :'org_id', :'c', :'w',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 111, 'unit_price', 20, 'discount', 0))::text), 'المتاحة', 'the reserved 40 units cannot be sold again (111 > 110 available)');
select create_sales_invoice(:'org_id', :'c', :'w', 'S-2', '2026-02-06', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 70, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset si2_
select t.as_user('10100000-0000-0000-0000-000000000001');
select t.eq((select available from inventory_reservations(:'org_id') where product_id = :'p' and warehouse_id = :'w'), 40, 'available = 150 - 40 - 70 = 40');
select t.as_user('10100000-0000-0000-0000-000000000001');
select t.throws(format('select create_stock_transfer(%L, %L, %L, ''2026-02-07'', %L::jsonb, null)', :'org_id', :'w', :'w2',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 41))::text), 'أقل', 'a transfer cannot take stock that is promised to a sale');
select t.throws(format('select adjust_inventory_stock(%L, %L, %L, -41, ''تالف'', null)', :'org_id', :'p', :'w'), 'المحجوزة', 'nor can an adjustment write it off');

-- the storekeeper's view of the two orders
select t.as_user('10100000-0000-0000-0000-000000000002');
select t.eq((select count(*) from warehouse_sales_orders(:'org_id', 'open')), 2, 'storekeeper sees both sales orders');
select t.ok((select bool_and(not (to_jsonb(o) ?| array['total', 'subtotal', 'amount_paid', 'discount_total', 'tax_total', 'notes', 'sales_rep_id', 'payment_status'])) from warehouse_sales_orders(:'org_id', 'open') o), 'order rows carry no money, notes or rep');
select t.ok((select bool_and(not (l ?| array['unit_price', 'unit_cost', 'net_total', 'line_total', 'discount', 'total'])) from warehouse_sales_orders(:'org_id', 'open') o, jsonb_array_elements(o.lines) l), 'lines carry quantities only');
select t.empty('select 1 from sales_invoices', 'storekeeper cannot read sales invoices directly');
select t.empty('select 1 from sales_invoice_items', 'nor their items');
select t.empty('select 1 from customers', 'nor customers');
select t.empty('select 1 from product_prices', 'nor price lists');
select t.empty('select 1 from product_sale_prices', 'nor the price view');
select t.throws(format('select pricing_preview(%L, ''sales'', ''[]''::jsonb)', :'org_id'), 'صلاحية', 'nor the pricing engine');
select t.throws(format('select * from report_summary(%L, null, null)', :'org_id'), 'صلاحية', 'nor any sales report');

-- partial dispatch: 25 of 40
select confirm_sales_dispatch(:'org_id', :'si1_id', jsonb_build_array(jsonb_build_object('line_id', (select l->>'line_id' from warehouse_sales_orders(:'org_id', 'open', null, 50, 0, :'si1_id') o, jsonb_array_elements(o.lines) l limit 1), 'quantity', 25))) as j \gset d1_
select t.eq_text((:'d1_j'::jsonb) ->> 'status', 'partial', 'partial dispatch');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 125, 'only the 25 dispatched units left stock');
select t.eq((select count(*) from inventory_movements where reference_id = :'si1_id' and movement_type = 'sale'), 1, 'one sale movement, at confirmation');
select t.throws(format('select confirm_sales_dispatch(%L, %L, ''[{"line_id": "%s", "quantity": 16}]'')', :'org_id', :'si1_id', (select l->>'line_id' from warehouse_sales_orders(:'org_id', 'open', null, 50, 0, :'si1_id') o, jsonb_array_elements(o.lines) l limit 1)), 'كمية زائدة', 'dispatching more than is open (16 > 15) is refused');
select confirm_sales_dispatch(:'org_id', :'si1_id', null, 'تم التسليم للسائق') as j \gset d2_
select t.eq_text((:'d2_j'::jsonb) ->> 'status', 'dispatched', 'the rest completes the order');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 110, '110 on hand after dispatching 40');
select t.throws(format('select confirm_sales_dispatch(%L, %L)', :'org_id', :'si1_id'), 'تم صرف', 'the same invoice cannot be dispatched twice');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 110, 'the refused repeat deducted nothing');

-- who may confirm
select t.as_user('10100000-0000-0000-0000-000000000003');
select t.throws(format('select confirm_sales_dispatch(%L, %L)', :'org_id', :'si2_id'), 'صلاحية', 'a rep cannot confirm dispatch');
select t.throws(format('select * from warehouse_sales_orders(%L)', :'org_id'), 'صلاحية', 'a rep cannot open the storekeeper queue');
select t.as_user('10100000-0000-0000-0000-000000000004');
select t.throws(format('select confirm_sales_dispatch(%L, %L)', :'org_id', :'si2_id'), 'عضوًا', 'a stranger cannot confirm anything');

-- history & status for the owner
select t.as_user('10100000-0000-0000-0000-000000000001');
select t.eq_text((select dispatch_status from sales_invoices where id = :'si1_id'), 'dispatched', 'owner sees: dispatched');
select t.eq_text((select dispatched_by::text from sales_invoices where id = :'si1_id'), '10100000-0000-0000-0000-000000000002', 'who confirmed: the storekeeper');
select t.eq((select sum((h->>'quantity')::numeric) from warehouse_sales_orders(:'org_id', 'all', null, 50, 0, :'si1_id') o, jsonb_array_elements(o.history) h where h->>'type' = 'confirm'), 40, 'requested 40 = dispatched 25 + 15');

-- ------------------------------------------------------------------
-- 3. RETURNS
-- ------------------------------------------------------------------
-- 3a. sales return BEFORE dispatch: 20 of S-2's 70 units never left -> released, no stock movement
select id as it2 from sales_invoice_items where sales_invoice_id = :'si2_id' limit 1 \gset
select create_sales_return(:'org_id', :'si2_id', '2026-02-10', jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'it2', 'quantity', 20, 'condition', 'resalable')), 0, null, false, 'resalable') as id \gset sr1_
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 110, 'return before dispatch: stock untouched');
select t.eq((select count(*) from inventory_movements where movement_type = 'sale_return' and reference_id = :'sr1_id'), 0, 'and no stock movement is written');
select t.eq((select total from sales_returns where id = :'sr1_id'), 400, 'but the money side is reversed (20 x 20)');
select t.eq((select (l->>'open')::numeric from warehouse_sales_orders(:'org_id', 'open', null, 50, 0, :'si2_id') o, jsonb_array_elements(o.lines) l limit 1), 50, 'the open quantity shrank to 50');
select confirm_sales_dispatch(:'org_id', :'si2_id') as j \gset d3_
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 60, 'dispatch takes only the remaining 50 (110 - 50)');
-- 3b. sales return AFTER dispatch: goods really come back
select create_sales_return(:'org_id', :'si2_id', '2026-02-11', jsonb_build_array(jsonb_build_object('sales_invoice_item_id', :'it2', 'quantity', 10, 'condition', 'resalable')), 0, null, false, 'resalable') as id \gset sr2_
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 70, 'return after dispatch restores stock (60 + 10)');
select t.eq((select count(*) from inventory_movements where movement_type = 'sale_return' and reference_id = :'sr2_id'), 1, 'with one return movement');
-- 3c. a fully returned pending sale is cancelled and cannot be dispatched
select t.as_user('10100000-0000-0000-0000-000000000003');
select create_sales_invoice(:'org_id', :'c', :'w', 'S-3', '2026-02-12', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 5, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset si3_
select t.as_user('10100000-0000-0000-0000-000000000001');
select create_sales_return(:'org_id', :'si3_id', '2026-02-12', '[]'::jsonb, 0, null, true, 'resalable');
select t.eq_text((select dispatch_status from sales_invoices where id = :'si3_id'), 'cancelled', 'fully returned before dispatch: cancelled');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 70, 'stock unchanged');
select t.as_user('10100000-0000-0000-0000-000000000002');
select t.throws(format('select confirm_sales_dispatch(%L, %L)', :'org_id', :'si3_id'), 'أُلغيت', 'a cancelled order cannot be dispatched');
-- 3d. purchase return BEFORE receipt, then receive the rest, then return received goods
select t.as_user('10100000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'s', :'w', 'P-2', '2026-02-15', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 20, 'unit_cost', 12, 'discount', 0)), 0, 0, 0, 'نقدًا', null) as id \gset pi2_
select id as pit2 from purchase_invoice_items where purchase_invoice_id = :'pi2_id' limit 1 \gset
select create_purchase_return(:'org_id', :'pi2_id', '2026-02-16', jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', :'pit2', 'quantity', 5)), 0, null, false);
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 70, 'purchase return before receipt: stock untouched (nothing arrived to send back)');
select t.eq((select (l->>'open')::numeric from warehouse_purchase_orders(:'org_id', 'open', null, 50, 0, :'pi2_id') o, jsonb_array_elements(o.lines) l limit 1), 15, 'expected receipt shrank to 15');
select t.as_user('10100000-0000-0000-0000-000000000002');
select confirm_purchase_receipt(:'org_id', :'pi2_id') as j \gset r3_
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 85, 'receipt adds only the 15 expected units');
select t.as_user('10100000-0000-0000-0000-000000000001');
select create_purchase_return(:'org_id', :'pi2_id', '2026-02-17', jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', :'pit2', 'quantity', 3)), 0, null, false) as id \gset pr2_
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 82, 'return after receipt takes goods out of stock (85 - 3)');

-- ------------------------------------------------------------------
-- 4. Services / untracked products have nothing to move: complete at once
-- ------------------------------------------------------------------
select t.as_user('10100000-0000-0000-0000-000000000003');
select create_sales_invoice(:'org_id', :'c', :'w', 'S-SVC', '2026-02-18', jsonb_build_array(jsonb_build_object('product_id', :'svc', 'quantity', 1, 'unit_price', 50, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset siv_
select t.as_owner();
select t.eq_text((select dispatch_status from sales_invoices where id = :'siv_id'), 'dispatched', 'a services-only invoice is complete at once');
select t.eq((select count(*) from invoice_stock_lines where invoice_id = :'siv_id'), 0, 'with nothing in the storekeeper queue');

-- ------------------------------------------------------------------
-- 5. Legacy + books
-- ------------------------------------------------------------------
select t.as_user('10100000-0000-0000-0000-000000000002');
select t.throws(format('select confirm_purchase_receipt(%L, %L)', :'org_id', :'leg_id'), 'تم استلام', 'a legacy invoice is already received: nothing to confirm again');
select t.as_user('10100000-0000-0000-0000-000000000001');
select t.eq((select count(*) from warehouse_sales_orders(:'org_id', 'open')) + (select count(*) from warehouse_purchase_orders(:'org_id', 'open')), 0, 'the queue is empty: every order was handled');
select t.eq(
  round((report_financial_position(:'org_id') ->> 'inventory_value')::numeric, 2),
  round((select sum(s.quantity * coalesce(sc.avg_cost, 0)) from inventory_stock s left join stock_costs sc on sc.stock_id = s.id where s.organization_id = :'org_id'), 2),
  'books: with nothing open, stock value = on hand x average cost');
select t.eq((select count(*) from inventory_stock where organization_id = :'org_id' and quantity < 0), 0, 'no negative stock anywhere');
-- every unit that moved is traceable: movements net to what is on the shelf
select t.eq((select sum(quantity_delta) from inventory_movements where organization_id = :'org_id' and product_id = :'p' and warehouse_id = :'w'), (select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 'sum of movements = stock on hand');
