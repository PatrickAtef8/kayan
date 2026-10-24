-- After 0037 + 0038 are applied on top of populated data.
\set ON_ERROR_STOP on
select t.as_owner();
select t.eq((select count(*) from t.fp_before b join t.fp_after a using (tbl) where a.h <> b.h or a.n <> b.n), 0,
            'upgrade: stock, costs, movements, invoices, returns and transfers are byte-for-byte unchanged');
select t.ok((select count(*) from t.fp_after) = 15, 'upgrade: all fifteen tables were fingerprinted');
select t.ok((select sum(quantity) from inventory_stock) > 0, 'upgrade: the seed really left stock on hand');
select t.eq((select count(*) from (
   select s.product_id, s.warehouse_id, s.quantity, coalesce((select sum(b.quantity) from stock_batches b where b.product_id = s.product_id and b.warehouse_id = s.warehouse_id), 0) as bq
   from inventory_stock s) x where abs(x.quantity - x.bq) > 0.0005), 0, 'upgrade: batches add up to the stock for every product and warehouse');
select t.eq((select count(*) from stock_batches where expiry_date is not null or purchase_invoice_id is not null), 0, 'upgrade: all migrated stock is "no expiry date recorded"');
select t.eq((select count(*) from stock_batches), (select count(*) from inventory_stock where quantity > 0), 'upgrade: exactly one batch per stocked product/warehouse');
select t.eq((select count(*) from inventory_stock where quantity = 0 and exists (select 1 from stock_batches b where b.product_id = inventory_stock.product_id and b.warehouse_id = inventory_stock.warehouse_id)), 0, 'upgrade: empty stock rows got no batch');

-- the app keeps working on migrated data
select t.as_user('99000000-0000-0000-0000-000000000001');
select create_sales_invoice((select org from t.upg_ids), (select cus from t.upg_ids), (select w1 from t.upg_ids), 'U-S3', current_date,
  jsonb_build_array(jsonb_build_object('product_id', (select pa from t.upg_ids), 'quantity', 10, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) is not null as sold \gset
select t.ok(:'sold', 'upgrade: selling migrated (undated) stock works');
select t.eq((select count(*) from report_expiry((select org from t.upg_ids)) where status <> 'no_expiry'), 0, 'upgrade: the expiry report lists migrated stock as "no expiry date recorded"');
select t.ok((select count(*) from report_expiry((select org from t.upg_ids))) >= 1, 'upgrade: and it lists it');
select t.eq((select count(*) from (
   select s.quantity, coalesce((select sum(b.quantity) from stock_batches b where b.product_id = s.product_id and b.warehouse_id = s.warehouse_id), 0) as bq
   from inventory_stock s) x where abs(x.quantity - x.bq) > 0.0005), 0, 'upgrade: still consistent after a post-upgrade sale');
-- returning goods from an invoice created BEFORE the upgrade (no allocations exist for it) is safe
select pg_sleep(5.5);
select create_sales_return((select org from t.upg_ids), (select s1 from t.upg_ids), current_date,
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = (select s1 from t.upg_ids) and product_id = (select pa from t.upg_ids)), 'quantity', 2, 'condition', 'resalable')), 0, null) is not null as returned \gset
select t.ok(:'returned', 'upgrade: a return on a pre-upgrade invoice works');
select t.eq((select count(*) from (
   select s.quantity, coalesce((select sum(b.quantity) from stock_batches b where b.product_id = s.product_id and b.warehouse_id = s.warehouse_id), 0) as bq
   from inventory_stock s) x where abs(x.quantity - x.bq) > 0.0005), 0, 'upgrade: still consistent after returning a pre-upgrade sale');

-- a stock count on migrated stock: starts from the (undated) batches, changes nothing, can be cancelled
select t.as_user('99000000-0000-0000-0000-000000000001');
select t.eq_text(md5((select string_agg(x::text, '|' order by x::text) from inventory_stock x)), md5((select string_agg(x::text, '|' order by x::text) from inventory_stock x)), 'upgrade: (sanity) fingerprint helper is stable');
select start_stocktake((select org from t.upg_ids), (select w1 from t.upg_ids)) as stc \gset
select t.eq((select count(*) from stocktake_lines where stocktake_id = :'stc'), (select count(*) from stock_batches where warehouse_id = (select w1 from t.upg_ids) and organization_id = (select org from t.upg_ids)), 'upgrade: a stock count starts with one line per migrated batch');
select t.eq((select count(*) from stocktake_lines where stocktake_id = :'stc' and expiry_date is not null), 0, 'upgrade: migrated batches are counted as "no expiry date recorded"');
select cancel_stocktake((select org from t.upg_ids), :'stc'::uuid);

-- sales reports on migrated invoices (0040): existing rows untouched, report agrees with the existing sales report
select t.as_user('99000000-0000-0000-0000-000000000001');
select t.eq((select count(*) from sales_invoices where sales_channel is not null and invoice_number like 'U-S%' and invoice_number <> 'U-S3'), 0, 'upgrade: existing invoices were not given a channel (no backfill update)');
select t.eq((select count(*) from report_sales_by((select org from t.upg_ids), 'channel') where invoices > 0 and group_id = 'retail'), 1, 'upgrade: migrated invoices are reported under the channel derived from the customer tier');
select t.eq((select sum(net_revenue) from report_sales_by((select org from t.upg_ids), 'rep')), (select sum(net_sales) from report_sales_breakdown((select org from t.upg_ids), null, null, 'representative', 1000, 0)), 'upgrade: rep report = existing sales report on migrated data');
select t.eq((select sum(net_revenue) from report_sales_by((select org from t.upg_ids), 'product')), (select sum(net_sales) from report_sales_breakdown((select org from t.upg_ids), null, null, 'product', 1000, 0)), 'upgrade: product report = existing sales report on migrated data');
select t.eq((select sum(net_revenue) from report_sales_by((select org from t.upg_ids), 'channel')), (select sum(net_revenue) from report_sales_by((select org from t.upg_ids), 'product')), 'upgrade: channel total = product total');
select create_sales_invoice((select org from t.upg_ids), (select cus from t.upg_ids), (select w1 from t.upg_ids), 'U-S9', current_date,
  jsonb_build_array(jsonb_build_object('product_id', (select pa from t.upg_ids), 'quantity', 1, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0) is not null as sold9 \gset
select t.ok(:'sold9', 'upgrade: creating an invoice with the OLD call shape still works after 0040');

-- partner reports on migrated data (0041): nothing re-classified, everything reconciles
select t.as_owner();
select t.eq((select count(*) from sales_invoice_channel_snapshot), (select count(*) from sales_invoices where sales_channel is null), 'upgrade: every pre-existing invoice (NULL channel) has a frozen channel snapshot');
select t.eq((select count(*) from sales_invoices where sales_channel is null and invoice_number like 'U%' and invoice_number not in ('U-S3', 'U-S9')), (select count(*) from sales_invoice_channel_snapshot where source = 'tier_at_migration'), 'upgrade: and none of those invoices was modified (still NULL)');
select t.eq((select count(*) from purchase_invoices where due_date is not null), 0, 'upgrade: existing purchase invoices got no due date (no reclassification)');
select t.as_user('99000000-0000-0000-0000-000000000001');
select t.eq((select count(*) from report_supplier_dues((select org from t.upg_ids), null, null, true) where overdue <> 0), 0, 'upgrade: nothing is overdue on undated legacy invoices');
select t.eq((select sum(balance) from report_supplier_dues((select org from t.upg_ids), null, null, true)), (select sum(balance) from supplier_balances where organization_id = (select org from t.upg_ids)), 'upgrade: supplier dues = supplier balances on migrated data');
select t.eq((select sum(undated) from report_supplier_dues((select org from t.upg_ids), null, null, true)), (select sum(greatest(balance, 0)) from supplier_balances where organization_id = (select org from t.upg_ids)), 'upgrade: legacy balances are reported as "undated"');
select t.eq((select net_balance from report_receivables_summary((select org from t.upg_ids)) where is_total), (select sum(balance) from customer_balances where organization_id = (select org from t.upg_ids)), 'upgrade: company receivables = customer balances on migrated data');
select t.eq((select count(*) from (select party_id, sum(open_amount) s from _open_items((select org from t.upg_ids), 'customer') group by 1) o join customer_balances b on b.customer_id = o.party_id where abs(o.s - b.balance) > 0.005), 0, 'upgrade: every customer statement adds up to the balance');
-- the frozen classification survives a tier change
select retail + wholesale as before_total from (select coalesce(sum(net_revenue) filter (where group_id = 'retail'), 0) as retail, coalesce(sum(net_revenue) filter (where group_id = 'wholesale'), 0) as wholesale from report_sales_by((select org from t.upg_ids), 'channel', null, null, null, null, null, 10, 0 )) x \gset
select net_revenue as retail_before from report_sales_by((select org from t.upg_ids), 'channel') where group_id = 'retail' \gset
select t.as_owner();
update customers set price_tier = 'distributor' where id = (select cus from t.upg_ids);
select t.as_user('99000000-0000-0000-0000-000000000001');
select t.eq((select net_revenue from report_sales_by((select org from t.upg_ids), 'channel') where group_id = 'retail'), :retail_before::numeric, 'upgrade: changing the customer tier afterwards does not move historical sales between channels');

-- accounting reports on migrated data (0042)
select t.as_user('99000000-0000-0000-0000-000000000002');
select t.eq((select units from report_returns_by_reason((select org from t.upg2_ids)) where group_id = 'unclassified'), 3, 'upgrade: returns made before the reason existed are "unclassified" (2 + 1 units), nothing is guessed');
select t.eq((select coalesce(sum(units), 0) from report_returns_by_reason((select org from t.upg2_ids)) where group_id <> 'unclassified'), 0, 'upgrade: and no legacy return was given a reason');
select t.eq((select sum(damaged_units) from report_returns_by_reason((select org from t.upg2_ids))), 1, 'upgrade: the legacy condition (damaged) is still reported');
select t.eq((select sum(value) from report_returns_by_reason((select org from t.upg2_ids))), (select sum(subtotal_reversed) from sales_returns where organization_id = (select org from t.upg2_ids)), 'upgrade: returns report = the return documents');
select t.eq((select net_profit from report_profit_loss((select org from t.upg2_ids))), ((select report_summary((select org from t.upg2_ids))->'financial'->>'net_profit')::numeric), 'upgrade: P&L net profit = report_summary on migrated data');
select t.eq((select operating_expenses from report_profit_loss((select org from t.upg2_ids))), 1250, 'upgrade: operating expenses 200 + 50 + 1000 (commission payout 20 excluded)');
select t.eq((select sum(in_profit_loss) from report_expenses((select org from t.upg2_ids), null, null, 'category')), (select operating_expenses from report_profit_loss((select org from t.upg2_ids))), 'upgrade: expenses report = P&L operating expenses');
select t.eq((select sum(total) from report_expenses((select org from t.upg2_ids), null, null, 'type')), (select sum(amount) from expenses where organization_id = (select org from t.upg2_ids)), 'upgrade: every expense is classified once');
select t.eq((select count(*) from report_rep_payroll((select org from t.upg2_ids)) p join rep_monthly_performance m on m.rep_id = p.rep_id and m.month = date_trunc('month', current_date)::date where abs(p.sales_commission + p.collection_commission - m.earned_commission) > 0.005), 0, 'upgrade: sales + collection commission = the existing earned commission, per rep');
select t.ok((select collection_commission from report_rep_payroll((select org from t.upg2_ids)) where rep_id = (select repb from t.upg2_ids)) > 0, 'upgrade: the collection-basis rep earns collection commission on migrated invoices');
select t.eq((select salary_paid from report_rep_payroll((select org from t.upg2_ids)) where rep_id = (select repa from t.upg2_ids)), 1000, 'upgrade: the recorded salary is shown');
select t.eq((select count(*) from report_cash_reconciliation((select org from t.upg2_ids)) where abs(difference) > 0.005), 0, 'upgrade: treasury = documents on migrated data');
select t.eq(((select report_treasury_summary((select org from t.upg2_ids))->>'opening')::numeric), 500, 'upgrade: the account opening balance is the cash opening');
select t.eq(((select report_treasury_summary((select org from t.upg2_ids))->>'closing')::numeric), 500 + ((select report_treasury_summary((select org from t.upg2_ids))->>'total_in')::numeric) - ((select report_treasury_summary((select org from t.upg2_ids))->>'total_out')::numeric), 'upgrade: closing cash = opening + in − out');
-- new behaviour works on migrated data: with a reason, and the old call shape without one
select create_sales_return((select org from t.upg2_ids), (select s1 from t.upg2_ids), current_date,
  jsonb_build_array(jsonb_build_object('sales_invoice_item_id', (select id from sales_invoice_items where sales_invoice_id = (select s1 from t.upg2_ids)), 'quantity', 1, 'condition', 'resalable', 'reason', 'slow_moving')), 0, null) is not null as rr \gset
select t.ok(:'rr', 'upgrade: a return with a reason works after 0042');
select t.eq((select units from report_returns_by_reason((select org from t.upg2_ids)) where group_id = 'slow_moving'), 1, 'upgrade: and is reported under its reason');
select t.as_owner();
