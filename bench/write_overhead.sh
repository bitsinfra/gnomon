#!/usr/bin/env bash
# Write-path cost of tracking: untracked vs PL/pgSQL row trigger vs statement trigger vs
# the C trigger, single-row UPDATE by key with pgbench, plus a bulk 1M-row-style UPDATE and
# bytes per version. Needs a server with gnomon and gnomon_c (shared_preload_libraries = gnomon_c).
#   PGHOST=... PGPORT=... ./bench/write_overhead.sh [rows] [seconds]
set -euo pipefail
ROWS=${1:-200000}; SECS=${2:-8}
DB=${DB:-gnomon_bench}
SCR=$(mktemp -d); trap 'rm -rf "$SCR"' EXIT
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null
psql -X -q -d $DB >/dev/null <<SQL
set client_min_messages = warning;
create extension gnomon; create extension gnomon_c;
create table u (id int primary key, a int not null, b int not null, c text not null);
insert into u select g, 0, g, md5(g::text) from generate_series(1, $ROWS) g;
create table r (like u including all); insert into r select * from u;
create table s (like u including all); insert into s select * from u;
create table cc (like u including all); insert into cc select * from u;
select gnomon.track('r'); select gnomon.track('s', write_mode => 'statement'); select gnomon.track('cc');
select gnomon.use_c_trigger('cc');
vacuum analyze;
SQL
# the heartbeat, as in production: it creates version partitions ahead of the writes (without
# it, writes past the last partition land in the default partition and take the slow path)
( while sleep 1; do psql -X -q -d $DB -c "select gnomon.heartbeat()" >/dev/null 2>&1 || true; done ) &
HB=$!
trap 'kill $HB 2>/dev/null; rm -rf "$SCR"' EXIT
for t in u r s cc; do printf '\\set id random(1, %s)\nupdate %s set a = a + 1 where id = :id;\n' "$ROWS" "$t" > "$SCR/$t.sql"; done
run() {
  psql -X -q -d $DB -Atc checkpoint
  local l0 l1 out tx
  l0=$(psql -X -d $DB -Atc "select pg_current_wal_lsn()")
  out=$(pgbench -n -M prepared -T "$SECS" -c "$2" -j "$2" -f "$SCR/$1.sql" $DB 2>&1)
  l1=$(psql -X -d $DB -Atc "select pg_current_wal_lsn()")
  tx=$(echo "$out" | awk '/number of transactions actually processed/ {print $NF}' | cut -d/ -f1)
  printf '%-10s clients=%-2s tps=%-10s latency_ms=%-7s wal_bytes_per_tx=%s\n' "$1" "$2" \
    "$(echo "$out" | awk '/^tps/ {print $3}')" "$(echo "$out" | awk '/latency average/ {print $4}')" \
    "$(psql -X -d $DB -Atc "select round(pg_wal_lsn_diff('$l1','$l0') / $tx)")"
}
echo "# single-row UPDATE by key, $ROWS rows, pgbench -M prepared, ${SECS}s"
for c in ${CLIENTS:-1 8}; do for t in ${TABLES:-u r s cc}; do run $t $c; done; done
echo "# bulk: one UPDATE of every row; the first also writes every row's lazy baseline, the second is steady state"
for t in ${BULK:-u r s cc}; do
  psql -X -q -d $DB -Atc checkpoint
  ms=$(psql -X -d $DB -c '\timing on' -c "update $t set b = b + 1" | awk '/Time:/ {print $2}')
  psql -X -q -d $DB -Atc checkpoint
  ms2=$(psql -X -d $DB -c '\timing on' -c "update $t set b = b + 1" | awk '/Time:/ {print $2}')
  echo "bulk $t first_ms=$ms second_ms=$ms2"
done
echo "# storage: bytes per version (heap + indexes, all partitions)"
for t in r s cc; do
  psql -X -d $DB -Atc "select '$t', round(sum(pg_total_relation_size(i.inhrelid))::numeric / (select count(*) from _gnomon.${t}__v), 1),
                       (select count(*) from _gnomon.${t}__v)
                  from pg_inherits i where i.inhparent = '_gnomon.${t}__v'::regclass"
done
