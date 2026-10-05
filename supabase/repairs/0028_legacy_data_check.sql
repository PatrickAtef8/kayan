-- READ-ONLY. Run after applying 0028 to list HISTORICAL rows created under the old rules.
-- 0028 deliberately does not rewrite past invoices or returns: their totals are what the
-- customer / supplier was actually billed, and changing them would silently move balances.
-- Review these rows and decide case by case.
--
--   psql "$DATABASE_URL" -f supabase/repairs/0028_legacy_data_check.sql

\echo '--- 1. Returns made before 0028 on invoices that carried tax (the tax was not reversed)'
select r.organization_id, i.invoice_number, r.return_date, r.total as credited, i.tax_total as invoice_tax
from sales_returns r join sales_invoices i on i.id = r.sales_invoice_id
where r.tax_reversed = 0 and i.tax_total > 0
order by r.return_date;

\echo '--- 2. Purchase returns made before 0028 on invoices that carried tax'
select r.organization_id, i.invoice_number, r.return_date, r.total as credited, i.tax_total as invoice_tax
from purchase_returns r join purchase_invoices i on i.id = r.purchase_invoice_id
where r.tax_reversed = 0 and i.tax_total > 0
order by r.return_date;

\echo '--- 3. Stock rows that are negative (sold below zero stock, at cost 0)'
select s.organization_id, p.name as product, w.name as warehouse, s.quantity, s.avg_cost
from inventory_stock s
join products p on p.id = s.product_id
join warehouses w on w.id = s.warehouse_id
where s.quantity < 0
order by s.quantity;

\echo '--- 4. Invoices paid beyond their total'
select organization_id, invoice_number, total, amount_paid, round(amount_paid - total, 2) as overpaid
from sales_invoices where amount_paid > total + 0.005
union all
select organization_id, invoice_number, total, amount_paid, round(amount_paid - total, 2)
from purchase_invoices where amount_paid > total + 0.005
order by 1;

\echo '--- 5. Invoices with a negative total or negative tax'
select organization_id, invoice_number, subtotal, discount_total, tax_total, total
from sales_invoices where total < 0 or tax_total < 0
order by invoice_date;

\echo '--- 6. Customers / suppliers whose balance is negative because a refund was never reflected'
select organization_id, customer_id as party_id, 'customer' as kind, balance from customer_balances where balance < 0 and total_refunded = 0 and total_returned > 0
union all
select organization_id, supplier_id, 'supplier', balance from supplier_balances where balance < 0 and total_refunded = 0 and total_returned > 0;
