#!/usr/bin/env bash
# Proves the batch, stock-count and sales-report migrations (0037-0042) preserve existing data:
#   1. build a scratch DB with every migration BEFORE 0037,
#   2. load realistic data using the old functions,
#   3. fingerprint stock / costs / movements / invoices / returns / transfers,
#   4. apply 0037 … 0042,
#   5. compare fingerprints (must be identical) and check batches = stock.
#
#   PGHOST=localhost PGUSER=postgres PGPASSWORD=postgres bash supabase/tests/upgrade_check.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${KAYAN_UPGRADE_DB:-kayan_upgrade_test}"
case "$DB" in *test*|*scratch*|*tmp*) ;; *) echo "Refusing: DB name must contain 'test', 'scratch' or 'tmp'." >&2; exit 2 ;; esac
psql -q -v ON_ERROR_STOP=1 -d postgres -c "drop database if exists \"$DB\"" -c "create database \"$DB\""
run() { psql -q -v ON_ERROR_STOP=1 -X -o /dev/null -d "$DB" "$@"; }
run -f supabase/tests/00_supabase_stub.sql
for f in $(ls supabase/migrations/*.sql | sort); do
  case "$(basename "$f")" in 0037_*|0038_*|0039_*|0040_*|0041_*|0042_*) continue ;; esac
  run -f "$f"
done
run -f supabase/tests/01_helpers.sql
run -f supabase/tests/upgrade/seed.sql
run -f supabase/tests/upgrade/seed_accounts.sql
run -v tag=before -f supabase/tests/upgrade/snapshot.sql
echo "applying 0037 … 0042 on populated data…"
run -f supabase/migrations/0037_expiry_batches_phase2.sql
run -f supabase/migrations/0038_batch_returns_and_disposal.sql
run -f supabase/migrations/0039_stocktake_phase3.sql
run -f supabase/migrations/0040_sales_reports_phase4.sql
run -f supabase/migrations/0041_partner_reports_phase5.sql
run -f supabase/migrations/0042_accounting_reports_phase6.sql
run -v tag=after -f supabase/tests/upgrade/snapshot.sql
run -f supabase/tests/upgrade/check.sql
echo "UPGRADE CHECK PASSED"
