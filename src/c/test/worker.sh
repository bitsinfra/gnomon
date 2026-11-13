#!/usr/bin/env bash
# The background worker ticks gc_worker every 200 ms.
set -euo pipefail
psql -X -q -d gc_worker -c "set client_min_messages=warning" -c "drop extension if exists gnomon cascade" -c "drop table if exists w" \
  -c "create extension gnomon" -c "create table w(id int primary key); select gnomon.track('w')" >/dev/null
for i in 1 2 3 4 5; do psql -X -q -d gc_worker -c "insert into w values ($i)" >/dev/null; sleep 0.3; done
n=$(psql -X -At -d gc_worker -c "select count(*) from gnomon.tick")
[ "$n" -ge 3 ] || { echo "FAILED: expected ticks from the worker, got $n"; exit 1; }
echo "ok: $n ticks"
