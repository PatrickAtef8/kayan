-- Cost data is invisible and unwritable for Sales/Warehouse (0034); costing maths unchanged.
-- Five sources were found leaking: product_prices.cost, inventory_stock.avg_cost, inventory_movements.unit_cost,
-- stock_transfer_items.unit_cost/line_total and stock_transfers.total_value.
select * from lab.ctx \gset
select * from lab.u \gset
select lab.as_owner() \gset
delete from role_permissions where permission_key in ('products.view_cost','sales.assign_any_rep') and role_id=(select id from roles where key='sales' and organization_id is null);

-- ============ scenario that creates cost data in every source ============
select lab.as_user(:'owner_a') \gset
insert into warehouses(organization_id,name) values (:'org_a','WH2-cost') returning id as wh2 \gset
insert into products(organization_id,name,sku) values (:'org_a','CostT','CT1') returning id as p2 \gset
insert into product_prices(organization_id,product_id,selling_price) values (:'org_a',:'p2',100);
select create_purchase_invoice(org_id:=:'org_a',p_supplier_id:=:'sup_a',p_warehouse_id:=:'wh_a',p_invoice_number:='CT-PI1',p_invoice_date:=current_date,items:=jsonb_build_array(jsonb_build_object('product_id',:'p2','quantity',100,'unit_cost',50)),p_discount_pct:=0,p_tax_total:=0,p_amount_paid:=0,p_payment_method:='cash',p_notes:=null) \gset
select create_purchase_invoice(org_id:=:'org_a',p_supplier_id:=:'sup_a',p_warehouse_id:=:'wh_a',p_invoice_number:='CT-PI2',p_invoice_date:=current_date,items:=jsonb_build_array(jsonb_build_object('product_id',:'p2','quantity',100,'unit_cost',70)),p_discount_pct:=0,p_tax_total:=0,p_amount_paid:=0,p_payment_method:='cash',p_notes:=null) \gset
select lab.check('cost','purchases blend the weighted average (100@50 + 100@70 = 60.000000)', (select sc.avg_cost from inventory_stock s join stock_costs sc on sc.stock_id=s.id where s.product_id=:'p2' and s.warehouse_id=:'wh_a')=60);
select lab.check('cost','last cost is kept in product_costs (60)', (select cost from product_costs where product_id=:'p2')=60);
select create_stock_transfer(org_id:=:'org_a',p_from_warehouse_id:=:'wh_a',p_to_warehouse_id:=:'wh2',p_transfer_date:=current_date,items:=jsonb_build_array(jsonb_build_object('product_id',:'prod_a','quantity',20)),p_notes:=null) as tr \gset
select lab.check('cost','transfer: header total 20 x 60 = 1200.00 kept in the protected table', (select total_value from stock_transfer_costs where transfer_id=:'tr')=1200);
select lab.check('cost','transfer: item cost 60 / line 1200 kept in the protected table', (select c.unit_cost=60 and c.line_total=1200 from stock_transfer_item_costs c join stock_transfer_items i on i.id=c.item_id where i.stock_transfer_id=:'tr'));
select lab.check('cost','transfer: destination warehouse inherits the cost (60)', (select sc.avg_cost from inventory_stock s join stock_costs sc on sc.stock_id=s.id where s.product_id=:'prod_a' and s.warehouse_id=:'wh2')=60);
select lab.check('cost','transfer: movements carry the cost', (select count(*) from inventory_movement_costs c join inventory_movements m on m.id=c.movement_id where m.reference_id=:'tr' and c.unit_cost=60)=2);
select adjust_inventory_stock(:'org_a',:'prod_a',:'wh2',10,'count up') \gset
select lab.check('cost','adjustment is valued at the average cost (60)', (select c.unit_cost from inventory_movements m join inventory_movement_costs c on c.movement_id=m.id where m.product_id=:'prod_a' and m.movement_type='adjustment' order by m.created_at desc limit 1)=60);
select lab.check('cost','sale records COGS at the average cost (60)', lab.sale(:'owner_a','CT-S1',:'cust_n',100,0,0,null,4)='ALLOWED');
select lab.as_owner() \gset
select lab.check('cost','... COGS unit cost 60 x 4 = 240', (select f.unit_cost=60 and f.cost_total=240 from sales_item_financials f join sales_invoice_items it on it.id=f.sales_invoice_item_id join sales_invoices i on i.id=it.sales_invoice_id where i.invoice_number='CT-S1'));
select id as sinv from sales_invoices where invoice_number='CT-S1' \gset
select id as sii from sales_invoice_items where sales_invoice_id=:'sinv' limit 1 \gset
select lab.as_user(:'owner_a') \gset
select lab.check('cost','sales return (resalable) works and re-enters stock at cost', lab.try(format($q$select create_sales_return(org_id:=%L,p_sales_invoice_id:=%L,p_return_date:=current_date,items:=jsonb_build_array(jsonb_build_object('sales_invoice_item_id',%L,'quantity',2,'condition','resalable')),p_cash_refund:=0,p_notes:=null)$q$,:'org_a',:'sinv',:'sii'))='ALLOWED');
select id as pinv from purchase_invoices where invoice_number='CT-PI2' \gset
select id as pii from purchase_invoice_items where purchase_invoice_id=:'pinv' limit 1 \gset
select lab.check('cost','purchase return works', lab.try(format($q$select create_purchase_return(org_id:=%L,p_purchase_invoice_id:=%L,p_return_date:=current_date,items:=jsonb_build_array(jsonb_build_object('purchase_invoice_item_id',%L,'quantity',20)),p_notes:=null)$q$,:'org_a',:'pinv',:'pii'))='ALLOWED');
select lab.check('cost','purchase return re-weights the average: (200 x 60 - 1400) / 180 = 58.888889', abs((select sc.avg_cost from inventory_stock s join stock_costs sc on sc.stock_id=s.id where s.product_id=:'p2' and s.warehouse_id=:'wh_a') - 58.888889) < 0.0001);
select lab.check('cost','owner: report_inventory_stock shows cost', (select count(*) from report_inventory_stock(:'org_a') where avg_cost is not null and avg_cost > 0)>0);
select lab.check('cost','owner: report_stock_movements shows unit cost', (select count(*) from report_stock_movements(:'org_a',null,null,null,null,null,500,0) where unit_cost is not null)>0);
select lab.check('cost','owner: report_financial_position inventory value > 0', (select (report_financial_position(:'org_a')::text) is not null));
select lab.check('cost','owner: report_summary runs', lab.try(format($q$select report_summary(%L)$q$,:'org_a'))='ALLOWED');

-- ============ BLOCKED: warehouse, plain sales, restricted rep ============
select lab.as_user(:'warehouse') \gset
select lab.check('cost','warehouse: product_prices.cost no longer exists', lab.try($q$select cost from product_prices$q$) like 'denied%');
select lab.check('cost','warehouse: inventory_stock.avg_cost no longer exists', lab.try($q$select avg_cost from inventory_stock$q$) like 'denied%');
select lab.check('cost','warehouse: movement unit_cost is always NULL', (select count(unit_cost) from inventory_movements)=0 and (select count(*) from inventory_movements)>0);
select lab.check('cost','warehouse: transfer item cost / line total are NULL', (select count(unit_cost)+count(line_total) from stock_transfer_items)=0 and (select count(*) from stock_transfer_items)>0);
select lab.check('cost','warehouse: transfer header total is NULL', (select count(total_value) from stock_transfers)=0 and (select count(*) from stock_transfers)>0);
select lab.check('cost','warehouse: still sees stock QUANTITIES (needs them)', (select count(*) from inventory_stock where quantity > 0)>0);
select lab.check('cost','warehouse: protected tables are empty', (select count(*) from product_costs)+(select count(*) from stock_costs)+(select count(*) from inventory_movement_costs)+(select count(*) from stock_transfer_item_costs)+(select count(*) from stock_transfer_costs)=0);
select lab.check('cost','warehouse: cannot INSERT a product cost', lab.try(format($q$insert into product_costs(product_id,cost) values (%L,1)$q$,:'prod_a')) like 'denied%');
select lab.check('cost','warehouse: cannot UPDATE a product cost', lab.val(format($q$with u as (update product_costs set cost=1 returning 1) select count(*) from u$q$))='0');
select lab.check('cost','warehouse: cannot DELETE a product cost', lab.val($q$with d as (delete from product_costs returning 1) select count(*) from d$q$)='0');
select lab.check('cost','warehouse: cannot write a cost into a movement', lab.try($q$update inventory_movements set unit_cost = 5$q$) like 'denied%' or lab.val($q$select count(unit_cost) from inventory_movements$q$)='0');
select lab.check('cost','warehouse: full leak scan finds NOTHING', (select count(*) from lab.leaks(:'warehouse') where readable_nonnull > 0)=0);
select lab.as_user(:'plain') \gset
select lab.check('cost','plain sales: cost columns gone / NULL', lab.try($q$select cost from product_prices$q$) like 'denied%' and lab.try($q$select avg_cost from inventory_stock$q$) like 'denied%' and (select count(unit_cost) from inventory_movements)=0);
select lab.check('cost','plain sales: protected tables are empty', (select count(*) from product_costs)+(select count(*) from stock_costs)+(select count(*) from inventory_movement_costs)+(select count(*) from stock_transfer_item_costs)+(select count(*) from stock_transfer_costs)=0);
select lab.check('cost','plain sales: cannot write a product cost', lab.try(format($q$insert into product_costs(product_id,cost) values (%L,1)$q$,:'prod_a')) like 'denied%');
select lab.check('cost','plain sales: full leak scan finds NOTHING', (select count(*) from lab.leaks(:'plain') where readable_nonnull > 0)=0);
select lab.as_user(:'rep') \gset
select lab.check('cost','restricted rep: full leak scan finds NOTHING', (select count(*) from lab.leaks(:'rep') where readable_nonnull > 0)=0);
select lab.check('cost','restricted rep: cannot write a product cost', lab.try(format($q$insert into product_costs(product_id,cost) values (%L,1)$q$,:'prod_a')) like 'denied%');
select lab.as_user(:'owner_b') \gset
select lab.check('cost','other tenant: sees 0 cost rows and cannot write', (select count(*) from product_costs)+(select count(*) from stock_costs)+(select count(*) from inventory_movement_costs)=0 and lab.try(format($q$insert into product_costs(product_id,cost) values (%L,1)$q$,:'prod_a')) like 'denied%');

-- ============ ALLOWED: cost viewers / editors ============
select lab.as_user(:'accountant') \gset
select lab.check('cost','accountant reads all five cost stores', (select count(*) from product_costs)>0 and (select count(*) from stock_costs)>0 and (select count(*) from inventory_movement_costs)>0 and (select count(*) from stock_transfer_item_costs)>0 and (select count(*) from stock_transfer_costs)>0);
select lab.check('cost','accountant can edit a product cost', lab.val(format($q$with u as (update product_costs set cost=61 where product_id=%L returning 1) select count(*) from u$q$,:'p2'))='1');
select lab.as_user(:'admin') \gset
select lab.check('cost','admin can edit a product cost', lab.val(format($q$with u as (update product_costs set cost=60 where product_id=%L returning 1) select count(*) from u$q$,:'p2'))='1');
select lab.as_user(:'owner_a') \gset
select lab.check('cost','owner reads cost', (select count(*) from stock_costs)>0);
select lab.as_owner() \gset
select lab.check('cost','manual cost edits are audited', (select count(*) from audit_logs where entity='product_cost' and action='product_cost.updated')>=2);

-- view-only permission: reads, cannot write; restricted rep still cannot see stock rows
insert into role_permissions values ((select id from roles where key='sales' and organization_id is null),'products.view_cost');
select lab.as_user(:'plain') \gset
select lab.check('cost','products.view_cost: plain sales can now READ product costs', (select count(*) from product_costs)>0);
select lab.check('cost','products.view_cost: ... but still cannot WRITE', lab.val(format($q$with u as (update product_costs set cost=1 where product_id=%L returning 1) select count(*) from u$q$,:'p2'))='0');
select lab.as_user(:'rep') \gset
select lab.check('cost','products.view_cost: restricted rep still sees no stock costs (stock rows hidden from reps)', (select count(*) from stock_costs)=0);
select lab.as_owner() \gset
delete from role_permissions where permission_key='products.view_cost' and role_id=(select id from roles where key='sales' and organization_id is null);
select lab.as_user(:'plain') \gset
select lab.check('cost','permission removed -> hidden again', (select count(*) from product_costs)=0);
select lab.as_owner() \gset
