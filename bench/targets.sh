#!/usr/bin/env bash
# The performance targets, measured: reads on main, branch point reads by depth, past reads,
# diff, merge throughput, change-feed throughput, coordinate capture, branch creation, many
# open branches, tracking an existing table. Prints one line per measurement.
#   PGHOST=... PGPORT=... ./bench/targets.sh [rows] [seconds]
set -euo pipefail
ROWS=${1:-200000}; SECS=${2:-5}
DB=${DB:-gnomon_targets}
SCR=$(mktemp -d); trap 'rm -rf "$SCR"' EXIT
q() { psql -X -q -At -d $DB "$@"; }
ms() { psql -X -q -d $DB -c '\timing on' "$@" | awk '/^Time:/ {print $2}' | tail -1; }
tps() { # tps <script> [PGOPTIONS]
  PGOPTIONS="${2:-}" pgbench -n -M prepared -T "$SECS" -c "${C:-1}" -j "${C:-1}" -f "$1" $DB 2>&1 | awk '/latency average/ {l=$4} /^tps/ {t=$3} END {printf "tps=%.0f latency_ms=%s", t, l}'
}
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null 2>&1
q >/dev/null <<SQL
set client_min_messages = warning;
create extension gnomon;
create table plain (id int primary key, v int not null, doc jsonb, name text);
insert into plain select g, g, jsonb_build_object('k', g), 'n' || g from generate_series(1, $ROWS) g;
create table t (like plain including all); insert into t select * from plain;
create table big (like plain including all); insert into big select * from plain;
vacuum analyze;
SQL
# the heartbeat, as in production: it creates version partitions ahead of the writes (without
# it, writes past the last partition land in the default partition and take the slow path)
( while sleep 1; do psql -X -q -d $DB -c "select gnomon.heartbeat()" >/dev/null 2>&1 || true; done ) &
HB=$!
trap 'kill $HB 2>/dev/null; rm -rf "$SCR"' EXIT
echo "# rows=$ROWS seconds=$SECS server=$(q -c 'show server_version')"

CMOD=$(q -c "select coalesce(current_setting('gnomon.c_module', true), '')")
[ "$CMOD" = on ] && q -c "create extension gnomon_c" >/dev/null
echo "# C module: ${CMOD:-off}"
t0=$(date +%s%N); q -c "select gnomon.track('t')" >/dev/null; echo "track existing table ($ROWS rows): $(( ($(date +%s%N) - t0) / 1000000 )) ms (no backfill; lock is metadata-only)"
q -c "select gnomon.track('big')" >/dev/null
# with the module: the C trigger (and its shared-memory watermark) on both tables
[ "$CMOD" = on ] && q -c "select gnomon.use_c_trigger('t')" -c "select gnomon.use_c_trigger('big')" >/dev/null

printf '\\set id random(1, %s)\nselect * from plain where id = :id;\n' $ROWS > $SCR/plain.sql
printf '\\set id random(1, %s)\nselect * from t where id = :id;\n' $ROWS > $SCR/t.sql
printf '\\set id random(1, %s)\nselect * from t where doc @> jsonb_build_object(chr(107), (:id)::int);\n' $ROWS > $SCR/tj.sql
printf '\\set id random(1, %s)\nselect * from plain where doc @> jsonb_build_object(chr(107), (:id)::int);\n' $ROWS > $SCR/pj.sql
q -c "create index on plain using gin (doc); create index on t using gin (doc); analyze" >/dev/null
echo "current point read, untracked:      $(tps $SCR/plain.sql)"
echo "current point read, tracked (main): $(tps $SCR/t.sql)"
echo "current jsonb @> read, untracked:   $(tps $SCR/pj.sql)"
echo "current jsonb @> read, tracked:     $(tps $SCR/tj.sql)"

# branches at depth 1..4, each with some writes
q -c "select gnomon.create_branch('d1')" >/dev/null
for d in 2 3 4; do q -c "select gnomon.create_branch('d$d', 'd$((d-1))')" >/dev/null; done
for d in 1 2 3 4; do q -c "select gnomon.use('d$d')" -c "update t set v = v + $d where id % 1000 = $d" >/dev/null; done
for d in 1 2 3 4; do
  echo "branch point read, depth $d:       $(tps $SCR/t.sql "-c gnomon.branch=d$d -c search_path=gnomon_r_public,public")"
done
echo "branch jsonb @> read, depth 1:      $(tps $SCR/tj.sql "-c gnomon.branch=d1 -c search_path=gnomon_r_public,public")"

# past reads: unchanged since C, and rows changed since C
c0=$(q -c "select gnomon.coordinate_text()")
echo "past point read, table unchanged:   $(tps $SCR/t.sql "-c gnomon.as_of=$c0 -c search_path=gnomon_r_public,public")"
q -c "update t set v = v + 1 where id % 10 = 0" >/dev/null
echo "past point read, 10% rows changed:  $(tps $SCR/t.sql "-c gnomon.as_of=$c0 -c search_path=gnomon_r_public,public")"
echo "scan $ROWS rows now:                $(ms -c 'select count(*), sum(v) from t') ms"
echo "past scan, 10% changed since C:     $(ms -c "select gnomon.use('main', '$c0')" -c 'select count(*), sum(v) from t') ms"
q -c "update t set v = v + 1" >/dev/null
echo "past scan, all rows changed:        $(ms -c "select gnomon.use('main', '$c0')" -c 'select count(*), sum(v) from t') ms"

# the backlog of the writes above (ledger sealing in the heartbeat) settled first, so it does not
# run alongside the timings below
q -c "select gnomon.heartbeat()" >/dev/null
# diff with 1000 changes in a big table
q -c "select gnomon.create_branch('diffb')" >/dev/null
q -c "select gnomon.use('diffb')" -c "update big set v = -v where id <= 1000" >/dev/null
echo "diff, 1000 changed rows of $ROWS:    $(ms -c "select count(*) from gnomon.diff('diffb')") ms"

# merge throughput
q -c "select gnomon.create_branch('mb')" >/dev/null
N=$((ROWS / 4))
q -c "select gnomon.use('mb')" -c "update big set name = 'merged' where id <= $N" >/dev/null
m=$(ms -c "select gnomon.merge('mb')")
echo "merge $N updated rows:              $m ms ($(awk -v n=$N -v m=$m 'BEGIN {printf "%.0f", n / (m / 1000)}') rows/s)"

# change feed
q -c "select gnomon.heartbeat()" >/dev/null
c1=$(q -c "select gnomon.coord_text(track_coord) from gnomon.tracked where relname = 'big'")
n=$(q -c "select count(*) from gnomon.changes('$c1', null, null, false)")
f=$(ms -c "select count(*) from gnomon.changes('$c1', null, null, false)")
echo "change feed, $n versions (keys):    $f ms ($(awk -v n=$n -v m=$f 'BEGIN {printf "%.0f", n / (m / 1000)}') rows/s)"
# (the feed is ordered, so a LIMIT still builds every image: time the whole of it)
f=$(ms -c "select count(*) from gnomon.changes('$c1')")
echo "change feed with row images, $n versions: $f ms ($(awk -v n=$n -v m=$f 'BEGIN {printf "%.0f", n / (m / 1000)}') rows/s)"

# scratch (unlogged) vs logged branch writes
q -c "select gnomon.create_branch('lg')" -c "select gnomon.create_branch('sc', kind => 'scratch')" >/dev/null
printf '\\set id random(1, %s)\nupdate big set v = v + 1 where id = :id;\n' $ROWS > $SCR/bw.sql
echo "branch write, logged branch:        $(C=4 tps $SCR/bw.sql "-c gnomon.branch=lg -c search_path=gnomon_r_public,public")"
echo "branch write, scratch branch:       $(C=4 tps $SCR/bw.sql "-c gnomon.branch=sc -c search_path=gnomon_r_public__s,public")"
if [ "$(q -c "select coalesce(current_setting('gnomon.c_module', true), '')")" = on ]; then
  echo "branch point read, C module routing: $(tps $SCR/t.sql "-c gnomon.branch=d1")"
fi

# coordinates and branch creation
printf 'select gnomon.coordinate();\n' > $SCR/coord.sql
printf 'select pg_current_snapshot();\n' > $SCR/snap.sql
echo "capture coordinate:                 $(tps $SCR/coord.sql)"
echo "pg_current_snapshot (reference):    $(tps $SCR/snap.sql)"
t0=$(date +%s%N); q -c "select gnomon.create_branch('cb' || g) from generate_series(1, 200) g" >/dev/null
echo "create branch:                      $(( ($(date +%s%N) - t0) / 200000 )) us each (200 in one statement)"

# many open branches: main must not notice
printf '\\set id random(1, %s)\nupdate plain set v = v + 1 where id = :id;\n' $ROWS > $SCR/pw.sql
printf '\\set id random(1, %s)\nupdate t set v = v + 1 where id = :id;\n' $ROWS > $SCR/tw.sql
before_r=$(tps $SCR/t.sql); before_w=$(tps $SCR/tw.sql)
q -c "select gnomon.create_branch('many' || g) from generate_series(1, ${BRANCHES:-10000}) g" >/dev/null
after_r=$(tps $SCR/t.sql); after_w=$(tps $SCR/tw.sql)
echo "main point read before/after ${BRANCHES:-10000} branches:  $before_r  |  $after_r"
echo "main write before/after ${BRANCHES:-10000} branches:       $before_w  |  $after_w"
psql -X -q -d postgres -c "drop database $DB" >/dev/null 2>&1 || true
