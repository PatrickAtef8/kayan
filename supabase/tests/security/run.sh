#!/usr/bin/env bash
# Security test suite. Needs a PostgreSQL superuser (it creates a scratch database + roles).
#   PGHOST/PGPORT/PGUSER/PGPASSWORD as usual, e.g.:   PGUSER=postgres ./run.sh
# Exits non-zero if any check fails.
set -uo pipefail
cd "$(dirname "$0")"
DB="${KAYAN_TEST_DB:-kayan_security_test}"
P="psql -X -q -v ON_ERROR_STOP=1"

psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB" 2>&1 | grep -v NOTICE
$P -d "$DB" -f 00_bootstrap.sql
for f in $(ls ../../migrations/*.sql | sort); do
  $P -d "$DB" -o /dev/null -f "$f" 2>&1 | grep -v NOTICE || true
done
$P -d "$DB" -o /dev/null -f 01_helpers.sql
$P -d "$DB" -o /dev/null -f 02_seed.sql 2>&1 | grep -v NOTICE
# optional: KAYAN_SABOTAGE=file.sql deliberately breaks a protection to prove the tests can fail
[ -n "${KAYAN_SABOTAGE:-}" ] && $P -d "$DB" -o /dev/null -f "$KAYAN_SABOTAGE"
ERRS=$(mktemp)
for t in cases/*.sql; do
  psql -X -q -d "$DB" -o /dev/null -f "$t" 2>&1 | grep -v NOTICE | grep -v "^$" | sed "s|^|[$t] |" >> "$ERRS"
done

psql -X -d "$DB" -c "select suite, count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from lab.results group by suite order by min(id)"
if [ -s "$ERRS" ]; then
  echo "---- TEST SCRIPT ERRORS (a check did not run!) ----"; cat "$ERRS"; rm -f "$ERRS"; exit 2
fi
rm -f "$ERRS"
FAILS=$(psql -X -At -d "$DB" -c "select count(*) from lab.results where not ok")
TOTAL=$(psql -X -At -d "$DB" -c "select count(*) from lab.results")
if [ "$FAILS" != "0" ]; then
  echo "---- FAILED CHECKS ----"
  psql -X -At -d "$DB" -c "select '['||suite||'] '||name from lab.results where not ok order by id"
  echo "$FAILS of $TOTAL checks FAILED"; exit 1
fi
echo "All $TOTAL checks passed"
