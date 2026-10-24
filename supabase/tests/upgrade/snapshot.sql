-- Fingerprint of everything the batch migrations must NOT change. Called as: psql -v tag=before|after
\set ON_ERROR_STOP on
select t.as_owner();
drop table if exists t.fp_:tag;
create table t.fp_:tag as
select 'inventory_stock' as tbl, count(*) as n, md5(coalesce(string_agg(x::text, '|' order by x::text), '')) as h from inventory_stock x
union all select 'stock_costs', count(*), md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from stock_costs x
union all select 'inventory_movements', count(*), md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from inventory_movements x
-- 0040 adds sales_invoices.sales_channel (NULL on existing rows): fingerprint every OTHER column
union all select 'sales_invoices', count(*), md5(coalesce(string_agg((to_jsonb(x) - 'sales_channel')::text, '|' order by (to_jsonb(x) - 'sales_channel')::text), '')) from sales_invoices x
union all select 'sales_invoice_items', count(*), md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from sales_invoice_items x
-- 0041 adds purchase_invoices.due_date (NULL on existing rows): fingerprint every OTHER column
union all select 'purchase_invoices', count(*), md5(coalesce(string_agg((to_jsonb(x) - 'due_date')::text, '|' order by (to_jsonb(x) - 'due_date')::text), '')) from purchase_invoices x
union all select 'purchase_invoice_items', count(*), md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from purchase_invoice_items x
union all select 'sales_returns', count(*), md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from sales_returns x
union all select 'stock_transfers', count(*), md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from stock_transfers x
union all select 'expenses', count(*), md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from expenses x
union all select 'treasury_movements', count(*), md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from treasury_movements x
union all select 'treasury_accounts', count(*), md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from treasury_accounts x
union all select 'customer_collections', count(*), md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from customer_collections x
union all select 'supplier_payments', count(*), md5(coalesce(string_agg(x::text, '|' order by x::text), '')) from supplier_payments x
-- 0042 adds sales_return_items.return_reason (NULL on existing rows): fingerprint every OTHER column
union all select 'sales_return_items', count(*), md5(coalesce(string_agg((to_jsonb(x) - 'return_reason')::text, '|' order by (to_jsonb(x) - 'return_reason')::text), '')) from sales_return_items x;
