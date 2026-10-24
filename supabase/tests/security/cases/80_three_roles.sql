-- Exactly three roles (0043): owner / sales rep / storekeeper — enforced by the database itself.
-- Everything here goes through the same entry points the REST API exposes (tables, views, RPCs), as each persona.
\set ON_ERROR_STOP on
select lab.as_owner() \gset
select * from lab.ctx \gset
select * from lab.u \gset

-- ---------------------------------------------------------------- the role catalogue
select lab.check('roles3','exactly three roles exist', (select count(*) from roles)=3 and (select count(*) from roles where key in ('owner','sales','warehouse') and organization_id is null)=3);
select lab.as_user(:'owner_a') \gset
select lab.check('roles3','nobody can create a role through the API', lab.try($q$insert into roles(name,key) values ('x','custom')$q$) like 'denied%');
select lab.check('roles3','nobody can change a role''s permissions through the API', lab.try($q$insert into role_permissions values ((select id from roles where key='warehouse' and organization_id is null),'view_financial')$q$) like 'denied%');
select lab.check('roles3','the custom-role RPCs are gone', lab.try(format($q$select create_custom_role(%L,'x',array['view_dashboard'])$q$,:'org_a')) like 'denied%');

-- ---------------------------------------------------------------- data for the isolation checks
select lab.as_owner() \gset
select lab.autoconfirm_on();
select lab.as_user(:'rep') \gset
select lab.sale(:'rep','TR-1',:'cust_a',100) as r1 \gset
select lab.as_user(:'rep2') \gset
select lab.sale(:'rep2','TR-2',:'cust_b',100) as r2 \gset
select lab.as_owner() \gset
select lab.check('roles3','setup: each rep could invoice his own customer', :'r1'='ALLOWED' and :'r2'='ALLOWED');
insert into customer_collections(organization_id,customer_id,amount,collection_date) values (:'org_a',:'cust_a',10,current_date),(:'org_a',:'cust_b',20,current_date);
insert into party_notes(organization_id,party_type,customer_id,note) values (:'org_a','customer',:'cust_b','note of rep two');

-- ---------------------------------------------------------------- REP: only his customers, everywhere
select lab.as_user(:'rep') \gset
select lab.check('rep3','sees only his own customer', (select count(*) from customers)=1 and (select sales_rep_id from customers)=:'rep_a');
select lab.check('rep3','cannot read the other rep''s customer by id', lab.val(format('select count(*) from customers where id=%L',:'cust_b'))='0');
select lab.check('rep3','cannot read an unassigned customer', lab.val(format('select count(*) from customers where id=%L',:'cust_n'))='0');
select lab.check('rep3','sales invoices: only his', (select count(*) from sales_invoices where sales_rep_id is distinct from :'rep_a')=0 and (select count(*) from sales_invoices)>=1);
select lab.check('rep3','invoice lines: only his', (select count(*) from sales_invoice_items i where not exists (select 1 from sales_invoices s where s.id=i.sales_invoice_id and s.sales_rep_id=:'rep_a'))=0);
select lab.check('rep3','the other rep''s invoice is invisible by number', lab.val($q$select count(*) from sales_invoices where invoice_number='TR-2'$q$)='0');
select lab.check('rep3','collections: only his customer''s', (select count(*) from customer_collections where customer_id<>:'cust_a')=0 and (select count(*) from customer_collections)>=1);
select lab.check('rep3','customer balances: only his customer', (select count(*) from customer_balances where customer_id<>:'cust_a')=0);
select lab.check('rep3','... and he SEES the balance (customers.view_balance)', (select balance is not null from customer_balances where customer_id=:'cust_a'));
select lab.check('rep3','notes on another rep''s customer are invisible', lab.val($q$select count(*) from party_notes where note='note of rep two'$q$)='0');
select lab.check('rep3','batch allocations / channel snapshots: only his invoices', (select count(*) from sales_batch_allocations a where not exists (select 1 from sales_invoices s where s.id=a.sales_invoice_id))=0 and (select count(*) from sales_invoice_channel_snapshot a where not exists (select 1 from sales_invoices s where s.id=a.sales_invoice_id))=0);
select lab.check('rep3','another rep''s statement is "not found"', lab.try(format($q$select * from report_party_ledger(%L,'customer',%L,null,null)$q$,:'org_a',:'cust_b')) like 'denied%');
select lab.check('rep3','his own statement works', lab.try(format($q$select * from report_party_ledger(%L,'customer',%L,null,null)$q$,:'org_a',:'cust_a'))='ALLOWED');
select lab.check('rep3','sales dashboard totals are scoped: equal to his own invoices', (select total_sales from dashboard_sales_totals(:'org_a',null)) = (select coalesce(sum(total),0) from sales_invoices) and coalesce((select total_profit from dashboard_sales_totals(:'org_a',null)),0) = 0);
select lab.check('rep3','cannot invoice the other rep''s customer', lab.sale(:'rep','TR-3',:'cust_b',100) like 'denied%');
select lab.check('rep3','cannot create a customer', lab.try(format($q$insert into customers(organization_id,name,sales_rep_id) values (%L,'x',%L)$q$,:'org_a',:'rep_a')) like 'denied%');
select lab.check('rep3','cannot re-assign his customer', lab.val(format($q$with u as (update customers set sales_rep_id=%L where id=%L returning 1) select count(*) from u$q$,:'rep_b',:'cust_a'))='1' and (select sales_rep_id from customers where id=:'cust_a')=:'rep_a');
select lab.check('rep3','cannot touch the other rep''s customer', lab.val(format($q$with u as (update customers set name='hijack' where id=%L returning 1) select count(*) from u$q$,:'cust_b'))='0');
select lab.check('rep3','cannot delete customers', lab.val(format($q$with u as (delete from customers where id=%L returning 1) select count(*) from u$q$,:'cust_a'))='0');
select lab.check('rep3','no purchases / suppliers / treasury / expenses / audit', (select count(*) from purchase_invoices)=0 and (select count(*) from suppliers)=0 and (select count(*) from treasury_movements)=0 and (select count(*) from expenses)=0 and (select count(*) from audit_logs)=0);
select lab.check('rep3','no stock internals', (select count(*) from inventory_stock)=0 and (select count(*) from stock_batches)=0 and (select count(*) from stocktakes)=0);
select lab.check('rep3','cannot create products / categories / warehouses / suppliers', lab.try(format($q$insert into products(organization_id,name) values (%L,'x')$q$,:'org_a')) like 'denied%'
  and lab.try(format($q$insert into warehouses(organization_id,name) values (%L,'x')$q$,:'org_a')) like 'denied%'
  and lab.try(format($q$insert into suppliers(organization_id,name) values (%L,'x')$q$,:'org_a')) like 'denied%');
select lab.check('rep3','cannot use the storekeeper queue or confirm dispatch', lab.try(format('select * from warehouse_sales_orders(%L)',:'org_a')) like 'denied%' and lab.try(format('select confirm_sales_dispatch(%L,gen_random_uuid())',:'org_a')) like 'denied%');
select lab.check('rep3','cannot read the stock reservation view', lab.try(format('select * from inventory_reservations(%L)',:'org_a')) like 'denied%');

-- the other rep sees the mirror image, never the first rep's data
select lab.as_user(:'rep2') \gset
select lab.check('rep3','rep two: only his customer, his invoices, his collections', (select count(*) from customers where id<>:'cust_b')=0 and (select count(*) from sales_invoices where sales_rep_id is distinct from :'rep_b')=0 and (select count(*) from customer_collections where customer_id<>:'cust_b')=0);
select lab.check('rep3','rep two cannot see rep one''s statement', lab.try(format($q$select * from report_party_ledger(%L,'customer',%L,null,null)$q$,:'org_a',:'cust_a')) like 'denied%');

-- a sales-role account with NO rep record sees nothing (it used to see the whole company)
select lab.as_user(:'plain') \gset
select lab.check('rep3','unlinked sales account: no customers, no invoices, no collections, no balances', (select count(*) from customers)=0 and (select count(*) from sales_invoices)=0 and (select count(*) from customer_collections)=0 and (select count(*) from customer_balances)=0);

-- ---------------------------------------------------------------- OWNER: sees everything, assigns freely
select lab.as_user(:'owner_a') \gset
select lab.check('owner3','sees every customer and invoice', (select count(*) from customers where organization_id=:'org_a')>=3 and lab.val($q$select count(*) from sales_invoices where invoice_number in ('TR-1','TR-2')$q$)='2');
select lab.try(format($q$insert into customers(organization_id,name,sales_rep_id) values (%L,'owner-made',%L)$q$,:'org_a',:'rep_b')) as ins \gset
select lab.check('owner3','creates a customer and assigns it to a rep', :'ins'='ALLOWED' and (select sales_rep_id from customers where name='owner-made')=:'rep_b');
select lab.check('owner3','re-assigns it at any time', lab.val(format($q$with u as (update customers set sales_rep_id=%L where name='owner-made' returning 1) select count(*) from u$q$,:'rep_a'))='1');
select lab.check('owner3','... and the new assignment is recorded', (select sales_rep_id from customers where name='owner-made')=:'rep_a');
select lab.as_user(:'rep') \gset
select lab.check('owner3','... and the rep sees it right after the assignment', (select count(*) from customers where name='owner-made')=1);
select lab.as_user(:'rep2') \gset
select lab.check('owner3','... while the other rep does not', (select count(*) from customers where name='owner-made')=0);

-- ---------------------------------------------------------------- STOREKEEPER: quantities, never money
select lab.as_user(:'warehouse') \gset
select lab.check('keeper3','no sales data at all', (select count(*) from sales_invoices)=0 and (select count(*) from sales_invoice_items)=0 and (select count(*) from sales_returns)=0 and (select count(*) from customer_collections)=0 and (select count(*) from customers)=0 and (select count(*) from customer_balances)=0 and (select count(*) from sales_representatives)=0);
select lab.check('keeper3','no purchase / supplier / money data', (select count(*) from purchase_invoices)=0 and (select count(*) from purchase_invoice_items)=0 and (select count(*) from suppliers)=0 and (select count(*) from supplier_balances)=0 and (select count(*) from treasury_movements)=0 and (select count(*) from expenses)=0 and (select count(*) from partners)=0);
select lab.check('keeper3','no prices (price table, price view, discount tiers, bonus rules)', (select count(*) from product_prices)=0 and (select count(*) from product_sale_prices)=0 and (select count(*) from discount_tiers)=0 and (select count(*) from bonus_rules)=0);
select lab.check('keeper3','no audit log and no attachments', (select count(*) from audit_logs)=0 and (select count(*) from attachments)=0);
select lab.check('keeper3','still reads what he needs: products, warehouses, stock', (select count(*) from products)>=1 and (select count(*) from warehouses)>=1 and (select count(*) from inventory_stock)>=1);
select lab.check('keeper3','stock cost is hidden', (select count(*) from stock_costs)=0 and (select count(*) from product_costs)=0);
select lab.check('keeper3','sales reports refuse him', lab.try(format('select * from report_summary(%L,null,null)',:'org_a')) like 'denied%' and lab.try(format('select * from report_sales_by(%L,''customer'',null,null,null,null,null,50,0)',:'org_a')) like 'denied%' and lab.try(format('select * from dashboard_sales_totals(%L,null)',:'org_a')) like 'denied%');
select lab.check('keeper3','financial reports refuse him', lab.try(format('select * from report_financial_position(%L)',:'org_a')) like 'denied%' and lab.try(format('select * from report_receivables_summary(%L,null)',:'org_a')) like 'denied%' and lab.try(format('select * from report_supplier_dues(%L)',:'org_a')) like 'denied%');
select lab.check('keeper3','the pricing engine refuses him', lab.try(format($q$select pricing_preview(%L,'sales','[]'::jsonb)$q$,:'org_a')) like 'denied%');
select lab.check('keeper3','cannot create products / prices / warehouses / customers / suppliers', lab.try(format($q$insert into products(organization_id,name) values (%L,'x')$q$,:'org_a')) like 'denied%'
  and lab.try(format($q$insert into customers(organization_id,name) values (%L,'x')$q$,:'org_a')) like 'denied%'
  and lab.try(format($q$insert into warehouses(organization_id,name) values (%L,'x')$q$,:'org_a')) like 'denied%'
  and lab.try(format($q$insert into product_prices(organization_id,product_id,selling_price) values (%L,%L,1)$q$,:'org_a',:'prod_a')) like 'denied%');
select lab.check('keeper3','cannot add or edit members / roles / settings', lab.try(format($q$select add_team_member(%L,'x@y.test',(select id from roles where key='owner' and organization_id is null))$q$,:'org_a')) like 'denied%');
-- the storekeeper's queue exists and carries no money
select lab.check('keeper3','the queue works and has no money keys', (select count(*) from warehouse_sales_orders(:'org_a','all'))>=2
  and (select bool_and(not (to_jsonb(o) ?| array['total','subtotal','amount_paid','discount_total','tax_total','notes','sales_rep_id'])) from warehouse_sales_orders(:'org_a','all') o)
  and (select bool_and(not (l ?| array['unit_price','unit_cost','net_total','line_total','discount'])) from warehouse_sales_orders(:'org_a','all') o, jsonb_array_elements(o.lines) l));
-- no column in any table he can read looks like money (reuses the catch-all scan from 10_regressions)
select lab.check('keeper3','catch-all scan: no cost/profit/margin column readable', (select count(*) from lab.leaks(:'warehouse'))=0);
select lab.check('keeper3','is not an owner: no manage_settings / view_financial', not has_permission(:'org_a','manage_settings') and not has_permission(:'org_a','view_financial'));
select lab.check('keeper3','but holds the work permissions', has_permission(:'org_a','warehouse.fulfill') and has_permission(:'org_a','inventory.adjust'));

-- anonymous callers and other tenants get nothing from the new RPCs
select lab.as_anon() \gset
select lab.check('keeper3','anon cannot call the queue or confirmations', lab.try(format('select * from warehouse_sales_orders(%L)',:'org_a')) like 'denied%' and lab.try(format('select confirm_sales_dispatch(%L,gen_random_uuid())',:'org_a')) like 'denied%');
select lab.as_user(:'owner_b') \gset
select lab.check('keeper3','another tenant''s owner cannot read this company''s queue', lab.try(format('select * from warehouse_sales_orders(%L)',:'org_a')) like 'denied%');
select lab.as_owner() \gset
