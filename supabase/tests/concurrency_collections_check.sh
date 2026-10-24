#!/usr/bin/env bash
# Real multi-session checks for customer COLLECTIONS and purchase RECEIPTS (0052).
# Sequential SQL tests cannot prove lock behaviour, so this runs several psql sessions against a scratch database:
#   1. a collection of the whole remaining balance is in flight (transaction still open) when a second one for the same
#        invoice arrives -> the second WAITS, then is refused; exactly one collection, one treasury movement, balance never exceeded;
#   2. six collections of 400 hit one 1 000 invoice at the same moment -> exactly two succeed (800), four are refused;
#   3. two storekeepers confirm the same pending purchase receipt at the same moment -> stock rises by 50 exactly once.
#
#   PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres bash supabase/tests/concurrency_collections_check.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
DB="${KAYAN_COLLECT_DB:-kayan_collect_test}"
case "$DB" in *test*|*scratch*|*tmp*) ;; *) echo "Refusing: DB name must contain 'test', 'scratch' or 'tmp'." >&2; exit 2 ;; esac
psql -q -v ON_ERROR_STOP=1 -d postgres -c "drop database if exists \"$DB\"" -c "create database \"$DB\""
run() { psql -q -v ON_ERROR_STOP=1 -X -o /dev/null -d "$DB" "$@"; }
val() { psql -q -At -X -d "$DB" -c "$1"; }
FAILS=0
# usage:  check_t "message" "<actual>" <op> "<expected>"    (the values are evaluated BEFORE the message is printed)
check_t() { local msg="$1" a="$2" op="$3" b="$4"; if [ "$a" "$op" "$b" ]; then echo "  ok   - $msg"; else echo "  FAIL - $msg"; FAILS=$((FAILS+1)); fi; }
run -f supabase/tests/00_supabase_stub.sql
for f in $(ls supabase/migrations/*.sql | sort); do run -f "$f"; done
run -f supabase/tests/01_helpers.sql
run -f supabase/tests/concurrency/collections_setup.sql
ORG=$(val "select org from t.cl_ids"); S1=$(val "select s1 from t.cl_ids"); C1=$(val "select c1 from t.cl_ids")
W1=$(val "select w1 from t.cl_ids"); PA=$(val "select pa from t.cl_ids"); P1=$(val "select p1 from t.cl_ids")
paid()  { val "select amount_paid from sales_invoices where id = '$1'"; }
colls() { val "select count(*) || '/' || coalesce(sum(amount), 0) from customer_collections where sales_invoice_id = '$1'"; }
tmov()  { val "select count(*) || '/' || coalesce(sum(m.amount), 0) from treasury_movements m join customer_collections c on c.id = m.source_id where c.sales_invoice_id = '$1'"; }
collect() { psql -q -At -X -d "$DB" -v who="$1" -v inv="$2" -v cust="$3" -v amount="$4" -v sleep="$5" -f supabase/tests/concurrency/collect.sql; }

echo "-- scenario 1: a full collection is in flight when another arrives for the same invoice (remaining 1000)"
OUT1=$(mktemp); OUT2=$(mktemp)
collect 2 "$S1" "$C1" 1000 4 >"$OUT1" 2>&1 &
P=$!
sleep 1.5
T0=$(date +%s.%N)
collect 1 "$S1" "$C1" 1000 0 >"$OUT2" 2>&1
T1=$(date +%s.%N)
wait $P
WAITED=$(echo "$T1 - $T0" | bc -l)
G1=0; grep -q "COLLECTED" "$OUT1" && G1=1
G2=0; grep -q "REFUSED" "$OUT2" && G2=1
check_t "the rep's collection committed" "$G1" = 1
check_t "the second collection of the same 1000 was refused" "$G2" = 1
check_t "it waited for the first one (${WAITED}s) instead of racing past it" "$(echo "$WAITED > 1.5" | bc -l)" = 1
check_t "exactly one collection row of 1000 (got $(colls "$S1"))" "$(colls "$S1")" = "1/1000.00"
check_t "exactly one treasury movement of 1000 (got $(tmov "$S1"))" "$(tmov "$S1")" = "1/1000.00"
check_t "amount_paid = 1000, never 2000 (got $(paid "$S1"))" "$(paid "$S1")" = "1000.00"
rm -f "$OUT1" "$OUT2"

echo "-- scenario 2: six collections of 400 at the same moment against a fresh 1000 invoice"
psql -q -At -X -o /dev/null -d "$DB" <<SQL
select t.as_user('98000000-0000-0000-0000-000000000002');
select create_sales_invoice('$ORG', '$C1', '$W1', 'CL-S2', current_date,
  jsonb_build_array(jsonb_build_object('product_id', '$PA', 'quantity', 10, 'unit_price', 100, 'discount_pct', 0)), 0, 0, 0, null, null, null, 0);
SQL
S2=$(val "select id from sales_invoices where invoice_number = 'CL-S2'")
OUTS=()
for i in 1 2 3 4 5 6; do
  O=$(mktemp); OUTS+=("$O")
  collect $(( (i % 2) + 1 )) "$S2" "$C1" 400 1 >"$O" 2>&1 &
done
wait
OKN=0; NO=0
for O in "${OUTS[@]}"; do grep -q "COLLECTED" "$O" && OKN=$((OKN+1)); grep -q "REFUSED" "$O" && NO=$((NO+1)); rm -f "$O"; done
check_t "exactly 2 of 6 succeeded (got $OKN)" "$OKN" = 2
check_t "and 4 were refused (got $NO)" "$NO" = 4
check_t "amount_paid = 800 (got $(paid "$S2"))" "$(paid "$S2")" = "800.00"
check_t "2 collection rows totalling 800 (got $(colls "$S2"))" "$(colls "$S2")" = "2/800.00"
check_t "2 treasury movements totalling 800 (got $(tmov "$S2"))" "$(tmov "$S2")" = "2/800.00"
check_t "status = partial" "$(val "select payment_status from sales_invoices where id = '$S2'")" = "partial"
check_t "remaining = 200" "$(val "select sales_invoice_remaining('$S2')")" = "200.00"

echo "-- scenario 3: two storekeepers confirm the same pending receipt (50 units) at the same moment"
BEFORE=$(val "select quantity from inventory_stock where product_id = '$PA'")
OUT1=$(mktemp); OUT2=$(mktemp)
psql -q -At -X -d "$DB" -v who=1 -v inv="$P1" -v sleep=3 -f supabase/tests/concurrency/receive.sql >"$OUT1" 2>&1 &
P=$!
sleep 1
psql -q -At -X -d "$DB" -v who=2 -v inv="$P1" -v sleep=0 -f supabase/tests/concurrency/receive.sql >"$OUT2" 2>&1
wait $P
RC=0; RF=0
for O in "$OUT1" "$OUT2"; do grep -q "RECEIVED" "$O" && RC=$((RC+1)); grep -q "REFUSED" "$O" && RF=$((RF+1)); done
check_t "one confirmation succeeded and the other was refused (ok=$RC refused=$RF)" "$RC/$RF" = "1/1"
AFTER=$(val "select quantity from inventory_stock where product_id = '$PA'")
check_t "stock rose by exactly 50 (was $BEFORE, now $AFTER)" "$(echo "$AFTER - $BEFORE" | bc -l)" = "50.000"
check_t "invoice is 'received'" "$(val "select receipt_status from purchase_invoices where id = '$P1'")" = "received"
rm -f "$OUT1" "$OUT2"

echo
if [ "$FAILS" -eq 0 ]; then echo "ALL COLLECTION / RECEIPT CONCURRENCY CHECKS PASSED"; else echo "$FAILS CHECK(S) FAILED"; exit 1; fi
