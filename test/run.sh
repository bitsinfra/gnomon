#!/usr/bin/env bash
# Gnomon test runner. Each test/sql/*.sql runs in a fresh database with the extension
# installed and test/helpers.sql loaded; a test fails on the first error (ON_ERROR_STOP).
#   ./test/run.sh                 run everything against the dev cluster (build/pgdata)
#   ./test/run.sh 03_merge        run matching tests
#   PGPORT=... PGHOST=... ./test/run.sh   use another server (extension must be installed)
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
export LC_ALL=${LC_ALL:-en_US.UTF-8}
export PGHOST=${PGHOST:-$ROOT/build} PGPORT=${PGPORT:-54329} PGUSER=${PGUSER:-postgres}
if [ "${GNOMON_EXTERNAL:-}" = "" ] && [ "$PGHOST" = "$ROOT/build" ]; then
  ./tools/devcluster.sh start >/dev/null
fi
filter=${1:-}
pass=0; fail=0; failed=()
mkdir -p build/test-out
for f in test/sql/*.sql; do
  name=$(basename "$f" .sql)
  [[ -n "$filter" && "$name" != *"$filter"* ]] && continue
  db="gt_${name//[^a-zA-Z0-9]/_}"
  psql -X -q -d postgres -c "drop database if exists $db" -c "create database $db" >/dev/null 2>&1
  start=$(date +%s)
  install=(-c "create extension gnomon")
  # GNOMON_C=1: the C module too (its functions take over gnomon's read context and watermarks)
  [ -n "${GNOMON_C:-}" ] && install+=(-c "create extension gnomon_c")
  # GNOMON_PLAIN=1: install with the plain-SQL form (servers where the extension files are not installed)
  [ -n "${GNOMON_PLAIN:-}" ] && install=(-f "build/dist/gnomon-plain--$(sed -n "s/^default_version = '\(.*\)'/\1/p" gnomon.control).sql")
  if psql -X -q -d "$db" -v ON_ERROR_STOP=1 -c "set client_min_messages=warning" "${install[@]}" \
       -f test/helpers.sql -f "$f" > "build/test-out/$name.out" 2>&1; then
    printf '  ok    %-28s %3ss\n' "$name" "$(( $(date +%s) - start ))"; pass=$((pass+1))
  else
    printf '  FAIL  %-28s (see build/test-out/%s.out)\n' "$name" "$name"; fail=$((fail+1)); failed+=("$name")
    grep -E "ERROR|FAILED" "build/test-out/$name.out" | head -5 | sed 's/^/        /'
  fi
  [ "${KEEP_DB:-}" = "" ] && psql -X -q -d postgres -c "drop database if exists $db" >/dev/null 2>&1
done
for s in test/shell/[!_]*.sh; do
  [ -e "$s" ] || continue
  name=$(basename "$s" .sh)
  [[ -n "$filter" && "$name" != *"$filter"* ]] && continue
  start=$(date +%s)
  if bash "$s" > "build/test-out/$name.out" 2>&1; then
    printf '  ok    %-28s %3ss\n' "$name" "$(( $(date +%s) - start ))"; pass=$((pass+1))
  else
    printf '  FAIL  %-28s (see build/test-out/%s.out)\n' "$name" "$name"; fail=$((fail+1)); failed+=("$name")
    tail -5 "build/test-out/$name.out" | sed 's/^/        /'
  fi
done
echo "passed: $pass  failed: $fail"
[ $fail -eq 0 ]
