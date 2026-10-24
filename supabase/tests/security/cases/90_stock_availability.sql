-- 0045: what a rep may learn about stock, who may send / read / change shortage reports, and that the
-- database (not the screen) refuses to oversell.  Everything goes through the same entry points the REST API
-- exposes (tables, RPCs), as each persona.
\set ON_ERROR_STOP on
select lab.as_owner() \gset
select * from lab.ctx \gset
select * from lab.u \gset

-- ---------------------------------------------------------------- data: a product with a known quantity (50)
select lab.as_user(:'owner_a') \gset
insert into products(organization_id, name, sku) values (:'org_a', 'AvailProd', 'AV1') returning id as pav \gset
insert into product_prices(organization_id, product_id, selling_price) values (:'org_a', :'pav', 100);
insert into product_costs(product_id, cost) values (:'pav', 60);
select lab.as_owner() \gset
select lab.autoconfirm_on();
select lab.as_user(:'owner_a') \gset
select create_purchase_invoice(org_id:=:'org_a', p_supplier_id:=:'sup_a', p_warehouse_id:=:'wh_a', p_invoice_number:='AV-PI', p_invoice_date:=current_date,
  items:=jsonb_build_array(jsonb_build_object('product_id', :'pav', 'quantity', 50, 'unit_cost', 60)), p_discount_pct:=0, p_tax_total:=0, p_amount_paid:=0,
  p_payment_method:='cash', p_notes:=null) \gset
select lab.as_owner() \gset
select lab.autoconfirm_off();      -- from here on invoices RESERVE, exactly like production

-- ---------------------------------------------------------------- availability: who can ask
select lab.as_user(:'rep') \gset
select lab.check('avail', 'a rep reads the sellable quantity of a product', (select available from get_sellable_stock(:'org_a', :'wh_a') where product_id = :'pav') = 50);
select lab.check('avail', 'the row exposes only product / tracked / available (no cost, price, on hand, reserved)',
  (select (to_jsonb(g) - 'product_id' - 'tracked' - 'available') = '{}'::jsonb from get_sellable_stock(:'org_a', :'wh_a') g limit 1));
select lab.as_user(:'plain') \gset
select lab.check('avail', 'plain sales user: allowed', lab.try(format('select * from get_sellable_stock(%L, %L)', :'org_a', :'wh_a')) = 'ALLOWED');
select lab.as_user(:'warehouse') \gset
select lab.check('avail', 'the storekeeper is refused (he has the warehouse queue instead)', lab.try(format('select * from get_sellable_stock(%L, %L)', :'org_a', :'wh_a')) like 'denied%');
select lab.as_user(:'owner_b') \gset
select lab.check('avail', 'another company''s owner is refused', lab.try(format('select * from get_sellable_stock(%L, %L)', :'org_a', :'wh_a')) like 'denied%');
select lab.as_user(:'attacker') \gset
select lab.check('avail', 'an outsider is refused', lab.try(format('select * from get_sellable_stock(%L, %L)', :'org_a', :'wh_a')) like 'denied%');
select lab.as_anon() \gset
select lab.check('avail', 'an anonymous caller is refused', lab.try(format('select * from get_sellable_stock(%L, %L)', :'org_a', :'wh_a')) like 'denied%');
select lab.as_user(:'owner_a') \gset
select lab.check('avail', 'a warehouse of ANOTHER company is not accepted even for a member of this one', lab.try(format('select * from get_sellable_stock(%L, %L)', :'org_a', gen_random_uuid())) like '%المخزن غير موجود%');

-- ---------------------------------------------------------------- raw stock stays closed to a rep
select lab.as_user(:'rep') \gset
select lab.check('avail', 'rep: inventory_stock stays unreadable', lab.val('select count(*) from inventory_stock') = '0');
select lab.check('avail', 'rep: stock_batches stays unreadable', lab.val('select count(*) from stock_batches') = '0');
select lab.check('avail', 'rep: the reservation lines are not readable', lab.try('select * from invoice_stock_lines') like 'denied%');
select lab.check('avail', 'rep: nor the dispatch events', lab.try('select * from fulfilment_events') like 'denied%');
select lab.check('avail', 'rep: the reservation / on-hand report is refused', lab.try(format('select * from inventory_reservations(%L)', :'org_a')) like 'denied%');
select lab.check('avail', 'rep: the cost of the product is still unreadable', lab.val('select count(*) from product_costs') = '0');

-- ---------------------------------------------------------------- the backend refuses to oversell (the screen is not the rule)
select lab.as_user(:'rep') \gset
select lab.try(format($q$select create_sales_invoice(org_id:=%L, p_customer_id:=%L, p_warehouse_id:=%L, p_invoice_number:='AV-1', p_invoice_date:=current_date,
  items:=jsonb_build_array(jsonb_build_object('product_id',%L,'quantity',30,'unit_price',100,'discount_pct',0)), p_discount_pct:=0, p_tax_total:=0::numeric, p_amount_collected:=0::numeric,
  p_payment_method:='cash', p_notes:=null)$q$, :'org_a', :'cust_a', :'wh_a', :'pav')) as s1 \gset
select lab.check('avail', 'rep sells 30 of 50: allowed (reserved)', :'s1' = 'ALLOWED');
select lab.as_user(:'rep2') \gset
select lab.check('avail', 'rep 2 now sees 20 available', (select available from get_sellable_stock(:'org_a', :'wh_a') where product_id = :'pav') = 20);
select lab.try(format($q$select create_sales_invoice(org_id:=%L, p_customer_id:=%L, p_warehouse_id:=%L, p_invoice_number:='AV-2', p_invoice_date:=current_date,
  items:=jsonb_build_array(jsonb_build_object('product_id',%L,'quantity',21,'unit_price',100,'discount_pct',0)), p_discount_pct:=0, p_tax_total:=0::numeric, p_amount_collected:=0::numeric,
  p_payment_method:='cash', p_notes:=null)$q$, :'org_a', :'cust_b', :'wh_a', :'pav')) as s2 \gset
select lab.check('avail', 'rep 2 asks for 21 when 20 are free: REFUSED by the database', :'s2' like 'denied%');
select lab.check('avail', '... and told what was asked and what is available', :'s2' like '%المطلوب: 21%' and :'s2' like '%المتاح حاليًا: 20%');
select lab.check('avail', '... without revealing how much is reserved by others', :'s2' not like '%محجوز%');
select lab.as_owner() \gset
select lab.check('avail', 'the refused invoice left nothing behind', (select count(*) from sales_invoices where invoice_number = 'AV-2') = 0);
select lab.check('avail', 'on hand is untouched by reservations (50)', (select quantity from inventory_stock where product_id = :'pav' and warehouse_id = :'wh_a') = 50);
-- last line of defence: even a privileged write path cannot reserve more than is on hand
select lab.check('avail', 'the database refuses a reservation above on hand even from a privileged path',
  lab.try(format($q$do $x$ begin
      insert into invoice_stock_lines (organization_id, kind, invoice_id, product_id, warehouse_id, ordered_units)
      values (%L, 'sales', (select id from sales_invoices limit 1), %L, %L, 21);
      set constraints all immediate;
    end $x$$q$, :'org_a', :'pav', :'wh_a')) like '%لا يمكن حجز كمية أكبر من المتاح%');

-- ---------------------------------------------------------------- shortage reports: who can send, read, change
select lab.as_user(:'rep2') \gset
select report_stock_shortage(:'org_a', :'pav', :'wh_a', 40, 'x''); drop table customers; --') as j2 \gset
select lab.check('shortage', 'rep 2 sends a report (the available quantity is measured by the server)', (:'j2'::jsonb ->> 'created')::boolean);
select lab.as_owner() \gset
select lab.check('shortage', '... with the server-measured available quantity (20)', (select available_qty from stock_shortage_reports where id = (:'j2'::jsonb ->> 'report_id')::uuid) = 20);
select lab.check('shortage', '... and the note kept verbatim', (select note from stock_shortage_reports where id = (:'j2'::jsonb ->> 'report_id')::uuid) = 'x''); drop table customers; --');
select lab.check('shortage', 'the customers table is still there', to_regclass('public.customers') is not null);

select lab.as_user(:'rep2') \gset
do $$ declare i int; begin for i in 1..25 loop perform report_stock_shortage((select org_a from lab.ctx), (select id from products where sku = 'AV1'), (select wh_a from lab.ctx), 40); end loop; end $$;
select lab.as_owner() \gset
select lab.check('shortage', 'clicking "report" 25 more times creates NO additional report', (select count(*) from stock_shortage_reports where reported_by = :'rep2' and product_id = :'pav' and superseded_by is null) = 1);
select lab.check('shortage', '... and not even one more row of any kind', (select count(*) from stock_shortage_reports where reported_by = :'rep2' and product_id = :'pav') = 1);

select lab.as_user(:'rep') \gset
select lab.check('shortage', 'rep 1 (the other rep) does not see rep 2''s report', (select count(*) from list_stock_shortage_reports(:'org_a', null)) = 0);
select lab.check('shortage', 'rep 1 cannot read the table', lab.try('select * from stock_shortage_reports') like 'denied%');
select lab.check('shortage', 'rep 1 cannot change a status', lab.try(format($q$select set_stock_shortage_status(%L, %L, 'resolved')$q$, :'org_a', :'j2'::jsonb ->> 'report_id')) like '%للمالك فقط%');
select lab.check('shortage', 'rep 1 cannot write a report row by hand (it would carry a forged available quantity)',
  lab.try(format($q$insert into stock_shortage_reports (organization_id, product_id, warehouse_id, reported_by, rep_name, available_qty, needed_qty) values (%L, %L, %L, auth.uid(), 'x', 0, 1)$q$, :'org_a', :'pav', :'wh_a')) like 'denied%');
select lab.check('shortage', 'rep 1 cannot rewrite one either', lab.try($q$update stock_shortage_reports set status = 'resolved', needed_qty = 1$q$) like 'denied%');
select lab.check('shortage', 'nor delete', lab.try('delete from stock_shortage_reports') like 'denied%');
select lab.check('shortage', 'the report endpoint cannot be used to report a sufficient quantity', lab.try(format('select report_stock_shortage(%L, %L, %L, 20)', :'org_a', :'pav', :'wh_a')) like '%لا حاجة لبلاغ%');
select lab.check('shortage', 'a product of ANOTHER company is not accepted', lab.try(format('select report_stock_shortage(%L, %L, %L, 5)', :'org_a', (select id from products where organization_id = :'org_b' limit 1), :'wh_a')) like '%غير موجود%' or (select count(*) from products where organization_id = :'org_b') = 0);

select lab.as_user(:'warehouse') \gset
select lab.check('shortage', 'storekeeper: cannot list', lab.try(format('select * from list_stock_shortage_reports(%L)', :'org_a')) like 'denied%');
select lab.check('shortage', 'storekeeper: cannot report', lab.try(format('select report_stock_shortage(%L, %L, %L, 99)', :'org_a', :'pav', :'wh_a')) like 'denied%');
select lab.check('shortage', 'storekeeper: cannot change a status', lab.try(format($q$select set_stock_shortage_status(%L, %L, 'resolved')$q$, :'org_a', :'j2'::jsonb ->> 'report_id')) like '%للمالك فقط%');
select lab.check('shortage', 'storekeeper: counts are zero, no error', lab.val(format($q$select (stock_shortage_counts(%L) ->> 'new')$q$, :'org_a')) = '0');

select lab.as_user(:'owner_b') \gset
select lab.check('shortage', 'another company''s owner cannot list', lab.try(format('select * from list_stock_shortage_reports(%L)', :'org_a')) like 'denied%');
select lab.check('shortage', '... cannot change a status via his own company id either (the report is not there)', lab.try(format($q$select set_stock_shortage_status(%L, %L, 'resolved')$q$, :'org_b', :'j2'::jsonb ->> 'report_id')) like '%غير موجود%');
select lab.check('shortage', '... nor via the real company id', lab.try(format($q$select set_stock_shortage_status(%L, %L, 'resolved')$q$, :'org_a', :'j2'::jsonb ->> 'report_id')) like 'denied%');
select lab.as_user(:'attacker') \gset
select lab.check('shortage', 'an outsider cannot report', lab.try(format('select report_stock_shortage(%L, %L, %L, 99)', :'org_a', :'pav', :'wh_a')) like 'denied%');
select lab.as_anon() \gset
select lab.check('shortage', 'an anonymous caller cannot report', lab.try(format('select report_stock_shortage(%L, %L, %L, 99)', :'org_a', :'pav', :'wh_a')) like 'denied%');
select lab.check('shortage', '... nor list', lab.try(format('select * from list_stock_shortage_reports(%L)', :'org_a')) like 'denied%');

select lab.as_user(:'owner_a') \gset
select lab.check('shortage', 'the owner sees rep 2''s report (with the rep''s name)', (select count(*) from list_stock_shortage_reports(:'org_a', 'new') where rep_name = 'Rep Two') = 1);
select lab.check('shortage', 'the owner moves it to "in preparation"', lab.try(format($q$select set_stock_shortage_status(%L, %L, 'in_progress', 'ordered')$q$, :'org_a', :'j2'::jsonb ->> 'report_id')) = 'ALLOWED');
-- 0052: a report can be closed by hand only when the SELLABLE stock covers the need (40; only 20 are sellable) -> refused,
-- then the quantity arrives from another source and the admin's authorization can be tested on its own.
select lab.check('shortage', 'closing by hand is refused while the sellable stock is below the need', lab.try(format($q$select set_stock_shortage_status(%L, %L, 'resolved')$q$, :'org_a', :'j2'::jsonb ->> 'report_id')) like '%المتاح للبيع الآن%');
select lab.as_owner() \gset
select lab.autoconfirm_on();
select lab.as_user(:'owner_a') \gset
select create_purchase_invoice(org_id:=:'org_a', p_supplier_id:=:'sup_a', p_warehouse_id:=:'wh_a', p_invoice_number:='AV-PI-SRC', p_invoice_date:=current_date,
  items:=jsonb_build_array(jsonb_build_object('product_id', :'pav', 'quantity', 100, 'unit_cost', 60)), p_discount_pct:=0, p_tax_total:=0, p_amount_paid:=0,
  p_payment_method:='cash', p_notes:=null) \gset
select lab.as_owner() \gset
select lab.autoconfirm_off();
select lab.as_user(:'admin') \gset
select lab.check('shortage', 'an admin (migrated to the owner role) can finish it', lab.try(format($q$select set_stock_shortage_status(%L, %L, 'resolved')$q$, :'org_a', :'j2'::jsonb ->> 'report_id')) = 'ALLOWED');
select lab.as_user(:'rep2') \gset
select lab.check('shortage', 'rep 2 sees the status of his report', (select status from list_stock_shortage_reports(:'org_a', null) where id = (:'j2'::jsonb ->> 'report_id')::uuid) = 'resolved');
select lab.check('shortage', '... and the owner''s note', (select owner_note from list_stock_shortage_reports(:'org_a', null) where id = (:'j2'::jsonb ->> 'report_id')::uuid) = 'ordered');

-- the leak scan: no new table or column hands a rep or a storekeeper any cost
select lab.check('leak', 'rep: the cost/profit leak scan finds nothing new in the shortage or reservation tables',
  (select count(*) from lab.leaks(:'rep') where tbl in ('stock_shortage_reports', 'invoice_stock_lines', 'fulfilment_events')) = 0);
select lab.as_owner() \gset
select lab.autoconfirm_on();
