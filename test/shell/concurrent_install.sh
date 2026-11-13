#!/usr/bin/env bash
# Databases of one cluster installing gnomon at the same moment (a test runner creating a database
# per worker, say). gnomon's roles are cluster-wide, and two transactions cannot both update a
# shared catalog row ("tuple concurrently updated"), so every install must succeed whether it
# created the roles or found them being created, on a fresh cluster and on one that has them.
source "$(dirname "$0")/_cluster.sh"
P=54346
tc_init cinst $P "" "track_commit_timestamp = on"
N=8
psql -X -q -p $P -d postgres -c "select 1" >/dev/null
for round in fresh existing; do
  for i in $(seq 1 $N); do psql -X -q -p $P -d postgres -c "drop database if exists ci_$i" -c "create database ci_$i" >/dev/null 2>&1; done
  pids=()
  for i in $(seq 1 $N); do
    psql -X -q -p $P -d "ci_$i" -v ON_ERROR_STOP=1 -c "set client_min_messages = warning" -c "create extension gnomon" \
      > "$ROOT/build/tc-cinst.$i.out" 2>&1 &
    pids+=($!)
  done
  i=0
  for p in "${pids[@]}"; do
    i=$((i + 1))
    wait "$p" || { cat "$ROOT/build/tc-cinst.$i.out"; rm -f "$ROOT"/build/tc-cinst.*.out; fail "concurrent create extension ($round roles), database ci_$i"; }
  done
  rm -f "$ROOT"/build/tc-cinst.*.out
  q() { psql -X -q -At -v ON_ERROR_STOP=1 -p $P -d ci_1 "$@"; }
  [ "$(q -c "select count(*) from pg_roles where rolname in ('gnomon_reader', 'gnomon_writer', 'gnomon_merger', 'gnomon_admin', 'gnomon_reader_s')")" = 5 ] \
    || fail "roles after concurrent installs ($round)"
  [ "$(q -c "select string_agg(rolname, ',' order by rolname) from pg_roles where rolbypassrls and rolname like 'gnomon%'")" = gnomon_admin,gnomon_merger ] \
    || fail "bypassrls after concurrent installs ($round)"
  [ "$(q -c "select pg_has_role('gnomon_merger', 'gnomon_writer', 'member') and pg_has_role('gnomon_reader_s', 'gnomon_reader', 'member')")" = t ] \
    || fail "role memberships after concurrent installs ($round)"
  # every database works
  for i in $(seq 1 $N); do
    psql -X -q -At -v ON_ERROR_STOP=1 -p $P -d "ci_$i" -c "set client_min_messages = warning" \
      -c "create table a (id int primary key, v int); insert into a values (1, 1); select gnomon.track('a')" >/dev/null \
      || fail "track after concurrent installs ($round), database ci_$i"
  done
done
# with track_commit_timestamp on, blame's time is the commit time itself
psql -X -q -At -v ON_ERROR_STOP=1 -p $P -d ci_1 -c "update a set v = 2" >/dev/null
[ "$(psql -X -q -At -v ON_ERROR_STOP=1 -p $P -d ci_1 -c "select (select at from gnomon.blame('a', '{\"id\": 1}') where col = 'v') = pg_xact_commit_timestamp(((select xid from gnomon.history('a', '{\"id\": 1}') order by vkey desc limit 1)::text::int8 % 4294967296)::text::xid)")" = t ] \
  || fail "blame's time with track_commit_timestamp"
echo "concurrent installs ok"
