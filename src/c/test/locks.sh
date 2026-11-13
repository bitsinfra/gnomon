#!/usr/bin/env bash
# With the C module, SELECT ... FOR UPDATE on a branch blocks a concurrent writer of that row.
set -euo pipefail
DB=gc_locks
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null 2>&1
psql -X -q -d $DB -c "set client_min_messages=warning" -c "create extension gnomon" \
  -c "create table l(id int primary key, v int); insert into l values (1, 0); select gnomon.track('l'); select gnomon.create_branch('b')" >/dev/null
( psql -X -q -d $DB -c "set gnomon.branch = 'b'" -c "begin" -c "select * from l where id = 1 for update" -c "select pg_sleep(1.5)" -c "commit" >/dev/null ) &
sleep 0.5
out=$(psql -X -q -At -d $DB -c "set gnomon.branch = 'b'" -c "set lock_timeout = '300ms'" -c "update l set v = 5 where id = 1" 2>&1 || true)
wait
psql -X -q -d postgres -c "drop database if exists $DB" >/dev/null 2>&1
echo "$out" | grep -q "lock timeout" || { echo "FAILED: writer was not blocked: $out"; exit 1; }
echo ok
# INSERT ... ON CONFLICT on a branch from two sessions at once, the same new key: the second waits
# for the first, then takes the conflict action (as PostgreSQL's own upsert does), not an error
DB=gc_upsert
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null 2>&1
psql -X -q -d $DB -c "set client_min_messages=warning" -c "create extension gnomon" -c "create extension gnomon_c" \
  -c "create table u(id int primary key, v int, n int default 0); insert into u values (1, 0, 0); select gnomon.track('u'); select gnomon.create_branch('b')" >/dev/null
( psql -X -q -d $DB -c "set gnomon.branch = 'b'" -c "begin" -c "insert into u values (7, 1, 1) on conflict (id) do update set v = excluded.v, n = excluded.n" \
       -c "insert into u values (1, 10, 1) on conflict (id) do update set v = excluded.v" -c "select pg_sleep(1)" -c "commit" >/dev/null ) &
sleep 0.4
out=$(psql -X -q -At -d $DB -c "set gnomon.branch = 'b'" -c "insert into u values (7, 2, 2) on conflict (id) do update set v = excluded.v" \
          -c "insert into u values (1, 20, 2) on conflict (id) do update set v = excluded.v" \
          -c "insert into u values (7, 3, 3) on conflict do nothing" -c "select string_agg(id || ':' || v || ':' || n, ',' order by id) from u" 2>&1 || true)
wait
psql -X -q -d postgres -c "drop database if exists $DB" >/dev/null 2>&1
[ "$(echo "$out" | tail -1)" = "1:20:0,7:2:1" ] || { echo "FAILED: concurrent upserts on a branch: $out"; exit 1; }
echo ok
