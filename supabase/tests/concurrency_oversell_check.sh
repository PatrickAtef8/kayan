#!/usr/bin/env bash
# Real multi-session concurrency checks for selling the SAME units to more than one customer (0045).
# Sequential SQL tests cannot prove lock behaviour, so this runs several psql sessions against a scratch database:
#   1. rep 1 has a sale in flight (70 of 100, transaction still open) when rep 2 tries to sell 70
#        -> rep 2 WAITS for the stock lock, then is refused with "available now: 30"; only one invoice exists;
#   2. six reps press "save" at the same moment, 30 units each against 100 on hand
#        -> exactly three succeed, three are refused, reserved = 90, available = 10, nothing negative;
#   3. afterwards the storekeeper confirms every open order: stock and reservations end at 10 / 0 (nothing deducted twice).
#
#   PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres bash supabase/tests/concurrency_oversell_check.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
DB="${KAYAN_OVERSELL_DB:-kayan_oversell_test}"
case "$DB" in *test*|*scratch*|*tmp*) ;; *) echo "Refusing: DB name must contain 'test', 'scratch' or 'tmp'." >&2; exit 2 ;; esac
psql -q -v ON_ERROR_STOP=1 -d postgres -c "drop database if exists \"$DB\"" -c "create database \"$DB\""
run() { psql -q -v ON_ERROR_STOP=1 -X -o /dev/null -d "$DB" "$@"; }
val() { psql -q -At -X -d "$DB" -c "$1"; }
FAILS=0
check() { if [ "$2" -eq 0 ]; then echo "  ok   - $1"; else echo "  FAIL - $1"; FAILS=$((FAILS+1)); fi; }
run -f supabase/tests/00_supabase_stub.sql
for f in $(ls supabase/migrations/*.sql | sort); do run -f "$f"; done
run -f supabase/tests/01_helpers.sql
run -f supabase/tests/concurrency/oversell_setup.sql
ORG=$(val "select org from t.ov_ids"); PA=$(val "select pa from t.ov_ids")
reserved() { val "select coalesce(sum(ordered_units - fulfilled_units - cancelled_units), 0) from invoice_stock_lines where kind = 'sales' and product_id = '$PA'"; }

echo "-- scenario 1: a sale is in flight when another rep wants the same units"
OUT1=$(mktemp); OUT2=$(mktemp)
psql -q -At -X -d "$DB" -v who=1 -v qty=70 -v no=OV-1 -v sleep=4 -f supabase/tests/concurrency/oversell_sale.sql >"$OUT1" 2>&1 &
P1=$!
sleep 1.5
T0=$(date +%s.%N)
psql -q -At -X -d "$DB" -v who=2 -v qty=70 -v no=OV-2 -v sleep=0 -f supabase/tests/concurrency/oversell_sale.sql >"$OUT2" 2>&1
T1=$(date +%s.%N)
wait $P1
WAITED=$(echo "$T1 - $T0" | bc -l)
grep -q "SOLD" "$OUT1"; check "rep 1's sale committed" $?
grep -q "REFUSED" "$OUT2"; check "rep 2's sale of the same units was refused" $?
[ "$(echo "$WAITED > 1.5" | bc -l)" -eq 1 ]; check "rep 2 waited for rep 1's lock (${WAITED}s) instead of racing past it" $?
[ "$(val "select count(*) from sales_invoices where invoice_number in ('OV-1','OV-2')")" = "1" ]; check "exactly one of the two invoices exists" $?
[ "$(reserved)" = "70.000" ]; check "reserved = 70 (not 140)" $?
rm -f "$OUT1" "$OUT2"

echo "-- scenario 2: six reps save at the same moment (30 each, 30 already free = 30 left after scenario 1)"
# reset: dispatch what is open so the shelf is 30 and nothing is reserved, then restock to exactly 100 again
OV1=$(val "select id from sales_invoices where invoice_number = 'OV-1'")
psql -q -At -X -o /dev/null -d "$DB" <<SQL
select t.as_user('99000000-0000-0000-0000-000000000004');
select confirm_sales_dispatch((select org from t.ov_ids), '$OV1');
select t.as_owner();
select t.autoconfirm_on();
select t.as_user('99000000-0000-0000-0000-000000000001');
select create_purchase_invoice((select org from t.ov_ids), (select id from suppliers limit 1), (select w1 from t.ov_ids), 'OV-P2', current_date,
  jsonb_build_array(jsonb_build_object('product_id', (select pa from t.ov_ids), 'quantity', 70, 'unit_cost', 5, 'discount_pct', 0)), 0, 0, 0, null, null, 0);
select t.as_owner();
select t.autoconfirm_off();
SQL
[ "$(val "select quantity from inventory_stock where product_id = '$PA'")" = "100.000" ]; check "reset: 100 on hand, nothing reserved" $?
[ "$(reserved)" = "0" ] || [ "$(reserved)" = "0.000" ]; check "reset: reserved = 0" $?
OUTS=()
for i in 1 2 3 4 5 6; do
  O=$(mktemp); OUTS+=("$O")
  psql -q -At -X -d "$DB" -v who=$(( (i % 2) + 1 )) -v qty=30 -v no="OV-R$i" -v sleep=1 -f supabase/tests/concurrency/oversell_sale.sql >"$O" 2>&1 &
done
wait
SOLD=0; REFUSED=0
for O in "${OUTS[@]}"; do grep -q "SOLD" "$O" && SOLD=$((SOLD+1)); grep -q "REFUSED" "$O" && REFUSED=$((REFUSED+1)); rm -f "$O"; done
[ "$SOLD" -eq 3 ]; check "exactly 3 of 6 simultaneous sales succeeded (got $SOLD)" $?
[ "$REFUSED" -eq 3 ]; check "and 3 were refused (got $REFUSED)" $?
[ "$(reserved)" = "90.000" ]; check "reserved = 90 (3 x 30), never more than the shelf allows" $?
[ "$(val "select greatest(quantity - (select coalesce(sum(ordered_units - fulfilled_units - cancelled_units), 0) from invoice_stock_lines where kind = 'sales' and product_id = '$PA'), 0) from inventory_stock where product_id = '$PA'")" = "10.000" ]; check "10 left to sell" $?
[ "$(val "select count(*) from inventory_stock where quantity < 0")" = "0" ]; check "no negative stock" $?

echo "-- scenario 3: the storekeeper confirms everything that is open"
for ID in $(val "select id from sales_invoices where invoice_number like 'OV-R%' and dispatch_status in ('pending', 'partial')"); do
  psql -q -At -X -o /dev/null -d "$DB" -c "select t.as_user('99000000-0000-0000-0000-000000000004')" -c "select confirm_sales_dispatch('$ORG', '$ID')"
done
[ "$(val "select quantity from inventory_stock where product_id = '$PA'")" = "10.000" ]; check "on hand = 10 after dispatching 90 (nothing deducted twice)" $?
[ "$(reserved)" = "0" ] || [ "$(reserved)" = "0.000" ]; check "reserved back to 0" $?
[ "$(val "select sum(quantity_delta) from inventory_movements where product_id = '$PA'")" = "10.000" ]; check "movements net to what is on the shelf" $?

if [ "$FAILS" -eq 0 ]; then echo "OVERSELL CONCURRENCY CHECK PASSED"; else echo "OVERSELL CONCURRENCY CHECK FAILED ($FAILS)"; exit 1; fi
