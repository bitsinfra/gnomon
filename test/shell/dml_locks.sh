#!/usr/bin/env bash
# SQL-only gap: SELECT ... FOR UPDATE on a branch returns rows but takes
# no row lock. With the C module loaded the lock must be real. This test asserts whichever applies.
source "$(dirname "$0")/_lib.sh"
q -c "create table l(id int primary key, v int); insert into l values (1, 0); select gnomon.track('l'); select gnomon.create_branch('b');" >/dev/null
cmod=$(q -c "select coalesce(current_setting('gnomon.c_module', true), '')")
( q -c "select gnomon.use('b')" -c "begin" -c "select * from l where id = 1 for update" -c "select pg_sleep(1.5)" -c "commit" >/dev/null ) &
sleep 0.5
start=$(date +%s%N)
out=$(psql -X -q -At -d "$DB" -c "select gnomon.use('b')" -c "set lock_timeout = '300ms'" -c "update l set v = 5 where id = 1" 2>&1 || true)
elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
wait
if [ "$cmod" = "on" ]; then
  echo "$out" | grep -q "lock timeout" || fail "C module: FOR UPDATE should block the writer (got: $out)"
else
  echo "$out" | grep -q "lock timeout" && fail "SQL-only mode unexpectedly took a lock"
  [ "$elapsed" -lt 1000 ] || fail "SQL-only FOR UPDATE should not block (waited ${elapsed}ms)"
fi
echo ok
