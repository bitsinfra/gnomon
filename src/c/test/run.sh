#!/usr/bin/env bash
# Test the C module: a cluster with shared_preload_libraries = gnomon_c on port 54330, the whole
# SQL-core suite against it, then the C module's own tests (src/c/test/*.sql).
set -euo pipefail
cd "$(dirname "$0")/../../.."
ROOT=$PWD
mkdir -p build/test-out
export LC_ALL=${LC_ALL:-en_US.UTF-8}
# GNOMON_SKIP_BUILD=1: the extension and module are already installed in the server
# (tools/matrix.sh does that for other major versions); C_PGDATA picks the data directory
if [ -z "${GNOMON_SKIP_BUILD:-}" ]; then
  make -s dev >/dev/null
  make -s -C src/c dev >/dev/null
fi
export PGDATA_DIR=${C_PGDATA:-$ROOT/build/pgdata-c} PGPORT=${CPORT:-54330}
export EXTRA_CONF="shared_preload_libraries = 'gnomon_c'
gnomon.heartbeat_databases = 'gc_worker'
gnomon.heartbeat_interval = 200"
tools/devcluster.sh start >/dev/null
psql -X -q -h "$ROOT/build" -U postgres -d postgres -c "create database gc_worker" >/dev/null 2>&1 || true
tools/devcluster.sh restart >/dev/null   # pick up a rebuilt library; the worker connects at start
export PGHOST=$ROOT/build PGUSER=postgres
fail=0
if [ "${1:-}" != "c" ]; then
  echo "SQL-core suite with the C module loaded:"
  GNOMON_EXTERNAL=1 GNOMON_C=1 ./test/run.sh "${1:-}" || fail=1
fi
echo "C module tests:"
for f in src/c/test/*.sql; do
  name=$(basename "$f" .sql); db="gc_${name}"
  psql -X -q -d postgres -c "drop database if exists $db" -c "create database $db" >/dev/null 2>&1
  if psql -X -q -d "$db" -v ON_ERROR_STOP=1 -c "set client_min_messages=warning" -c "create extension gnomon" -c "create extension gnomon_c" \
       -f test/helpers.sql -f "$f" > "build/test-out/c_$name.out" 2>&1; then
    echo "  ok    c/$name"
  else
    echo "  FAIL  c/$name (see build/test-out/c_$name.out)"; grep -E "ERROR|FAILED" "build/test-out/c_$name.out" | head -5 | sed 's/^/        /'; fail=1
  fi
  [ "${KEEP_DB:-}" = "" ] && psql -X -q -d postgres -c "drop database if exists $db" >/dev/null 2>&1
done
for s in src/c/test/[!r]*.sh; do
  [ -e "$s" ] || continue
  if bash "$s" > "build/test-out/c_$(basename "$s" .sh).out" 2>&1; then echo "  ok    c/$(basename "$s")"; else echo "  FAIL  c/$(basename "$s")"; tail -5 "build/test-out/c_$(basename "$s" .sh).out"; fail=1; fi
done
exit $fail
