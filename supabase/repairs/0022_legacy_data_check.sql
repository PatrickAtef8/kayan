-- READ-ONLY. Run after applying 0022 to see which HISTORICAL rows were created
-- under the old rules. 0022 deliberately does not rewrite past invoices: their
-- totals are what the customer/supplier was actually billed, and changing them
-- would silently move balances. Review these rows and decide case by case.
--
--   psql "$DATABASE_URL" -f supabase/repairs/0022_legacy_data_check.sql

\echo '--- 1. Sales invoices whose total ignored a per-line discount (old bug #1)'
select i.organization_id, i.invoice_number, i.invoice_date, i.total as billed_total,
       round(i.subtotal - sum(it.line_total) - i.line_discount_total, 2) as line_discounts_not_applied
from sales_invoices i
join sales_invoice_items it on it.sales_invoice_id = i.id
group by i.id
having abs(i.subtotal - sum(it.line_total) - i.line_discount_total) > 0.005
order by i.invoice_date;

\echo '--- 2. Purchase invoices whose total ignored a per-line discount (old bug #1)'
select i.organization_id, i.invoice_number, i.invoice_date, i.total as billed_total,
       round(i.subtotal - sum(it.line_total) - i.line_discount_total, 2) as line_discounts_not_applied
from purchase_invoices i
join purchase_invoice_items it on it.purchase_invoice_id = i.id
group by i.id
having abs(i.subtotal - sum(it.line_total) - i.line_discount_total) > 0.005
order by i.invoice_date;

\echo '--- 3. Stock rows that are negative (old bug #6: oversold, sold at cost 0)'
select s.organization_id, p.name as product, w.name as warehouse, s.quantity, s.avg_cost
from inventory_stock s
join products p on p.id = s.product_id
join warehouses w on w.id = s.warehouse_id
where s.quantity < 0
order by s.quantity;

\echo '--- 4. Invoices paid beyond their total (old bug #7)'
select organization_id, invoice_number, total, amount_paid, round(amount_paid - total, 2) as overpaid
from sales_invoices where amount_paid > total + 0.005
union all
select organization_id, invoice_number, total, amount_paid, round(amount_paid - total, 2)
from purchase_invoices where amount_paid > total + 0.005
order by 1;

\echo '--- 5. Sales invoices with a negative total or a discount above the subtotal (old bug #7)'
select organization_id, invoice_number, subtotal, discount_total, tax_total, total
from sales_invoices where total < 0 or discount_total > subtotal
order by invoice_date;

\echo '--- 6. Returns made before 0022 on invoices that carried invoice-level discount or tax (old bug #2)'
select r.organization_id, i.invoice_number, r.return_date, r.total as credited,
       (i.discount_total - i.line_discount_total) as invoice_discount, i.tax_total
from sales_returns r
join sales_invoices i on i.id = r.sales_invoice_id
where r.tax_reversed = 0 and (i.discount_total - i.line_discount_total > 0 or i.tax_total > 0)
order by r.return_date;
