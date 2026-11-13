#!/usr/bin/env bash
# Many open branches have no effect on main. Measures main's point reads
# and single-row writes on a tracked table, creates N branches (some with writes), and measures
# again; also branch creation time and catalog size.
#   PGHOST=... PGPORT=... bench/soak_branches.sh [branches] [seconds]
set -euo pipefail
N=${1:-100000}; SECS=${2:-5}
DB=${DB:-gnomon_soak}
SCR=$(mktemp -d); trap 'rm -rf "$SCR"' EXIT
q() { psql -X -q -At -d $DB "$@"; }
tps() { pgbench -n -M prepared -T "$SECS" -c "${C:-4}" -j "${C:-4}" -f "$1" $DB 2>&1 | awk '/latency average/ {l=$4} /^tps/ {t=$3} END {printf "tps=%.0f latency_ms=%s", t, l}'; }
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null 2>&1
q >/dev/null <<SQL
set client_min_messages = warning;
create extension gnomon;
create table t (id int primary key, v int not null);
insert into t select g, g from generate_series(1, 200000) g;
vacuum analyze t;
select gnomon.track('t');
SQL
printf '\\set id random(1, 200000)\nselect * from t where id = :id;\n' > $SCR/r.sql
printf '\\set id random(1, 200000)\nupdate t set v = v + 1 where id = :id;\n' > $SCR/w.sql
echo "# $N branches, ${SECS}s runs, server $(q -c 'show server_version')"
r0=$(tps $SCR/r.sql); w0=$(tps $SCR/w.sql)
t0=$(date +%s)
for ((done = 0; done < N; done += 5000)); do
  n=$(( N - done < 5000 ? N - done : 5000 ))
  q -c "select count(gnomon.create_branch('s' || g)) from generate_series($done + 1, $done + $n) g" >/dev/null
done
t1=$(date +%s)
# one branch in a hundred gets a write
q -c "do \$\$ declare i int; begin for i in 1..$N by 100 loop perform gnomon.use('s' || i); update t set v = -i where id = i; end loop; perform gnomon.use('main'); end \$\$" >/dev/null
t2=$(date +%s)
q -c "vacuum analyze" >/dev/null
r1=$(tps $SCR/r.sql); w1=$(tps $SCR/w.sql)
echo "create $N branches:            $(( t1 - t0 )) s ($(awk -v n=$N -v s=$(( t1 - t0 )) 'BEGIN {printf "%.2f", s * 1000 / n}') ms each)"
echo "a write on every 100th branch: $(( t2 - t1 )) s"
echo "catalog: $(q -c "select pg_size_pretty(pg_total_relation_size('gnomon.branch') + pg_total_relation_size('gnomon.branch_base'))") for branch + branch_base"
echo "main point read  before: $r0   after: $r1"
echo "main write       before: $w0   after: $w1"
echo "branch point read (last branch, 1 level): $(PGOPTIONS="-c gnomon.branch=s$N -c search_path=gnomon_r_public,public" C=1 tps $SCR/r.sql)"
psql -X -q -d postgres -c "drop database $DB" >/dev/null 2>&1 || true
