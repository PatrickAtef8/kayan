-- 0045: reps see the SELLABLE quantity while invoicing, can report a shortage to the Owner, and the database
-- refuses to sell more than what is available.
-- Covers: available = on hand − reserved − expired · reservation + dispatch never deducts twice · the backend
-- refuses over-selling (message says asked vs available) · re-check when stock changed meanwhile · the
-- database-level oversell guard · shortage reports (server-measured quantities, no duplicates, new report when the
-- need grew or the availability changed, owner statuses, rep follow-up) · who may see/do what · no effect on stock
-- movements, books or reports.
-- (The test-only auto-confirm trigger is OFF here: everything goes through the real dispatch RPCs.)

\set ON_ERROR_STOP on
select t.autoconfirm_off();

-- extra helper for this file: the statement must fail with `must` in its message and must NOT mention `forbidden`
create or replace function t.throws_without(sql text, must text, forbidden text, label text) returns void language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    if sqlerrm like '%' || forbidden || '%' then raise exception 'FAIL - %: the message mentions "%": %', label, forbidden, sqlerrm; end if;
    if sqlerrm like '%' || must || '%' then raise notice 'ok   - % (rejected: %)', label, left(sqlerrm, 80); return; end if;
    raise exception 'FAIL - %: raised the wrong error: %', label, sqlerrm;
  end;
  raise exception 'FAIL - %: expected an error, but the statement succeeded', label;
end $$;
grant execute on function t.throws_without(text, text, text, text) to authenticated, anon;

select t.as_owner();
insert into auth.users (id, email) values
  ('10200000-0000-0000-0000-000000000001', 'owner@avail.test'),
  ('10200000-0000-0000-0000-000000000002', 'keeper@avail.test'),
  ('10200000-0000-0000-0000-000000000003', 'rep1@avail.test'),
  ('10200000-0000-0000-0000-000000000004', 'rep2@avail.test'),
  ('10200000-0000-0000-0000-000000000005', 'outsider@avail.test');

select t.as_user('10200000-0000-0000-0000-000000000001');
select create_organization('شركة المتاح', 'x', 'EG', 'EGP', 'ar',
  array['products','warehouses','customers','suppliers','sales','purchases','inventory','representatives','treasury','reports']) as id \gset org_
select t.as_user('10200000-0000-0000-0000-000000000005');
select create_organization('شركة أخرى', 'x', 'EG', 'EGP', 'ar', array['products','warehouses','sales','inventory']) as id \gset other_

select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', '10200000-0000-0000-0000-000000000002', id, 'active' from roles where key = 'warehouse' and organization_id is null;
insert into organization_users (organization_id, user_id, role_id, status)
select :'org_id', u, id, 'active' from roles, (values ('10200000-0000-0000-0000-000000000003'::uuid), ('10200000-0000-0000-0000-000000000004'::uuid)) v(u)
where key = 'sales' and organization_id is null;

select t.as_user('10200000-0000-0000-0000-000000000001');
insert into warehouses (organization_id, name) values (:'org_id', 'المخزن الرئيسي') returning id as w \gset
insert into warehouses (organization_id, name) values (:'org_id', 'مخزن فرعي') returning id as w2 \gset
insert into suppliers (organization_id, name) values (:'org_id', 'مورد') returning id as s \gset
insert into products (organization_id, name, unit) values (:'org_id', 'صنف أ', 'قطعة') returning id as p \gset
insert into products (organization_id, name, unit) values (:'org_id', 'صنف ب', 'قطعة') returning id as pb \gset
insert into products (organization_id, name, unit) values (:'org_id', 'صنف منتهي', 'قطعة') returning id as pe \gset
insert into products (organization_id, name, unit) values (:'org_id', 'صنف نافد', 'قطعة') returning id as pz \gset
insert into products (organization_id, name, unit, track_inventory) values (:'org_id', 'خدمة', 'مرة', false) returning id as svc \gset
insert into product_prices (organization_id, product_id, selling_price) select :'org_id', id, 20 from products where organization_id = :'org_id';
insert into product_costs (product_id, cost) select id, 8 from products where organization_id = :'org_id' and track_inventory;
insert into sales_representatives (organization_id, name, user_id, commission_basis, commission_rate) values (:'org_id', 'مندوب 1', '10200000-0000-0000-0000-000000000003', 'net_sales', 5) returning id as rep1 \gset
insert into sales_representatives (organization_id, name, user_id, commission_basis, commission_rate) values (:'org_id', 'مندوب 2', '10200000-0000-0000-0000-000000000004', 'net_sales', 5) returning id as rep2 \gset
insert into customers (organization_id, name, sales_rep_id) values (:'org_id', 'عميل 1', :'rep1') returning id as c1 \gset
insert into customers (organization_id, name, sales_rep_id) values (:'org_id', 'عميل 2', :'rep2') returning id as c2 \gset
-- another company, to prove nothing crosses over
select t.as_user('10200000-0000-0000-0000-000000000005');
insert into warehouses (organization_id, name) values (:'other_id', 'مخزن الغير') returning id as ow \gset
insert into products (organization_id, name, unit) values (:'other_id', 'صنف الغير', 'قطعة') returning id as op \gset

-- ------------------------------------------------------------------
-- 0. Opening stock (built the old way, confirmed): A 100, B 10, E = 10 expired + 20 fresh, Z = 0
-- ------------------------------------------------------------------
select t.as_owner();
select t.autoconfirm_on();
select t.as_user('10200000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'s', :'w', 'OPEN-1', '2026-01-01', jsonb_build_array(
  jsonb_build_object('product_id', :'p', 'quantity', 100, 'unit_cost', 8, 'discount', 0),
  jsonb_build_object('product_id', :'pb', 'quantity', 10, 'unit_cost', 8, 'discount', 0),
  jsonb_build_object('product_id', :'pe', 'quantity', 10, 'unit_cost', 8, 'discount', 0, 'expiry_date', (cairo_today() - 5)::text),
  jsonb_build_object('product_id', :'pe', 'quantity', 20, 'unit_cost', 8, 'discount', 0, 'expiry_date', (cairo_today() + 90)::text)), 0, 0, 0, 'نقدًا', null) as id \gset leg_
select t.as_owner();
select t.autoconfirm_off();

-- ------------------------------------------------------------------
-- 1. What the rep sees: on hand − reserved − expired. One number, nothing else.
-- ------------------------------------------------------------------
select t.as_user('10200000-0000-0000-0000-000000000003');   -- rep 1
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'p'), 100, 'available = 100 when nothing is reserved');
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'pb'), 10, 'a second product has its own number');
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'pz'), 0, 'a product that never had stock: 0, not an error');
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'pe'), 20, 'expired units (10 of 30) are not sellable: 20');
select t.eq((select available from get_sellable_stock(:'org_id', :'w2') where product_id = :'p'), 0, 'another warehouse has its own figure (0)');
select t.ok((select available is null and not tracked from get_sellable_stock(:'org_id', :'w') where product_id = :'svc'), 'a service (no stock tracking) has no limit: available is NULL');
select t.eq((select count(*) from get_sellable_stock(:'org_id', :'w', array[:'p'::uuid, :'pb'::uuid])), 2, 'the product filter returns exactly the asked products');
select t.eq((select count(*) from get_sellable_stock(:'org_id', :'w') where product_id = :'op'), 0, 'another company''s product never shows up');
select t.ok((select (to_jsonb(g) - 'product_id' - 'tracked' - 'available') = '{}'::jsonb from get_sellable_stock(:'org_id', :'w') g limit 1), 'the row has only product, tracked, available — no cost, price, on-hand or reserved');
select t.empty('select 1 from inventory_stock', 'the rep still cannot read the stock table itself');
select t.empty('select 1 from stock_batches', 'nor the batches');

-- reservation: rep 1 sells 40 -> everybody sees 60 available, on hand is untouched
select create_sales_invoice(:'org_id', :'c1', :'w', 'S-1', '2026-02-05', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 40, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset si1_
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'p'), 60, 'after rep 1 sells 40: 60 available');
select t.as_user('10200000-0000-0000-0000-000000000004');   -- rep 2 sees the same figure, without seeing rep 1's invoice
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'p'), 60, 'rep 2 sees 60 too (the reservation is counted)');
select t.empty($$select 1 from sales_invoices where invoice_number = 'S-1'$$, 'while rep 2 cannot see rep 1''s invoice');
select t.as_user('10200000-0000-0000-0000-000000000001');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 100, 'on hand is still 100 until the storekeeper dispatches');
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'p'), 60, 'the owner sees the same available figure');

-- dispatch confirmation: on hand and reserved drop together, availability does not move (no double deduction)
select t.as_user('10200000-0000-0000-0000-000000000002');
select confirm_sales_dispatch(:'org_id', :'si1_id') as j \gset d1_
select t.as_user('10200000-0000-0000-0000-000000000003');
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'p'), 60, 'after the storekeeper confirms: still 60 — nothing deducted twice');
select t.as_user('10200000-0000-0000-0000-000000000001');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 60, 'on hand is now 60');
select t.eq((select reserved from inventory_reservations(:'org_id') where product_id = :'p' and warehouse_id = :'w'), 0, 'reserved is back to 0');
select t.eq((select count(*) from inventory_movements where reference_id = :'si1_id'), 1, 'exactly one stock movement for the sale');

-- partial dispatch: 30 sold, 10 handed over -> available 30, on hand 50, reserved 20
select t.as_user('10200000-0000-0000-0000-000000000003');
select create_sales_invoice(:'org_id', :'c1', :'w', 'S-2', '2026-02-06', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 30, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset si2_
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'p'), 30, 'sold 30 more: 30 available');
select t.as_user('10200000-0000-0000-0000-000000000002');
select confirm_sales_dispatch(:'org_id', :'si2_id', jsonb_build_array(jsonb_build_object('line_id', (select l->>'line_id' from warehouse_sales_orders(:'org_id', 'open', null, 50, 0, :'si2_id') o, jsonb_array_elements(o.lines) l limit 1), 'quantity', 10))) as j \gset d2_
select t.as_user('10200000-0000-0000-0000-000000000003');
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'p'), 30, 'a PARTIAL dispatch (10 of 30) leaves availability at 30');
select t.as_user('10200000-0000-0000-0000-000000000001');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 50, 'on hand 50 after the partial dispatch');
select t.eq((select reserved from inventory_reservations(:'org_id') where product_id = :'p' and warehouse_id = :'w'), 20, 'reserved 20 (the part not yet dispatched)');

-- a return of the undispatched part gives the units back to the sellable pool, without moving stock
select create_sales_return(:'org_id', :'si2_id', '2026-02-07', '[]'::jsonb, 0, null, true, 'resalable') as id \gset sr_
select t.as_user('10200000-0000-0000-0000-000000000003');
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'p'), 60, 'full return of S-2: 20 undispatched units released + 10 dispatched units back on the shelf = 60');
select t.as_user('10200000-0000-0000-0000-000000000001');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 60, 'on hand is 60: only the 10 that had left physically came back');
select t.eq((select reserved from inventory_reservations(:'org_id') where product_id = :'p' and warehouse_id = :'w'), 0, 'nothing is reserved any more');
select t.as_user('10200000-0000-0000-0000-000000000003');

-- ------------------------------------------------------------------
-- 2. The backend refuses to oversell, and says what was asked vs what is available
-- ------------------------------------------------------------------
select t.eq((select count(*) from sales_invoices where organization_id = :'org_id'), 2, 'setup: two invoices so far');
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'X-1', '2026-02-08', %L::jsonb, 0, 0, 0, 'نقدًا', null, null)$q$, :'org_id', :'c1', :'w',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 61, 'unit_price', 20, 'discount', 0))::text),
  'الكمية المتاحة بالمخزون أقل من الكمية المطلوبة', '61 > 60 available is refused');
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'X-1', '2026-02-08', %L::jsonb, 0, 0, 0, 'نقدًا', null, null)$q$, :'org_id', :'c1', :'w',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 61, 'unit_price', 20, 'discount', 0))::text),
  'المطلوب: 61', 'the message states the requested quantity');
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'X-1', '2026-02-08', %L::jsonb, 0, 0, 0, 'نقدًا', null, null)$q$, :'org_id', :'c1', :'w',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 61, 'unit_price', 20, 'discount', 0))::text),
  'المتاح حاليًا: 60', 'and the quantity available right now');
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'X-1', '2026-02-08', %L::jsonb, 0, 0, 0, 'نقدًا', null, null)$q$, :'org_id', :'c1', :'w',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 61, 'unit_price', 20, 'discount', 0))::text),
  'صنف أ', 'and which product');
select t.eq((select count(*) from sales_invoices where organization_id = :'org_id'), 2, 'a refused invoice is not recorded');
select t.as_owner();
select t.eq((select count(*) from invoice_stock_lines where organization_id = :'org_id' and kind = 'sales' and ordered_units = 61), 0, 'and reserves nothing');
select t.as_user('10200000-0000-0000-0000-000000000003');

-- sold out entirely: "not available right now"
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'X-2', '2026-02-08', %L::jsonb, 0, 0, 0, 'نقدًا', null, null)$q$, :'org_id', :'c1', :'w',
  jsonb_build_array(jsonb_build_object('product_id', :'pz', 'quantity', 1, 'unit_price', 20, 'discount', 0))::text),
  'غير متوفر حاليًا', 'a product with nothing left: "غير متوفر حاليًا"');
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'X-3', '2026-02-08', %L::jsonb, 0, 0, 0, 'نقدًا', null, null)$q$, :'org_id', :'c1', :'w2',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 1, 'unit_price', 20, 'discount', 0))::text),
  'غير متوفر حاليًا', 'a product that is empty in THIS warehouse (it has stock in another): not available');
-- the message never reveals what other reps have reserved
select create_sales_invoice(:'org_id', :'c1', :'w', 'S-3', '2026-02-09', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 45, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset si3_
select t.as_user('10200000-0000-0000-0000-000000000004');
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'X-4', '2026-02-09', %L::jsonb, 0, 0, 0, 'نقدًا', null, null)$q$, :'org_id', :'c2', :'w',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 16, 'unit_price', 20, 'discount', 0))::text),
  'المتاح حاليًا: 15', 'rep 2 asks for 16 and is told 15 are available');
select t.throws_without(format($q$select create_sales_invoice(%L, %L, %L, 'X-5', '2026-02-09', %L::jsonb, 0, 0, 0, 'نقدًا', null, null)$q$, :'org_id', :'c2', :'w',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 16, 'unit_price', 20, 'discount', 0))::text),
  'المتاح حاليًا', 'محجوز', 'the shortage message does not mention what others have reserved');
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'p'), 15, 'rep 2 sees 15 available');

-- stock changed while the rep was filling in the form: he saw 15, someone else took 13 first -> his 15 is refused
select t.as_user('10200000-0000-0000-0000-000000000003');
select create_sales_invoice(:'org_id', :'c1', :'w', 'S-4', '2026-02-09', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 13, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset si4_
select t.as_user('10200000-0000-0000-0000-000000000004');
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'X-6', '2026-02-09', %L::jsonb, 0, 0, 0, 'نقدًا', null, null)$q$, :'org_id', :'c2', :'w',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 15, 'unit_price', 20, 'discount', 0))::text),
  'المتاح حاليًا: 2', 'the quantity is re-checked when the sale is confirmed: 15 is no longer there, only 2');
select create_sales_invoice(:'org_id', :'c2', :'w', 'S-5', '2026-02-09', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 2, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset si5_
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'p'), 0, 'the exact remainder can be sold: 0 left');
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'X-7', '2026-02-09', %L::jsonb, 0, 0, 0, 'نقدًا', null, null)$q$, :'org_id', :'c2', :'w',
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 0.001, 'unit_price', 20, 'discount', 0))::text),
  'غير متوفر حاليًا', 'even 0.001 is refused once everything is reserved');

-- the same product on two lines counts together
select t.as_user('10200000-0000-0000-0000-000000000003');
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'X-8', '2026-02-10', %L::jsonb, 0, 0, 0, 'نقدًا', null, null)$q$, :'org_id', :'c1', :'w',
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 6, 'unit_price', 20, 'discount', 0), jsonb_build_object('product_id', :'pb', 'quantity', 6, 'unit_price', 20, 'discount', 0))::text),
  'الكمية المتاحة بالمخزون أقل', 'two lines of the same product (6 + 6 > 10) cannot sneak past the check');
-- a free bonus line is stock too (a rep has no manual-bonus right by default, so the owner gives it)
select t.as_user('10200000-0000-0000-0000-000000000001');
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'X-9', '2026-02-10', %L::jsonb, 0, 0, 0, 'نقدًا', null, null, 0, %L::jsonb)$q$, :'org_id', :'c1', :'w',
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 8, 'unit_price', 20, 'discount', 0))::text,
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 5))::text),
  'الكمية المتاحة', 'a manual bonus on top of the sold quantity (8 + 5 > 10) is refused too');
select t.as_user('10200000-0000-0000-0000-000000000003');
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'pb'), 10, 'none of those refused invoices touched the availability of B');

-- expired stock is not sellable, and the figure the rep saw is exactly what the engine enforces
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'pe'), 20, 'E: 30 on hand, 10 expired -> 20');
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'X-10', '2026-02-10', %L::jsonb, 0, 0, 0, 'نقدًا', null, null)$q$, :'org_id', :'c1', :'w',
  jsonb_build_array(jsonb_build_object('product_id', :'pe', 'quantity', 21, 'unit_price', 20, 'discount', 0))::text),
  'المتاح للبيع (غير المنتهي): 20', 'asking for 21 of E is refused, with the sellable figure (20)');
select create_sales_invoice(:'org_id', :'c1', :'w', 'S-6', '2026-02-10', jsonb_build_array(jsonb_build_object('product_id', :'pe', 'quantity', 20, 'unit_price', 20, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset si6_
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'pe'), 0, 'selling exactly the sellable 20 leaves 0');

-- a service has no stock limit
select create_sales_invoice(:'org_id', :'c1', :'w', 'S-7', '2026-02-10', jsonb_build_array(jsonb_build_object('product_id', :'svc', 'quantity', 1000, 'unit_price', 50, 'discount', 0)), 0, 0, 0, 'نقدًا', null, null) as id \gset si7_
select t.ok(:'si7_id' is not null, 'a service can be sold in any quantity');

-- ------------------------------------------------------------------
-- 3. The database-level guard: a reservation can never exceed what is on hand, whatever path writes it
-- ------------------------------------------------------------------
select t.as_owner();
select t.eq((select quantity from inventory_stock where product_id = :'pb' and warehouse_id = :'w'), 10, 'B: 10 on hand, nothing reserved');
select t.throws(format($q$do $x$ begin
    insert into invoice_stock_lines (organization_id, kind, invoice_id, product_id, warehouse_id, ordered_units) values (%L, 'sales', %L, %L, %L, 11);
    set constraints all immediate;
  end $x$$q$, :'org_id', :'si7_id', :'pb', :'w'),
  'لا يمكن حجز كمية أكبر من المتاح بالمخزون', 'writing a reservation of 11 against 10 on hand is refused by the database itself');
select t.eq((select count(*) from invoice_stock_lines where product_id = :'pb' and kind = 'sales'), 0, 'and nothing was left behind');
select t.throws(format($q$do $x$ begin
    insert into invoice_stock_lines (organization_id, kind, invoice_id, product_id, warehouse_id, ordered_units) values (%L, 'sales', %L, %L, %L, 10);
    set constraints all immediate;
    raise exception 'rollback-me';
  end $x$$q$, :'org_id', :'si7_id', :'pb', :'w'), 'rollback-me', 'a reservation of exactly what is on hand (10) passes the guard (only my own sentinel stops it)');

-- ------------------------------------------------------------------
-- 4. Shortage reports
-- ------------------------------------------------------------------
-- state now: A 0 available, B 10, E 0, Z 0.   Rep 1 reports that he needs 40 of A.
select t.as_user('10200000-0000-0000-0000-000000000003');
select report_stock_shortage(:'org_id', :'p', :'w', 40, 'عميل مستني') as j \gset r1_
select t.ok((:'r1_j'::jsonb ->> 'created')::boolean and not (:'r1_j'::jsonb ->> 'duplicate')::boolean, 'the first report is created');
select t.eq_text(:'r1_j'::jsonb ->> 'status', 'new', 'and starts as "new"');
select t.as_owner();
select t.eq((select available_qty from stock_shortage_reports where id = (:'r1_j'::jsonb ->> 'report_id')::uuid), 0, 'the AVAILABLE quantity was measured by the server (0), not sent by the browser');
select t.eq((select needed_qty from stock_shortage_reports where id = (:'r1_j'::jsonb ->> 'report_id')::uuid), 40, 'needed = 40');
select t.eq_text((select rep_name from stock_shortage_reports where id = (:'r1_j'::jsonb ->> 'report_id')::uuid), 'مندوب 1', 'the rep''s name is on the report');
select t.ok((select created_at is not null and reported_by = '10200000-0000-0000-0000-000000000003' from stock_shortage_reports where id = (:'r1_j'::jsonb ->> 'report_id')::uuid), 'with the date and the reporting user');
select t.eq((select count(*) from audit_logs where action = 'stock_shortage.reported' and entity_id = (:'r1_j'::jsonb ->> 'report_id')::uuid), 1, 'the report is in the audit log');

-- no spam: the same report again does nothing
select t.as_user('10200000-0000-0000-0000-000000000003');
select report_stock_shortage(:'org_id', :'p', :'w', 40) as j \gset r1b_
select t.ok((:'r1b_j'::jsonb ->> 'duplicate')::boolean and not (:'r1b_j'::jsonb ->> 'created')::boolean, 'sending the same report again is a duplicate');
select t.eq_text(:'r1b_j'::jsonb ->> 'report_id', :'r1_j'::jsonb ->> 'report_id', 'and points at the report that is already open');
select report_stock_shortage(:'org_id', :'p', :'w', 25) as j \gset r1c_
select t.ok((:'r1c_j'::jsonb ->> 'duplicate')::boolean, 'a SMALLER need is not worth another report either');
select t.as_owner();
select t.eq((select count(*) from stock_shortage_reports where reported_by = '10200000-0000-0000-0000-000000000003' and product_id = :'p' and superseded_by is null), 1, 'still exactly one open report for this problem');

-- the need grew -> a new report replaces the old one
select t.as_user('10200000-0000-0000-0000-000000000003');
select report_stock_shortage(:'org_id', :'p', :'w', 60, 'العميل زاد الكمية') as j \gset r2_
select t.ok((:'r2_j'::jsonb ->> 'created')::boolean and (:'r2_j'::jsonb ->> 'replaced_previous')::boolean, 'the need grew (40 -> 60): a NEW report is created');
select t.ok(:'r2_j'::jsonb ->> 'report_id' <> :'r1_j'::jsonb ->> 'report_id', 'with its own id');
select t.as_owner();
select t.eq((select count(*) from stock_shortage_reports where reported_by = '10200000-0000-0000-0000-000000000003' and product_id = :'p' and superseded_by is null), 1, 'only one open report remains');
select t.ok((select superseded_by = (:'r2_j'::jsonb ->> 'report_id')::uuid from stock_shortage_reports where id = (:'r1_j'::jsonb ->> 'report_id')::uuid), 'the old one is marked as replaced by the new one');

-- availability changed (stock arrives, still not enough) -> new report; the same state again -> duplicate
select t.autoconfirm_on();
select t.as_user('10200000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'s', :'w', 'RESTOCK-1', '2026-02-11', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 15, 'unit_cost', 8, 'discount', 0)), 0, 0, 0, 'نقدًا', null) as id \gset rs_
select t.as_owner();
select t.autoconfirm_off();
select t.as_user('10200000-0000-0000-0000-000000000003');
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'p'), 15, '15 units arrived: 15 available, still short of 60');
select report_stock_shortage(:'org_id', :'p', :'w', 60) as j \gset r3_
select t.ok((:'r3_j'::jsonb ->> 'created')::boolean, 'the availability changed (0 -> 15): a new report is allowed');
select report_stock_shortage(:'org_id', :'p', :'w', 60) as j \gset r3b_
select t.ok((:'r3b_j'::jsonb ->> 'duplicate')::boolean, 'and nothing changed since: duplicate again');
select t.as_owner();
select t.eq((select available_qty from stock_shortage_reports where id = (:'r3_j'::jsonb ->> 'report_id')::uuid), 15, 'the new report carries the new availability (15)');

-- cannot report a shortage that does not exist
select t.as_user('10200000-0000-0000-0000-000000000003');
select t.throws(format('select report_stock_shortage(%L, %L, %L, 15)', :'org_id', :'p', :'w'), 'متاحة حاليًا', 'needing 15 when 15 are available is not a shortage');
select t.throws(format('select report_stock_shortage(%L, %L, %L, 5)', :'org_id', :'pb', :'w'), 'لا حاجة', 'nor is needing 5 of B (10 available)');

-- bad input
select t.throws(format('select report_stock_shortage(%L, %L, %L, 0)', :'org_id', :'p', :'w'), 'أدخل الكمية', 'zero is refused');
select t.throws(format('select report_stock_shortage(%L, %L, %L, -3)', :'org_id', :'p', :'w'), 'أدخل الكمية', 'negative is refused');
select t.throws(format('select report_stock_shortage(%L, %L, %L, null)', :'org_id', :'p', :'w'), 'أدخل الكمية', 'null is refused');
select t.throws(format($q$select report_stock_shortage(%L, %L, %L, 'NaN'::numeric)$q$, :'org_id', :'p', :'w'), 'أدخل الكمية', 'NaN is refused');
select t.throws(format('select report_stock_shortage(%L, %L, %L, 1000000000)', :'org_id', :'p', :'w'), 'غير منطقية', 'an absurd quantity is refused');
select t.throws(format('select report_stock_shortage(%L, %L, %L, 20.0001)', :'org_id', :'p', :'w'), '3 خانات', 'more than 3 decimals is refused');
select t.throws(format('select report_stock_shortage(%L, %L, %L, 99, %L)', :'org_id', :'p', :'w', repeat('x', 501)), 'الملاحظة طويلة', 'a 501-character note is refused');
select t.throws(format('select report_stock_shortage(%L, %L, %L, 99)', :'org_id', :'svc', :'w'), 'غير مرتبط بالمخزون', 'a service has no shortage');
select t.throws(format('select report_stock_shortage(%L, %L, %L, 99)', :'org_id', gen_random_uuid(), :'w'), 'الصنف غير موجود', 'an unknown product is refused');
select t.throws(format('select report_stock_shortage(%L, %L, %L, 99)', :'org_id', :'op', :'w'), 'الصنف غير موجود', 'another company''s product is refused');
select t.throws(format('select report_stock_shortage(%L, %L, %L, 99)', :'org_id', :'p', :'ow'), 'المخزن غير موجود', 'another company''s warehouse is refused');
select t.throws(format('select report_stock_shortage(%L, %L, %L, 99)', :'other_id', :'op', :'ow'), 'لست عضوًا', 'a company the rep does not belong to is refused');

-- a different rep, same product: his own report (nobody is silenced by somebody else's report)
select t.as_user('10200000-0000-0000-0000-000000000004');
select report_stock_shortage(:'org_id', :'p', :'w', 100) as j \gset r4_
select t.ok((:'r4_j'::jsonb ->> 'created')::boolean, 'rep 2 can report the same product: it is his own report');

-- the owner can report too (he sells as well); his name falls back to his account
select t.as_user('10200000-0000-0000-0000-000000000001');
select report_stock_shortage(:'org_id', :'pz', :'w', 7) as j \gset r5_
select t.ok((:'r5_j'::jsonb ->> 'created')::boolean, 'the owner can send a report');

-- ------------------------------------------------------------------
-- 5. Who sees what
-- ------------------------------------------------------------------
select t.as_user('10200000-0000-0000-0000-000000000001');
select t.eq((select count(*) from list_stock_shortage_reports(:'org_id', 'open')), 3, 'owner: three open reports (rep 1 on A, rep 2 on A, himself on Z)');
select t.eq((select count(*) from list_stock_shortage_reports(:'org_id', 'new')), 3, 'all three are "new"');
select t.eq((select count(*) from list_stock_shortage_reports(:'org_id', null)), 5, 'the full history has 5 rows (two replaced ones included)');
select t.eq((select count(*) from list_stock_shortage_reports(:'org_id', null) where superseded), 2, 'two are flagged as replaced');
select t.ok((select bool_and(product_name is not null and warehouse_name is not null and rep_name is not null and available_qty is not null and needed_qty is not null and created_at is not null) from list_stock_shortage_reports(:'org_id', 'open')), 'every row carries product, warehouse, rep, available, needed and date');
select t.ok((select not (to_jsonb(r) ?| array['unit_cost', 'cost', 'price', 'unit_price', 'profit', 'reported_by', 'on_hand', 'reserved']) from list_stock_shortage_reports(:'org_id', 'open') r limit 1), 'the list carries no cost, price or internal columns');
select t.eq(((select stock_shortage_counts(:'org_id')) ->> 'new')::numeric, 3, 'owner badge: 3 new');

select t.as_user('10200000-0000-0000-0000-000000000003');   -- rep 1
select t.eq((select count(*) from list_stock_shortage_reports(:'org_id', 'open')), 1, 'rep 1 sees only HIS open report');
select t.eq((select count(*) from list_stock_shortage_reports(:'org_id', null) where not mine), 0, 'and none that is not his');
select t.eq((select count(*) from list_stock_shortage_reports(:'org_id', null) where rep_name <> 'مندوب 1'), 0, 'not a single row carries another rep''s name');
select t.eq(((select stock_shortage_counts(:'org_id')) ->> 'new')::numeric, 1, 'rep 1 badge: only his own');
select t.as_user('10200000-0000-0000-0000-000000000004');   -- rep 2
select t.eq((select count(*) from list_stock_shortage_reports(:'org_id', 'open')), 1, 'rep 2 sees only his own');
select t.throws(format('select set_stock_shortage_status(%L, %L, ''resolved'')', :'org_id', (:'r3_j'::jsonb ->> 'report_id')), 'للمالك فقط', 'a rep cannot change a status');
select t.throws('select 1 from stock_shortage_reports', 'permission denied', 'a rep cannot read the table directly');
select t.throws(format($q$insert into stock_shortage_reports (organization_id, product_id, warehouse_id, reported_by, rep_name, available_qty, needed_qty) values (%L, %L, %L, auth.uid(), 'x', 0, 1)$q$, :'org_id', :'p', :'w'), 'permission denied', 'a rep cannot insert a report row directly (it must be measured by the server)');
select t.throws(format($q$update stock_shortage_reports set status = 'resolved'$q$), 'permission denied', 'nor update one');
select t.throws(format($q$delete from stock_shortage_reports$q$), 'permission denied', 'nor delete one');

select t.as_user('10200000-0000-0000-0000-000000000002');   -- storekeeper
select t.throws(format('select * from list_stock_shortage_reports(%L)', :'org_id'), 'ليس لديك صلاحية', 'the storekeeper cannot list reports');
select t.throws(format('select report_stock_shortage(%L, %L, %L, 99)', :'org_id', :'p', :'w'), 'ليس لديك صلاحية', 'cannot send one');
select t.throws(format('select * from get_sellable_stock(%L, %L)', :'org_id', :'w'), 'ليس لديك صلاحية', 'and has no use for the rep''s availability view (he has the warehouse queue)');
select t.throws(format('select set_stock_shortage_status(%L, %L, ''resolved'')', :'org_id', (:'r3_j'::jsonb ->> 'report_id')), 'للمالك فقط', 'cannot change a status');
select t.throws('select 1 from stock_shortage_reports', 'permission denied', 'cannot read the table');
select t.eq(((select stock_shortage_counts(:'org_id')) ->> 'new')::numeric, 0, 'his counts are zero (and do not raise)');

select t.as_user('10200000-0000-0000-0000-000000000005');   -- a member of ANOTHER company
select t.throws(format('select * from list_stock_shortage_reports(%L)', :'org_id'), 'لست عضوًا', 'an outsider cannot list');
select t.throws(format('select * from get_sellable_stock(%L, %L)', :'org_id', :'w'), 'لست عضوًا', 'nor read availability');
select t.throws(format('select set_stock_shortage_status(%L, %L, ''resolved'')', :'org_id', (:'r3_j'::jsonb ->> 'report_id')), 'لست عضوًا', 'nor change a status');
select t.eq(((select stock_shortage_counts(:'org_id')) ->> 'new')::numeric, 0, 'counts for a stranger are zero');
select t.as_anon();
select t.throws(format('select * from get_sellable_stock(%L, %L)', :'org_id', :'w'), 'permission denied', 'anonymous callers cannot read availability');
select t.throws(format('select * from list_stock_shortage_reports(%L)', :'org_id'), 'permission denied', 'nor the reports');
select t.throws(format('select report_stock_shortage(%L, %L, %L, 9)', :'org_id', :'p', :'w'), 'permission denied', 'nor report');

-- ------------------------------------------------------------------
-- 6. The owner follows up: new -> in preparation -> provided; the rep follows the status
-- ------------------------------------------------------------------
select t.as_user('10200000-0000-0000-0000-000000000001');
select set_stock_shortage_status(:'org_id', (:'r3_j'::jsonb ->> 'report_id')::uuid, 'in_progress', 'طلبنا من المورد — الخميس') as j \gset st1_
select t.eq_text((select status from list_stock_shortage_reports(:'org_id', null) where id = (:'r3_j'::jsonb ->> 'report_id')::uuid), 'in_progress', 'owner moves it to "in preparation"');
select t.eq((select count(*) from list_stock_shortage_reports(:'org_id', 'open')), 3, 'an in-preparation report is still open');
select t.eq(((select stock_shortage_counts(:'org_id')) ->> 'in_progress')::numeric, 1, 'owner counts: one in preparation');
select t.eq(((select stock_shortage_counts(:'org_id')) ->> 'new')::numeric, 2, 'and two still new');
select t.as_user('10200000-0000-0000-0000-000000000003');
select t.eq_text((select status from list_stock_shortage_reports(:'org_id', null) where id = (:'r3_j'::jsonb ->> 'report_id')::uuid), 'in_progress', 'rep 1 sees the new status of his report');
select t.eq_text((select owner_note from list_stock_shortage_reports(:'org_id', null) where id = (:'r3_j'::jsonb ->> 'report_id')::uuid), 'طلبنا من المورد — الخميس', 'and the owner''s note');
select t.eq(((select stock_shortage_counts(:'org_id')) ->> 'in_progress')::numeric, 1, 'rep 1 badge: one in preparation');
-- a rep re-sending while it is being prepared does not bother the owner again
select report_stock_shortage(:'org_id', :'p', :'w', 60) as j \gset r3c_
select t.ok((:'r3c_j'::jsonb ->> 'duplicate')::boolean, 'rep re-sends while it is in preparation: duplicate, nobody is bothered');
select t.eq_text(:'r3c_j'::jsonb ->> 'status', 'in_progress', 'and he is told the current status');

-- 0052: closing by hand ("provided from another source") needs SELLABLE stock that covers the need.
-- This report needs 60 and only 15 are sellable -> refused; then the quantity arrives from another source.
select t.as_user('10200000-0000-0000-0000-000000000001');
select t.throws(format('select set_stock_shortage_status(%L, %L, ''resolved'')', :'org_id', (:'r3_j'::jsonb ->> 'report_id')::uuid), 'المتاح للبيع الآن', '0052: refused while the sellable stock (15) is below the need (60)');
select t.as_owner();
select t.autoconfirm_on();
select t.as_user('10200000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'s', :'w', 'SRC-OTHER', '2026-02-12', jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 100, 'unit_cost', 8, 'discount', 0)), 0, 0, 0, 'نقدًا', null) as id \gset srco_
select t.as_owner();
select t.autoconfirm_off();
select t.as_user('10200000-0000-0000-0000-000000000001');
select set_stock_shortage_status(:'org_id', (:'r3_j'::jsonb ->> 'report_id')::uuid, 'resolved') as j \gset st2_
-- the extra 100 go back to the supplier, so the rest of this test still runs on the original 15 sellable units
select id as srco_item from purchase_invoice_items where purchase_invoice_id = :'srco_id' limit 1 \gset
select create_purchase_return(:'org_id', :'srco_id', '2026-02-12', jsonb_build_array(jsonb_build_object('purchase_invoice_item_id', :'srco_item', 'quantity', 100)), 0, null, false);
select t.eq((select count(*) from list_stock_shortage_reports(:'org_id', 'resolved')), 1, 'provided: filtered as resolved');
select t.eq((select count(*) from list_stock_shortage_reports(:'org_id', 'open')), 2, 'and it leaves the open list');
select t.eq_text((select owner_note from list_stock_shortage_reports(:'org_id', 'resolved') limit 1), 'طلبنا من المورد — الخميس', 'the earlier note is kept when no new note is given');
select t.as_user('10200000-0000-0000-0000-000000000003');
select t.eq(((select stock_shortage_counts(:'org_id')) ->> 'ready')::numeric, 1, 'rep 1 is told one of his reports is ready (provided)');
select t.as_user('10200000-0000-0000-0000-000000000004');
select t.eq(((select stock_shortage_counts(:'org_id')) ->> 'ready')::numeric, 0, 'rep 2 is not told about rep 1''s');

-- status rules
select t.as_user('10200000-0000-0000-0000-000000000001');
select t.throws(format('select set_stock_shortage_status(%L, %L, ''resolved'')', :'org_id', (:'r3_j'::jsonb ->> 'report_id')), 'بهذه الحالة بالفعل', 'setting the same status again is refused');
select t.throws(format('select set_stock_shortage_status(%L, %L, ''done'')', :'org_id', (:'r3_j'::jsonb ->> 'report_id')), 'حالة غير صحيحة', 'an unknown status is refused');
select t.throws(format('select set_stock_shortage_status(%L, %L, null)', :'org_id', (:'r3_j'::jsonb ->> 'report_id')), 'حالة غير صحيحة', 'null is refused');
select t.throws(format('select set_stock_shortage_status(%L, %L, ''resolved'')', :'org_id', gen_random_uuid()), 'غير موجود', 'an unknown report is refused');
select t.throws(format('select set_stock_shortage_status(%L, %L, ''resolved'')', :'org_id', (:'r1_j'::jsonb ->> 'report_id')), 'استبدال', 'a replaced report cannot be moved');
select t.throws(format('select set_stock_shortage_status(%L, %L, ''in_progress'', %L)', :'org_id', (:'r4_j'::jsonb ->> 'report_id'), repeat('x', 501)), 'الملاحظة طويلة', 'an over-long note is refused');
select t.eq((select count(*) from audit_logs where action = 'stock_shortage.status_changed'), 2, 'each status change is in the audit log');

-- after "provided", a rep who is still short can report again (it is a new problem)
select t.as_user('10200000-0000-0000-0000-000000000003');
select report_stock_shortage(:'org_id', :'p', :'w', 60) as j \gset r6_
select t.ok((:'r6_j'::jsonb ->> 'created')::boolean, 'a resolved report does not block a new one');
select t.as_user('10200000-0000-0000-0000-000000000001');
select t.eq((select count(*) from list_stock_shortage_reports(:'org_id', 'open')), 3, 'owner: three open again');

-- ------------------------------------------------------------------
-- 7. None of this touches stock, movements or the books
-- ------------------------------------------------------------------
select t.as_owner();
select sum(quantity) as qty_before from inventory_stock where organization_id = :'org_id' \gset
select count(*) as mv_before from inventory_movements where organization_id = :'org_id' \gset
select t.as_user('10200000-0000-0000-0000-000000000001');
select (report_financial_position(:'org_id') ->> 'inventory_value')::numeric as val_before \gset
select t.as_user('10200000-0000-0000-0000-000000000004');
select report_stock_shortage(:'org_id', :'pe', :'w', 12) as j \gset r7_
select count(*) as n_read from get_sellable_stock(:'org_id', :'w') \gset
select t.as_user('10200000-0000-0000-0000-000000000001');
select set_stock_shortage_status(:'org_id', (:'r7_j'::jsonb ->> 'report_id')::uuid, 'in_progress');
select t.eq((select sum(quantity) from inventory_stock where organization_id = :'org_id'), :'qty_before'::numeric, 'reports and availability reads never change stock');
select t.eq((select count(*) from inventory_movements where organization_id = :'org_id'), :'mv_before'::numeric, 'nor create stock movements');
select t.eq((select (report_financial_position(:'org_id') ->> 'inventory_value')::numeric), :'val_before'::numeric, 'nor the stock value in the books');

-- Dispatching EVERYTHING that is still open must not move availability at all (no double deduction),
-- and afterwards on hand = what is left to sell, reserved = 0.
select t.as_user('10200000-0000-0000-0000-000000000003');
select available as a_before from get_sellable_stock(:'org_id', :'w') where product_id = :'p' \gset
select available as e_before from get_sellable_stock(:'org_id', :'w') where product_id = :'pe' \gset
select t.as_user('10200000-0000-0000-0000-000000000002');
select confirm_sales_dispatch(:'org_id', :'si3_id') is not null as d3 \gset
select confirm_sales_dispatch(:'org_id', :'si4_id') is not null as d4 \gset
select confirm_sales_dispatch(:'org_id', :'si5_id') is not null as d5 \gset
select confirm_sales_dispatch(:'org_id', :'si6_id') is not null as d6 \gset
select t.as_user('10200000-0000-0000-0000-000000000003');
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'p'), :'a_before'::numeric, 'A: dispatching S-3, S-4 and S-5 leaves availability exactly where it was (15)');
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'pe'), :'e_before'::numeric, 'E: the same after dispatching S-6');
select t.as_user('10200000-0000-0000-0000-000000000001');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 15, 'A: on hand = the 15 left');
select t.eq((select coalesce(sum(reserved), 0) from inventory_reservations(:'org_id')), 0, 'nothing is reserved any more, anywhere');
select t.eq((select count(*) from inventory_stock where organization_id = :'org_id' and quantity < 0), 0, 'no negative stock anywhere');
select t.eq((select sum(quantity_delta) from inventory_movements where organization_id = :'org_id' and product_id = :'p' and warehouse_id = :'w'),
            (select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 'A: sum of movements = stock on hand');
select t.eq((select sum(quantity_delta) from inventory_movements where organization_id = :'org_id' and product_id = :'pe' and warehouse_id = :'w'),
            (select quantity from inventory_stock where product_id = :'pe' and warehouse_id = :'w'), 'E: sum of movements = stock on hand');
select t.as_owner();
select t.eq((select count(*) from fulfilment_events where kind = 'sales' and event_type = 'confirm' and invoice_id = :'si3_id'), 1, 'S-3 was confirmed exactly once');
select t.as_user('10200000-0000-0000-0000-000000000002');
select t.as_user('10200000-0000-0000-0000-000000000002');
select t.throws(format('select confirm_sales_dispatch(%L, %L)', :'org_id', :'si3_id'), 'تم صرف', 'a second confirmation of the same invoice is refused');
select t.as_owner();
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 15, 'and deducts nothing more');
-- ------------------------------------------------------------------
-- 8. Bonus units are stock too: the quantity the form must check is  paid lines + EVERY bonus unit that the
--    pricing engine returns (the same list the invoice RPC posts).  The database re-checks it all atomically.
--    State: A 15 on hand / 15 sellable, B 10 on hand / 10 sellable, nothing reserved.  (The owner invoices:
--    a rep has no manual-bonus right by default.)
-- ------------------------------------------------------------------
select t.as_user('10200000-0000-0000-0000-000000000001');
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'pb'), 10, 'bonus section starts with B = 10 sellable');
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'p'), 15, 'and A = 15 sellable');

-- (a) the engine's answer is what the screen sums: paid B 4 + bonus B 3 + bonus A 2
select pricing_preview(:'org_id', 'sales', jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 4, 'unit_price', 20, 'discount_pct', 0)), 0, 0, 0, 0,
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 3), jsonb_build_object('product_id', :'p', 'quantity', 2))) as j \gset pv_
select t.eq((select sum((x->>'qty')::numeric) from jsonb_array_elements((:'pv_j'::jsonb) -> 'bonus') x where x->>'product' = :'pb'), 3, 'the engine reports the bonus of the SAME product (3 x B)');
select t.eq((select sum((x->>'qty')::numeric) from jsonb_array_elements((:'pv_j'::jsonb) -> 'bonus') x where x->>'product' = :'p'), 2, 'and the bonus of ANOTHER product (2 x A)');

-- (b) what the form computes (paid + engine bonus) is exactly what gets reserved
select create_sales_invoice(:'org_id', :'c1', :'w', 'B-1', '2026-03-01', jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 4, 'unit_price', 20, 'discount_pct', 0)), 0, 0, 0, 'نقدًا', null, null, 0,
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 3), jsonb_build_object('product_id', :'p', 'quantity', 2))) as id \gset b1_
select t.as_owner();
select t.eq((select coalesce(sum(ordered_units), 0) from invoice_stock_lines where invoice_id = :'b1_id' and product_id = :'pb'), 7, 'B reserved = paid 4 + bonus 3 = 7 (what the form shows as required)');
select t.eq((select coalesce(sum(ordered_units), 0) from invoice_stock_lines where invoice_id = :'b1_id' and product_id = :'p'), 2, 'A reserved = the 2 bonus-only units');
select t.as_user('10200000-0000-0000-0000-000000000001');
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'pb'), 3, 'B has 3 left to sell');
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'p'), 13, 'A has 13 left to sell');

-- (c) over the limit only because of the bonus: paid 2 + bonus 2 = 4 > 3.  Refused, and NOTHING of it is kept
--     (the 1 bonus unit of A in the same invoice must not stay reserved: the invoice is all-or-nothing)
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'B-2', '2026-03-02', %L::jsonb, 0, 0, 0, 'نقدًا', null, null, 0, %L::jsonb)$q$, :'org_id', :'c1', :'w',
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 2, 'unit_price', 20, 'discount_pct', 0))::text,
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 2), jsonb_build_object('product_id', :'p', 'quantity', 1))::text),
  'المتاح حاليًا: 3', 'paid 2 + bonus 2 of B is 4 > 3: refused, with the real available figure');
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'p'), 13, 'the refused invoice reserved nothing of A either (atomic)');
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'pb'), 3, 'nor of B');

-- (d) a bonus-only product beyond what is free: paid line is a service (no stock), bonus A 14 > 13
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'B-3', '2026-03-02', %L::jsonb, 0, 0, 0, 'نقدًا', null, null, 0, %L::jsonb)$q$, :'org_id', :'c1', :'w',
  jsonb_build_array(jsonb_build_object('product_id', :'svc', 'quantity', 1, 'unit_price', 50, 'discount_pct', 0))::text,
  jsonb_build_array(jsonb_build_object('product_id', :'p', 'quantity', 14))::text),
  'المتاح حاليًا: 13', 'a bonus of a product that is on no paid line is still checked against its stock');

-- (e) exactly the free quantity (paid 1 + bonus 2 of B = 3; bonus 13 of A) passes, and leaves 0
select create_sales_invoice(:'org_id', :'c1', :'w', 'B-4', '2026-03-03', jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 1, 'unit_price', 20, 'discount_pct', 0)), 0, 0, 0, 'نقدًا', null, null, 0,
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 2), jsonb_build_object('product_id', :'p', 'quantity', 13))) as id \gset b4_
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'pb'), 0, 'exactly the free quantity is accepted: B left 0');
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'p'), 0, 'and A left 0');

-- (f) the last unit is gone for the next caller, and a late bonus of 0.001 is refused too
select t.throws(format($q$select create_sales_invoice(%L, %L, %L, 'B-5', '2026-03-03', %L::jsonb, 0, 0, 0, 'نقدًا', null, null, 0, %L::jsonb)$q$, :'org_id', :'c1', :'w',
  jsonb_build_array(jsonb_build_object('product_id', :'svc', 'quantity', 1, 'unit_price', 50, 'discount_pct', 0))::text,
  jsonb_build_array(jsonb_build_object('product_id', :'pb', 'quantity', 0.001))::text),
  'غير متوفر حاليًا', 'once everything is reserved even a 0.001 bonus is refused');

-- dispatch both invoices: availability does not move, books stay consistent
select t.as_user('10200000-0000-0000-0000-000000000002');
select confirm_sales_dispatch(:'org_id', :'b1_id') is not null as d1 \gset
select confirm_sales_dispatch(:'org_id', :'b4_id') is not null as d2 \gset
select t.as_user('10200000-0000-0000-0000-000000000001');
select t.eq((select available from get_sellable_stock(:'org_id', :'w') where product_id = :'pb'), 0, 'after dispatch B is still 0 sellable (10 on hand − 10 shipped)');
select t.eq((select quantity from inventory_stock where product_id = :'pb' and warehouse_id = :'w'), 0, 'B on hand = 0: paid and bonus units both left the shelf, once');
select t.eq((select quantity from inventory_stock where product_id = :'p' and warehouse_id = :'w'), 0, 'A on hand = 0');
select t.eq((select sum(quantity_delta) from inventory_movements where organization_id = :'org_id' and product_id = :'pb' and warehouse_id = :'w'), 0, 'B movements net to 0');
select t.eq((select count(*) from inventory_stock where organization_id = :'org_id' and quantity < 0), 0, 'no negative stock');
select t.as_owner();
select t.autoconfirm_on();
