#!/bin/bash
# starts everything, runs the browser test, stops everything (all in one foreground command)
export PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres
pg_isready -q || { pg_ctlcluster 16 main start; sleep 4; }
cd /tmp/ui
# fresh seeded DB every run
psql -q -d postgres -c "drop database if exists kayan_ui" -c "create database kayan_ui" >/dev/null 2>&1
M=/home/claude/kayan/kayan/supabase
psql -q -v ON_ERROR_STOP=1 -X -o /dev/null -d kayan_ui -f $M/tests/00_supabase_stub.sql >/dev/null 2>&1
for f in $(ls $M/migrations/*.sql | sort); do psql -q -v ON_ERROR_STOP=1 -X -o /dev/null -d kayan_ui -f $f >/dev/null 2>&1 || echo "migration failed: $f"; done
psql -q -v ON_ERROR_STOP=1 -X -o /dev/null -d kayan_ui -f $M/tests/01_helpers.sql >/dev/null 2>&1
psql -q -X -o /dev/null -d kayan_ui -f /tmp/ui/seed.sql >/dev/null 2>&1
/tmp/pgrst/postgrest postgrest.conf > pgrst.log 2>&1 &
PG=$!
(cd /tmp/pwt && node mock.mjs > /tmp/ui/mock.log 2>&1) &
MK=$!
cd /home/claude/kayan/kayan
NEXT_PUBLIC_SUPABASE_URL=http://localhost:54321 NEXT_PUBLIC_SUPABASE_ANON_KEY=anon-test-key NEXT_TELEMETRY_DISABLED=1 NEXT_FONT_GOOGLE_MOCKED_RESPONSES=/tmp/font-mock.js npx next start -p 3100 > /tmp/ui/next.log 2>&1 &
NX=$!
sleep 9
cd /tmp/pwt && timeout 600 node ui_test.mjs
RC=$?
kill $PG $MK $NX 2>/dev/null; pkill -f "next-server" 2>/dev/null
exit $RC
