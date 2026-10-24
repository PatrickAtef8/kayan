#!/usr/bin/env bash
# Proves migration 0053 is safe on a database that already holds LEGACY invoices:
# numberless invoices, hand-typed duplicate numbers, notifications showing an id fragment as the "number".
#   PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres bash supabase/tests/upgrade_0053_check.sh
# Builds a scratch DB at migration 0052, loads the legacy data, applies 0053 and checks that nothing was lost,
# only blank numbers were filled, duplicates were left alone, links/notifications were repaired and ids never changed.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${KAYAN_TEST_DB:-kayan_upgrade_0053_test}"
case "$DB" in *test*|*scratch*|*tmp*) ;; *) echo "bad db name" >&2; exit 2 ;; esac
run() { psql -q -v ON_ERROR_STOP=1 -X -o /dev/null -d "$DB" -f "$1"; }
psql -q -v ON_ERROR_STOP=1 -d postgres -c "drop database if exists \"$DB\"" -c "create database \"$DB\""
run supabase/tests/00_supabase_stub.sql
for f in $(ls supabase/migrations/*.sql | sort | grep -v 0053_); do run "$f"; done
run supabase/tests/01_helpers.sql

# ---- legacy data, created the way the old code created it (through the real RPCs, number left empty) ----
psql -q -v ON_ERROR_STOP=1 -X -o /dev/null -d "$DB" <<'SQL'
select t.autoconfirm_off();
insert into auth.users (id, email) values ('10953000-0000-0000-0000-000000000001', 'o@up.test'), ('10953000-0000-0000-0000-000000000003', 'k@up.test'), ('10953000-0000-0000-0000-000000000005', 'r@up.test');
select t.as_user('10953000-0000-0000-0000-000000000001');
select create_organization('legacy', 'x', 'EG', 'EGP', 'ar', array['products','warehouses','customers','suppliers','sales','purchases','inventory','representatives']) as id \gset org_
select t.as_owner();
insert into organization_users (organization_id, user_id, role_id, status) select :'org_id', u.id, r.id, 'active' from (values ('10953000-0000-0000-0000-000000000003'::uuid,'warehouse'),('10953000-0000-0000-0000-000000000005','sales')) u(id,k) join roles r on r.key=u.k and r.organization_id is null;
select t.as_user('10953000-0000-0000-0000-000000000001');
insert into warehouses (organization_id, name) values (:'org_id','W') returning id as w \gset
insert into suppliers (organization_id, name) values (:'org_id','S') returning id as s \gset
insert into products (organization_id, name, unit) values (:'org_id','P','u') returning id as p \gset
insert into product_prices (organization_id, product_id, selling_price) values (:'org_id', :'p', 20);
insert into product_costs (product_id, cost) values (:'p', 8);
insert into sales_representatives (organization_id, name, user_id, commission_basis, commission_rate) values (:'org_id','R','10953000-0000-0000-0000-000000000005','net_sales',5) returning id as rep \gset
insert into customers (organization_id, name, sales_rep_id) values (:'org_id','C', :'rep') returning id as c \gset
select t.as_owner(); select t.autoconfirm_on(); select t.as_user('10953000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'s', :'w', 'STOCK-1', '2026-01-01', jsonb_build_array(jsonb_build_object('product_id',:'p','quantity',500,'unit_cost',8,'discount',0)),0,0,0,'cash',null);
select t.as_owner(); select t.autoconfirm_off();
select t.as_user('10953000-0000-0000-0000-000000000005');
select create_sales_invoice(:'org_id', :'c', :'w', '',  '2026-02-01', jsonb_build_array(jsonb_build_object('product_id',:'p','quantity',2,'unit_price',20,'discount',0)),0,0,0,'cash',null,null);
select create_sales_invoice(:'org_id', :'c', :'w', 'DUP', '2026-02-02', jsonb_build_array(jsonb_build_object('product_id',:'p','quantity',2,'unit_price',20,'discount',0)),0,0,0,'cash',null,null);
select create_sales_invoice(:'org_id', :'c', :'w', 'DUP', '2026-02-03', jsonb_build_array(jsonb_build_object('product_id',:'p','quantity',2,'unit_price',20,'discount',0)),0,0,0,'cash',null,null);  -- legacy duplicate typed number
select create_sales_invoice(:'org_id', :'c', :'w', '',  '2026-02-04', jsonb_build_array(jsonb_build_object('product_id',:'p','quantity',2,'unit_price',20,'discount',0)),0,0,0,'cash',null,null);
select t.as_user('10953000-0000-0000-0000-000000000001');
select create_purchase_invoice(:'org_id', :'s', :'w', '', '2026-02-05', jsonb_build_array(jsonb_build_object('product_id',:'p','quantity',5,'unit_cost',8,'discount',0)),0,0,0,'cash',null);
select t.as_owner();
-- snapshot of everything that must not change
create table public.snap_before as
  select 'sales'::text k, id, invoice_number, total::numeric, customer_id, dispatch_status::text st from sales_invoices
  union all select 'purchase', id, invoice_number, total::numeric, supplier_id, receipt_status::text from purchase_invoices;
create table public.snap_counts as select
  (select count(*) from sales_invoice_items) si, (select count(*) from purchase_invoice_items) pi, (select count(*) from notifications) n,
  (select count(*) from inventory_movements) m, (select quantity from inventory_stock limit 1) stock;
SQL

# ---- apply 0053 ----
run supabase/migrations/0053_document_numbers.sql

# ---- verify ----
psql -q -v ON_ERROR_STOP=1 -X -d "$DB" <<'SQL'
select t.ok((select count(*) from sales_invoices where nullif(btrim(invoice_number),'') is null) = 0 and (select count(*) from purchase_invoices where nullif(btrim(invoice_number),'') is null) = 0, 'no invoice is left without a number');
select t.ok((select count(*) from snap_before b join (select 'sales' k, id, invoice_number, total::numeric, customer_id, dispatch_status::text st from sales_invoices union all select 'purchase', id, invoice_number, total::numeric, supplier_id, receipt_status::text from purchase_invoices) a using (k, id)) = (select count(*) from snap_before), 'every invoice id still exists (nothing deleted, nothing re-created)');
select t.ok((select count(*) from snap_before b join sales_invoices a on a.id = b.id and b.k = 'sales' where b.invoice_number is not null and a.invoice_number is distinct from b.invoice_number) = 0, 'invoices that already had a number kept it exactly');
select t.ok((select count(*) from snap_before b join sales_invoices a on a.id = b.id and b.k='sales' where a.total <> b.total or a.customer_id <> b.customer_id or a.dispatch_status::text <> b.st) = 0, 'amounts, customers and fulfilment status are untouched');
select t.eq((select count(*) from invoice_number_backfill), (select count(*) from snap_before where invoice_number is null), 'the backfill log lists exactly the invoices that had no number');
select t.eq((select count(*) from sales_invoices where invoice_number = 'DUP'), 2, 'legacy duplicate typed numbers are left exactly as they were');
select t.ok((select array_agg(invoice_number order by created_at) from sales_invoices where invoice_number like 'S-%') = array['S-000001','S-000002'], 'numberless sales invoices were numbered oldest first (S-000001, S-000002)');
select t.eq_text((select invoice_number from purchase_invoices where invoice_number like 'P-%'), 'P-000001', 'the numberless purchase invoice got P-000001');
select t.eq((select si from snap_counts), (select count(*) from sales_invoice_items), 'invoice lines untouched');
select t.eq((select m from snap_counts), (select count(*) from inventory_movements), 'stock movements untouched');
select t.eq((select stock from snap_counts), (select quantity from inventory_stock limit 1), 'stock quantity untouched');
select t.eq((select n from snap_counts), (select count(*) from notifications), 'no notification was lost or duplicated');
select t.empty($$select 1 from notifications where entity_id is not null and (title like '%' || left(entity_id::text, 8) || '%' or coalesce(payload->>'invoice_number','') = left(entity_id::text, 8))$$, 'old notifications no longer show an id fragment as the number');
select t.empty($$select 1 from notifications where entity_type in ('sales_invoice','purchase_invoice','sales','purchase') and href ~ '[?&]q='$$, 'old notification links now use the invoice id');
select t.ok((select count(*) from notifications n join sales_invoices i on i.id = n.entity_id where n.href like '%inv=' || i.id::text and n.title like '%' || i.invoice_number || '%') > 0, 'an old notification now names the real number and points at its invoice');
select t.eq((select count(*) from document_counters where organization_id = (select organization_id from sales_invoices limit 1) and kind = 'sales_invoice' and last_value = 2), 1, 'the counter continues after the backfill');
select 'UPGRADE 0053: ALL PASSED' as result;
SQL
