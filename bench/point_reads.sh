#!/usr/bin/env bash
# Point reads by key (target: branch reads within +25% and +5% per level; past reads within 5% when
# the table is unchanged): main, a branch at depth 1 and 4, and main as of a coordinate, run at the
# same time (one pgbench client each), so all four see the same machine load. Prints medians of
# ROUNDS rounds and the ratios to main. With the C module (port of a cluster that preloads it) the
# reads go through its custom scan; GNOMON_POINT=off compares with gnomon.c_point_reads = off.
#   PGHOST=... PGPORT=... bench/point_reads.sh [rows] [seconds] [rounds]
set -euo pipefail
ROWS=${1:-200000}; SECS=${2:-8}; ROUNDS=${3:-3}
DB=${DB:-gnomon_points}
SCR=$(mktemp -d)
q() { psql -X -q -At -d $DB "$@"; }
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null 2>&1
q >/dev/null <<SQL
set client_min_messages = warning;
create extension gnomon;
create table t (id int primary key, v int not null, doc jsonb, name text);
insert into t select g, g, jsonb_build_object('k', g), 'n' || g from generate_series(1, $ROWS) g;
vacuum analyze t;
select gnomon.track('t');
select gnomon.create_branch('d1');
select gnomon.create_branch('d2', 'd1');
select gnomon.create_branch('d3', 'd2');
select gnomon.create_branch('d4', 'd3');
SQL
CMOD=$(q -c "select coalesce(current_setting('gnomon.c_module', true), '')")
[ "$CMOD" = on ] && q -c "set client_min_messages = warning" -c "create extension gnomon_c" -c "select gnomon.use_c_trigger('t')" >/dev/null
# each level changes one row in a thousand
for d in 1 2 3 4; do q -c "select gnomon.use('d$d')" -c "update t set v = v + $d where id % 1000 = $d" >/dev/null; done
# the heartbeat, as in production (partitions ahead of the writes)
( while sleep 1; do psql -X -q -d $DB -c "select gnomon.heartbeat()" >/dev/null 2>&1 || true; done ) &
HB=$!
trap 'kill $HB 2>/dev/null; rm -rf "$SCR"' EXIT
c0=$(q -c "select gnomon.coordinate_text()")
printf '\\set id random(1, %s)\nselect * from t where id = :id;\n' $ROWS > $SCR/t.sql
P=${GNOMON_POINT:-on}
R="-c search_path=gnomon_r_public,public -c gnomon.c_point_reads=$P"
run() { PGOPTIONS="$1" pgbench -n -M prepared -T "$SECS" -f $SCR/t.sql $DB 2>&1 | awk '/latency average/ {print $4}' > "$2"; }
for i in $(seq $ROUNDS); do
  run "" $SCR/m.$i & p1=$!
  run "-c gnomon.branch=d1 $R" $SCR/d1.$i & p2=$!
  run "-c gnomon.branch=d4 $R" $SCR/d4.$i & p3=$!
  run "-c gnomon.as_of=$c0 $R" $SCR/p.$i & p4=$!
  wait $p1 $p2 $p3 $p4          # (not the heartbeat loop)
done
med() { cat "$@" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
m=$(med $SCR/m.*); d1=$(med $SCR/d1.*); d4=$(med $SCR/d4.*); p=$(med $SCR/p.*)
echo "# rows=$ROWS seconds=$SECS rounds=$ROUNDS C module: ${CMOD:-off} c_point_reads=$P load: $(uptime | sed 's/.*averages*: //')"
echo "latency (ms, medians, four clients at once): main $m | branch depth 1 $d1 | depth 4 $d4 | past, table unchanged $p"
awk -v m=$m -v a=$d1 -v b=$d4 -v c=$p 'BEGIN {printf "vs main: depth 1 %+.0f%%, depth 4 %+.0f%% (%+.1f%% per level), past %+.0f%%\n", (a/m-1)*100, (b/m-1)*100, (b/a-1)*100/3, (c/m-1)*100}'
