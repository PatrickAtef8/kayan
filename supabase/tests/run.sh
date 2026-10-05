#!/usr/bin/env bash
# Runs the whole database test-suite against a throwaway database.
#
#   PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres \
#     bash supabase/tests/run.sh
#
# It (re)creates a scratch database, installs a stub of the Supabase `auth`
# schema (see 00_supabase_stub.sql), applies every migration in order, then
# runs every *_test.sql file. Any failed assertion aborts with a non-zero
# exit code, so this is what CI runs.
#
# Safety: it only ever touches the database named by KAYAN_TEST_DB
# (default: kayan_test) and refuses names that don't look like a scratch DB.
set -euo pipefail

cd "$(dirname "$0")/../.."

DB="${KAYAN_TEST_DB:-kayan_test}"
case "$DB" in
  *test*|*scratch*|*tmp*) ;;
  *) echo "Refusing to run against '$DB': the database name must contain 'test', 'scratch' or 'tmp'." >&2; exit 2 ;;
esac

psql -q -v ON_ERROR_STOP=1 -d postgres -c "drop database if exists \"$DB\"" -c "create database \"$DB\""

# -o /dev/null hides the (empty) result tables of the assertion selects; the
# "ok - ..." lines are NOTICEs on stderr and stay visible.
run() { psql -q -v ON_ERROR_STOP=1 -X -o /dev/null -d "$DB" -f "$1"; }

run supabase/tests/00_supabase_stub.sql
for f in $(ls supabase/migrations/*.sql | sort); do
  echo "migrate  $f"
  run "$f"
done
run supabase/tests/01_helpers.sql

status=0
for f in $(ls supabase/tests/[1-9][0-9]_*_test.sql 2>/dev/null | sort); do
  echo
  echo "=== $f"
  if ! run "$f"; then status=1; echo "!!! FAILED: $f"; fi
done

echo
if [ "$status" -eq 0 ]; then echo "ALL DATABASE TESTS PASSED"; else echo "DATABASE TESTS FAILED"; fi
exit "$status"
