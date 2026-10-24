#!/usr/bin/env bash
# Real two-session concurrency checks for the stock count (جرد). Sequential SQL tests cannot prove
# lock behaviour, so this runs two psql sessions against a scratch database:
#   1. a sale is in flight (holds the stock lock) when the count is approved
#        → the approval WAITS for the sale, then refuses because the count is stale;
#   2. the approval is in flight when a sale arrives
#        → the sale WAITS for the approval, then succeeds against the adjusted stock;
#   in both cases batches == stock afterwards.
#
#   PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres bash supabase/tests/concurrency_check.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
DB="${KAYAN_CONCURRENCY_DB:-kayan_concurrency_test}"
case "$DB" in *test*|*scratch*|*tmp*) ;; *) echo "Refusing: DB name must contain 'test', 'scratch' or 'tmp'." >&2; exit 2 ;; esac
psql -q -v ON_ERROR_STOP=1 -d postgres -c "drop database if exists \"$DB\"" -c "create database \"$DB\""
run()  { psql -q -v ON_ERROR_STOP=1 -X -o /dev/null -d "$DB" "$@"; }
val()  { psql -q -At -X -d "$DB" -c "$1"; }
FAILS=0
check() { # label, shell condition result (0 = pass)
  if [ "$2" -eq 0 ]; then echo "  ok   - $1"; else echo "  FAIL - $1"; FAILS=$((FAILS+1)); fi
}
run -f supabase/tests/00_supabase_stub.sql
for f in $(ls supabase/migrations/*.sql | sort); do run -f "$f"; done
run -f supabase/tests/01_helpers.sql
run -f supabase/tests/concurrency/setup.sql
ST1=$(val "select st1 from t.cc_ids")
drift() { val "select count(*) from (select s.quantity q, coalesce((select sum(b.quantity) from stock_batches b where b.product_id=s.product_id and b.warehouse_id=s.warehouse_id),0) bq from inventory_stock s) x where abs(q-bq) > 0.0005"; }

echo "-- scenario 1: a sale is in flight when the count is approved"
SALE_OUT=$(mktemp); APPLY_OUT=$(mktemp)
psql -q -At -X -d "$DB" -v prod=pa -v qty=2 -v no=CC-S1 -v sleep=4 -f supabase/tests/concurrency/sale.sql >"$SALE_OUT" 2>&1 &
SALE_PID=$!
sleep 1.5
T0=$(date +%s.%N)
psql -q -At -X -d "$DB" -v st="$ST1" -v sleep=0 -f supabase/tests/concurrency/apply.sql >"$APPLY_OUT" 2>&1
T1=$(date +%s.%N)
wait $SALE_PID
WAITED=$(echo "$T1 - $T0" | bc -l)
grep -q "تغيّر المخزون بعد بدء الجرد" "$APPLY_OUT"; check "the approval was refused as stale" $?
[ "$(echo "$WAITED > 1.5" | bc -l)" -eq 1 ]; check "the approval waited for the in-flight sale (${WAITED}s)" $?
grep -q "^t$" "$SALE_OUT"; check "the sale itself committed" $?
[ "$(val "select status from stocktakes where id='$ST1'")" = "counting" ]; check "the count is still open (nothing applied)" $?
[ "$(val "select sum(quantity) from inventory_stock s join t.cc_ids c on c.pa = s.product_id")" = "18.000" ]; check "A stock reflects only the sale (20 − 2)" $?
[ "$(drift)" = "0" ]; check "batches == stock" $?
# reconcile + recount + approve now works
psql -q -At -X -o /dev/null -d "$DB" <<SQL
select t.as_user('98000000-0000-0000-0000-000000000001');
select reconcile_stocktake((select org from t.cc_ids), '$ST1');
select save_stocktake_counts((select org from t.cc_ids), '$ST1', (select jsonb_agg(jsonb_build_object('line_id', l.id, 'counted_qty', case when l.product_id = c.pa then 18 else 9 end)) from stocktake_lines l, t.cc_ids c where l.stocktake_id = '$ST1'));
select apply_stocktake((select org from t.cc_ids), '$ST1');
SQL
[ "$(val "select status from stocktakes where id='$ST1'")" = "applied" ]; check "after reconcile + recount the approval succeeds" $?
[ "$(val "select sum(quantity) from inventory_stock s join t.cc_ids c on c.pb = s.product_id")" = "9.000" ]; check "B shortage of 1 applied (10 → 9)" $?
[ "$(drift)" = "0" ]; check "batches == stock after approval" $?

echo "-- scenario 2: the approval is in flight when a sale arrives"
ST2=$(psql -q -At -X -d "$DB" <<SQL | tail -1
select t.as_user('98000000-0000-0000-0000-000000000001');
select start_stocktake((select org from t.cc_ids), (select w1 from t.cc_ids));
SQL
)
psql -q -At -X -o /dev/null -d "$DB" <<SQL
select t.as_user('98000000-0000-0000-0000-000000000001');
select save_stocktake_counts((select org from t.cc_ids), '$ST2', (select jsonb_agg(jsonb_build_object('line_id', l.id, 'counted_qty', case when l.product_id = c.pa then 17 else 9 end)) from stocktake_lines l, t.cc_ids c where l.stocktake_id = '$ST2'));
SQL
APPLY_OUT=$(mktemp); SALE_OUT=$(mktemp)
psql -q -At -X -d "$DB" -v st="$ST2" -v sleep=4 -f supabase/tests/concurrency/apply.sql >"$APPLY_OUT" 2>&1 &
APPLY_PID=$!
sleep 1.5
T0=$(date +%s.%N)
psql -q -At -X -d "$DB" -v prod=pa -v qty=1 -v no=CC-S2 -v sleep=0 -f supabase/tests/concurrency/sale.sql >"$SALE_OUT" 2>&1
T1=$(date +%s.%N)
wait $APPLY_PID
WAITED=$(echo "$T1 - $T0" | bc -l)
grep -q "^1$" "$APPLY_OUT"; check "the approval applied its 1 adjustment" $?
[ "$(echo "$WAITED > 1.5" | bc -l)" -eq 1 ]; check "the sale waited for the approval (${WAITED}s)" $?
grep -q "^t$" "$SALE_OUT"; check "the sale then succeeded" $?
[ "$(val "select sum(quantity) from inventory_stock s join t.cc_ids c on c.pa = s.product_id")" = "16.000" ]; check "A = counted 17 − 1 sold = 16" $?
[ "$(val "select status from stocktakes where id='$ST2'")" = "applied" ]; check "the count is applied" $?
[ "$(drift)" = "0" ]; check "batches == stock after both" $?

rm -f "$SALE_OUT" "$APPLY_OUT"
if [ "$FAILS" -eq 0 ]; then echo "CONCURRENCY CHECK PASSED"; else echo "CONCURRENCY CHECK FAILED ($FAILS)"; exit 1; fi
