#!/usr/bin/env bash
# The feed's three ways of rebuilding row images on one window, interleaved in one database
# (compare within a run: absolute numbers move with machine load). Needs a server with
# the C module (src/c/test/run.sh leaves one on port 54330).
#   PGHOST=... PGPORT=54330 ./bench/feed_c.sh [rows] [updates] [rounds]
set -euo pipefail
ROWS=${1:-100000}; UPD=${2:-300000}; ROUNDS=${3:-3}
DB=${DB:-gnomon_feed_c}
q() { psql -X -q -At -d $DB "$@"; }
ms() { psql -X -q -d $DB -c '\timing on' "$@" | awk '/^Time:/ {print $2}' | tail -1; }
echo "load: $(uptime | sed 's/.*load averages*: //')"
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null
q >/dev/null <<SQL
set client_min_messages = warning;
create extension gnomon; create extension gnomon_c;
create table ev (id int primary key, a int not null, b text, c jsonb);
insert into ev select g, g, 'b' || g, jsonb_build_object('g', g) from generate_series(1, $ROWS) g;
select gnomon.track('ev');
SQL
c1=$(q -c "select gnomon.coord_text(track_coord) from gnomon.tracked where relname = 'ev'")
# updates in batches of 10,000 rows per transaction, with ticks between (partitions roll over)
for i in $(seq 1 $((UPD / 10000))); do
  q -c "update ev set a = a + 1, b = case when id % 3 = 0 then b || 'x' else b end where id in (select 1 + (g * 7919 + $i * 104729) % $ROWS from generate_series(1, 10000) g)" -c "select gnomon.heartbeat()" >/dev/null
done
q -c "vacuum analyze" >/dev/null
n=$(q -c "select count(*) from gnomon.changes('$c1', null, null, false)")
echo "window: $n versions"
run() { # run <label> <settings...>: the feed with both images, then the new image only
  local label=$1; shift
  local set=""
  for s in "$@"; do set="$set select gnomon.set(${s});"; done
  local b nn
  b=$(ms -c "$set" -c "select count(*) from gnomon.changes('$c1', null, null, 'both')")
  nn=$(ms -c "$set" -c "select count(*) from gnomon.changes('$c1', null, null, 'new')")
  printf '%-28s both %8.0f ms %9.0f rows/s   new %8.0f ms %9.0f rows/s\n' "$label" "$b" "$(awk -v n=$n -v m=$b 'BEGIN {print n / (m / 1000)}')" \
    "$nn" "$(awk -v n=$n -v m=$nn 'BEGIN {print n / (m / 1000)}')"
}
for r in $(seq 1 $ROUNDS); do
  run "probes" "'feed_setbased_min', '0'"
  run "SQL set-based" "'feed_setbased_min', '1'" "'feed_c', 'off'"
  run "C arm" "'feed_setbased_min', '1'" "'feed_c', 'on'"
done
echo "load: $(uptime | sed 's/.*load averages*: //')"
