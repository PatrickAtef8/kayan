#!/usr/bin/env bash
# Upgrade test: build a database the way production looks BEFORE 0043/0044 (old roles, a custom role, live
# stock, invoices), upgrade it, and prove nothing changed that must not change:
#   members keep access (admin/accountant -> owner, custom -> mapped), stock quantities and average costs are
#   identical, every existing invoice counts as dispatched/received, balances and totals are identical.
set -euo pipefail
cd "$(dirname "$0")"
DB=kayan_upgrade_test
P="psql -X -q -v ON_ERROR_STOP=1"
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB" 2>&1 | grep -v NOTICE || true
$P -d $DB -o /dev/null -f 00_supabase_stub.sql
for f in $(ls ../migrations/*.sql | sort | grep -v "0043_\|0044_"); do $P -d $DB -o /dev/null -f "$f" 2>&1 | grep -v NOTICE || true; done

$P -d $DB <<'SQL' 2>&1 | grep -v NOTICE
\set ON_ERROR_STOP on
insert into auth.users (id, email) values
 ('a1000000-0000-0000-0000-000000000001','owner@up.test'), ('a1000000-0000-0000-0000-000000000002','admin@up.test'),
 ('a1000000-0000-0000-0000-000000000003','acct@up.test'),  ('a1000000-0000-0000-0000-000000000004','custom-fin@up.test'),
 ('a1000000-0000-0000-0000-000000000005','custom-sales@up.test'), ('a1000000-0000-0000-0000-000000000006','custom-other@up.test'),
 ('a1000000-0000-0000-0000-000000000007','rep@up.test'), ('a1000000-0000-0000-0000-000000000008','keeper@up.test');
select set_config('request.jwt.claims', json_build_object('sub','a1000000-0000-0000-0000-000000000001','role','authenticated')::text, false);
set role authenticated;
select create_organization('Upgrade Co','x','EG','EGP','ar',array['products','warehouses','customers','suppliers','sales','purchases','inventory','representatives']) as org \gset
reset role;
insert into organization_users (organization_id,user_id,role_id,status)
 select :'org', u, r.id, 'active' from (values ('a1000000-0000-0000-0000-000000000002'::uuid,'admin'),('a1000000-0000-0000-0000-000000000003','accountant'),('a1000000-0000-0000-0000-000000000007','sales'),('a1000000-0000-0000-0000-000000000008','warehouse')) v(u,k)
 join roles r on r.key=v.k and r.organization_id is null;
-- three custom roles (created the old way: directly, as the superuser)
insert into roles (organization_id,name,key,is_system) values (:'org','محاسب مخصص','custom_fin',false) returning id as cr1 \gset
insert into roles (organization_id,name,key,is_system) values (:'org','بائع مخصص','custom_sales',false) returning id as cr2 \gset
insert into roles (organization_id,name,key,is_system) values (:'org','أخرى','custom_other',false) returning id as cr3 \gset
insert into role_permissions values (:'cr1','view_financial'),(:'cr2','sales.create'),(:'cr3','view_dashboard');
insert into organization_users (organization_id,user_id,role_id,status) values (:'org','a1000000-0000-0000-0000-000000000004',:'cr1','active'),(:'org','a1000000-0000-0000-0000-000000000005',:'cr2','active'),(:'org','a1000000-0000-0000-0000-000000000006',:'cr3','active');

select set_config('request.jwt.claims', json_build_object('sub','a1000000-0000-0000-0000-000000000001','role','authenticated')::text, false);
set role authenticated;
insert into warehouses(organization_id,name) values (:'org','W') returning id as w \gset
insert into suppliers(organization_id,name) values (:'org','S') returning id as s \gset
insert into products(organization_id,name) values (:'org','P') returning id as p \gset
insert into product_prices(organization_id,product_id,selling_price) values (:'org',:'p',20);
insert into customers(organization_id,name) values (:'org','C') returning id as c \gset
select create_purchase_invoice(:'org',:'s',:'w','OLD-P1','2026-01-01',jsonb_build_array(jsonb_build_object('product_id',:'p','quantity',100,'unit_cost',8,'discount',0)),0,0,0,'نقدًا',null) as pi \gset
select create_sales_invoice(:'org',:'c',:'w','OLD-S1','2026-01-02',jsonb_build_array(jsonb_build_object('product_id',:'p','quantity',30,'unit_price',20,'discount',0)),0,0,0,'نقدًا',null,null) as si \gset
reset role;
create table up_before as select
  (select quantity from inventory_stock where product_id=:'p') qty,
  (select avg_cost from stock_costs sc join inventory_stock s on s.id=sc.stock_id where s.product_id=:'p') avg,
  (select count(*) from inventory_movements where organization_id=:'org') movements,
  (select total from sales_invoices where id=:'si') s_total, (select profit_total from sales_invoice_financials where sales_invoice_id=:'si') s_profit,
  (select total from purchase_invoices where id=:'pi') p_total,
  (select count(*) from organization_users where organization_id=:'org') members;
select :'org' as org, :'p' as p, :'si' as si, :'pi' as pi \gset
\echo seeded
SQL
ORG=$(psql -X -At -d $DB -c "select id from organizations limit 1")

for f in ../migrations/0043_*.sql ../migrations/0044_*.sql; do $P -d $DB -o /dev/null -f "$f" 2>&1 | grep -v NOTICE || true; done

FAIL=0
chk() { local got; got=$(psql -X -At -d $DB -c "$2"); if [ "$got" = "t" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got: $got)"; FAIL=1; fi; }
echo "upgrade checks:"
chk "exactly three roles remain"                  "select count(*)=3 from roles"
chk "nobody lost membership"                      "select count(*)=(select members from up_before) from organization_users where organization_id='$ORG'"
chk "no member without a role"                    "select count(*)=0 from organization_users where role_id is null"
chk "admin -> owner"                              "select r.key='owner' from organization_users ou join roles r on r.id=ou.role_id where ou.user_id='a1000000-0000-0000-0000-000000000002'"
chk "accountant -> owner"                         "select r.key='owner' from organization_users ou join roles r on r.id=ou.role_id where ou.user_id='a1000000-0000-0000-0000-000000000003'"
chk "custom with financial permission -> owner"   "select r.key='owner' from organization_users ou join roles r on r.id=ou.role_id where ou.user_id='a1000000-0000-0000-0000-000000000004'"
chk "custom with sales permission -> sales"       "select r.key='sales' from organization_users ou join roles r on r.id=ou.role_id where ou.user_id='a1000000-0000-0000-0000-000000000005'"
chk "custom with neither -> warehouse (least privilege)" "select r.key='warehouse' from organization_users ou join roles r on r.id=ou.role_id where ou.user_id='a1000000-0000-0000-0000-000000000006'"
chk "sales and warehouse members unchanged"       "select (select r.key from organization_users ou join roles r on r.id=ou.role_id where ou.user_id='a1000000-0000-0000-0000-000000000007')='sales' and (select r.key from organization_users ou join roles r on r.id=ou.role_id where ou.user_id='a1000000-0000-0000-0000-000000000008')='warehouse'"
chk "stock quantity untouched"                    "select s.quantity=b.qty from inventory_stock s, up_before b where s.organization_id='$ORG'"
chk "average cost untouched"                      "select sc.avg_cost=b.avg from stock_costs sc join inventory_stock s on s.id=sc.stock_id, up_before b where s.organization_id='$ORG'"
chk "no movement was written or removed"          "select count(*)=(select movements from up_before) from inventory_movements where organization_id='$ORG'"
chk "sales invoice total and profit identical"    "select i.total=b.s_total and f.profit_total=b.s_profit from sales_invoices i join sales_invoice_financials f on f.sales_invoice_id=i.id, up_before b where i.organization_id='$ORG'"
chk "purchase total identical"                    "select i.total=b.p_total from purchase_invoices i, up_before b where i.organization_id='$ORG'"
chk "existing sales invoice counts as dispatched" "select dispatch_status='dispatched' from sales_invoices where organization_id='$ORG'"
chk "existing purchase counts as received"       "select receipt_status='received' from purchase_invoices where organization_id='$ORG'"
chk "nothing waits for the storekeeper"           "select count(*)=0 from invoice_stock_lines"
chk "no audit noise from the upgrade"             "select count(*)=0 from audit_logs where organization_id='$ORG' and action like '%dispatch%'"
# re-running both migrations must be harmless
for f in ../migrations/0043_*.sql ../migrations/0044_*.sql; do $P -d $DB -o /dev/null -f "$f" 2>&1 | grep -v NOTICE || true; done
chk "migrations are re-runnable: stock still identical" "select s.quantity=b.qty from inventory_stock s, up_before b where s.organization_id='$ORG'"
chk "re-run keeps exactly three roles"            "select count(*)=3 from roles"
[ $FAIL -eq 0 ] && echo "UPGRADE TEST PASSED" || { echo "UPGRADE TEST FAILED"; exit 1; }
