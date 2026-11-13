#!/usr/bin/env bash
# Concurrent updates of one row on one branch: the second writer gets SQLSTATE 40001.
source "$(dirname "$0")/_lib.sh"
q -c "create table c(id int primary key, v int); insert into c values (1, 0); select gnomon.track('c'); select gnomon.create_branch('b');" >/dev/null
# session A updates and holds its transaction open
( q -c "select gnomon.use('b')" -c "begin" -c "update c set v = 1 where id = 1" -c "select pg_sleep(1.5)" -c "commit" >/dev/null ) &
sleep 0.5
out=$(psql -X -q -At -d "$DB" -c "select gnomon.use('b')" -c "update c set v = 2 where id = 1" 2>&1 || true)
wait
echo "$out" | grep -q "could not serialize access" || fail "expected 40001 for the second writer, got: $out"
[ "$(q -c "select gnomon.use('b')" -c "select v from c where id = 1" | tail -1)" = "1" ] || fail "first writer's value should win"
# a retry after the conflict succeeds
q -c "select gnomon.use('b')" -c "update c set v = 3 where id = 1" >/dev/null
[ "$(q -c "select gnomon.use('b')" -c "select v from c where id = 1" | tail -1)" = "3" ] || fail "retry should succeed"
# writers on different branches never block each other
q -c "select gnomon.create_branch('b2')" >/dev/null
( q -c "select gnomon.use('b')" -c "begin" -c "update c set v = 10 where id = 1" -c "select pg_sleep(1)" -c "commit" >/dev/null ) &
sleep 0.3
start=$(date +%s%N)
q -c "select gnomon.use('b2')" -c "update c set v = 20 where id = 1" >/dev/null
elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
wait
[ "$elapsed" -lt 700 ] || fail "a write on another branch waited ${elapsed}ms"
# main writes are untouched by branch writers
[ "$(q -c "select v from c where id = 1")" = "0" ] || fail "main changed"
# a scratch branch a session is still using is not swept, however it was chosen and however long
# ago its last gnomon.use() was; once the session ends it is
q -c "select gnomon.create_branch('s1', null, 'scratch')" >/dev/null
( psql -X -q -At -d "$DB" -c "set gnomon.branch = 's1'" -c "set search_path = gnomon_r_public__s, public" \
       -c "select count(*) from c" -c "select pg_sleep(2)" >/dev/null ) &
sleep 0.7
q -c "update gnomon.branch set last_used = now() - interval '1 day' where name = 's1'" >/dev/null
[ "$(q -c "select gnomon.sweep_scratch()")" = 0 ] || fail "a scratch branch in use was swept"
wait
[ "$(q -c "select gnomon.sweep_scratch()")" = 1 ] || fail "an abandoned scratch branch was not swept"
# ticks: a transaction running at a tick that commits after it makes a tick due, even with
# no new xid since; an idle heartbeat writes nothing (it takes no xid, so it causes no tick)
( q -c "begin" -c "update c set v = 99 where id = 1" -c "select pg_sleep(1.2)" -c "commit" >/dev/null ) &
sleep 0.4
q -c "select gnomon._do_tick(true)" >/dev/null
wait
[ "$(q -c "select gnomon._tick_due()")" = t ] || fail "a commit after a tick of a transaction running at it should make a tick due"
idle=0
for i in $(seq 1 20); do   # (other sessions on the server take xids too: wait for a quiet moment)
  q -c "select gnomon.heartbeat()" >/dev/null
  n0=$(q -c "select count(*) from gnomon.tick")
  q -c "select gnomon.heartbeat()" -c "select gnomon.heartbeat()" >/dev/null
  [ "$(q -c "select count(*) from gnomon.tick")" = "$n0" ] && { idle=1; break; }
  sleep 0.2
done
[ $idle = 1 ] || fail "an idle heartbeat kept writing ticks"
echo ok
