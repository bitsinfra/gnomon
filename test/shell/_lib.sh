# Shared helpers for shell tests: a fresh database with gnomon installed.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
mkdir -p "$ROOT/build/test-out"   # (scripts run alone write their logs there too)
export PGHOST=${PGHOST:-$ROOT/build} PGPORT=${PGPORT:-54329} PGUSER=${PGUSER:-postgres} LC_ALL=${LC_ALL:-en_US.UTF-8}
DB=${DB:-gts_$(basename "$0" .sh)}
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null 2>&1
psql -X -q -d "$DB" -c "set client_min_messages=warning" -c "create extension gnomon" >/dev/null
[ -n "${GNOMON_C:-}" ] && psql -X -q -d "$DB" -c "create extension gnomon_c" >/dev/null
trap 'psql -X -q -d postgres -c "drop database if exists $DB" >/dev/null 2>&1 || true' EXIT
q() { psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
fail() { echo "FAILED: $*"; exit 1; }
