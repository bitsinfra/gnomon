#!/usr/bin/env bash
# Single-row write overhead: UPDATE by key, untracked vs the PL/pgSQL row trigger vs the C
# trigger, interleaved; the best tps of ROUNDS runs of SECS seconds each, at 1 and 8 clients; then
# the best of ROUNDS bulk UPDATEs of every row, WAL bytes per write and storage per version. Needs
# gnomon_c preloaded.
#   PGHOST=... bench/write_best.sh <port> [rounds] [secs]
set -uo pipefail
P=$1; R=${2:-3}; S=${3:-5}; DB=${DB:-gnomon_write_best}
export PGPORT=$P
q() { psql -X -q -At -d $DB "$@"; }
SCR=$(mktemp -d)
psql -X -q -d postgres -c "drop database if exists $DB with (force)" -c "create database $DB" >/dev/null 2>&1
q >/dev/null <<SQL
set client_min_messages = warning;
create extension gnomon; create extension gnomon_c;
create table u (id int primary key, a int not null, b int not null, c text not null);
insert into u select g, 0, g, md5(g::text) from generate_series(1, 200000) g;
create table r (like u including all); insert into r select * from u;
create table cc (like u including all); insert into cc select * from u;
select gnomon.track('r'); select gnomon.track('cc'); select gnomon.use_c_trigger('cc');
select gnomon.use_c_trigger('r', false);
update r set a = 1; update cc set a = 1;   -- baselines written: the steady state
vacuum analyze;
SQL
( while sleep 1; do psql -X -q -d $DB -c "select gnomon.heartbeat()" >/dev/null 2>&1 || true; done ) &
HB=$!; trap 'kill $HB 2>/dev/null; rm -rf "$SCR"' EXIT
# one UPDATE of every row, steady state, best of R (interleaved)
bu=; br=; bc=
for i in $(seq $R); do
  for t in u r cc; do
    q -c "vacuum $t" >/dev/null
    v=$(psql -X -d $DB -c '\timing on' -c "update $t set b = b + 1" | awk '/Time:/ {printf "%d", $2}')
    case $t in u) [ -z "$bu" ] || [ $v -lt $bu ] && bu=$v;; r) [ -z "$br" ] || [ $v -lt $br ] && br=$v;; cc) [ -z "$bc" ] || [ $v -lt $bc ] && bc=$v;; esac
  done
done
echo "bulk UPDATE of every row, best ms: untracked $bu | row trigger $br | C trigger $bc"
for t in u r cc; do printf '\\set id random(1, 200000)\nupdate %s set a = a + 1 where id = :id;\n' $t > $SCR/$t.sql; done
for c in 1 8; do
  bu=0; br=0; bc=0
  for i in $(seq $R); do
    for t in u r cc; do
      v=$(pgbench -n -M prepared -T $S -c $c -j $c -f $SCR/$t.sql $DB 2>&1 | awk '/^tps/ {printf "%d", $3}')
      case $t in u) [ $v -gt $bu ] && bu=$v;; r) [ $v -gt $br ] && br=$v;; cc) [ $v -gt $bc ] && bc=$v;; esac
    done
  done
  echo "clients=$c best tps: untracked $bu | row trigger $br ($((100 * br / bu))%) | C trigger $bc ($((100 * bc / bu))%)"
done
for t in u r cc; do
  l0=$(q -c "select pg_current_wal_lsn()"); out=$(pgbench -n -M prepared -T 3 -f $SCR/$t.sql $DB 2>&1); l1=$(q -c "select pg_current_wal_lsn()")
  tx=$(echo "$out" | awk '/number of transactions actually processed/ {print $NF}' | cut -d/ -f1)
  echo "wal bytes per write, $t: $(q -c "select round(pg_wal_lsn_diff('$l1','$l0') / $tx)")"
done
for t in r cc; do
  echo "storage, $t: $(q -c "select round(sum(pg_total_relation_size(i.inhrelid))::numeric / (select count(*) from _gnomon.${t}__v), 1) || ' bytes per version over ' || (select count(*) from _gnomon.${t}__v) || ' versions, ' || (select count(*) from _gnomon.${t}__v where gn_flags & 16 <> 0) || ' of them carried forward' from pg_inherits i where i.inhparent = '_gnomon.${t}__v'::regclass")"
done
echo "load $(uptime | sed 's/.*averages*: //')"
