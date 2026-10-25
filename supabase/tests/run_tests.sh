#!/usr/bin/env bash
# Runs the schema tests against a throwaway local PostgreSQL database.
# Usage: supabase/tests/run_tests.sh   (needs psql and a local PostgreSQL 15+)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DB="${TEST_DB:-rpm_test}"
PSQL=(psql -X -q -v ON_ERROR_STOP=1)

# Local root shell with a system PostgreSQL: run as the postgres OS user.
# Otherwise (e.g. CI with PGHOST/PGUSER/PGPASSWORD set) run directly.
if [ -z "${PGHOST:-}" ] && [ "$(id -un)" = "root" ] && id postgres >/dev/null 2>&1; then
  run() { su postgres -c "$(printf '%q ' "$@")"; }
else
  run() { "$@"; }
fi

run dropdb --if-exists "$DB"
run createdb "$DB"

run "${PSQL[@]}" -d "$DB" -f "$HERE/00_supabase_stub.sql"
for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "applying $(basename "$f")"
  run "${PSQL[@]}" -d "$DB" -f "$f"
done
run "${PSQL[@]}" -d "$DB" -f "$HERE/10_tests.sql"
