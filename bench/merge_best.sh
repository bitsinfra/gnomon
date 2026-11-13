#!/usr/bin/env bash
# Merge throughput (target: 100k rows/s): the best of ROUNDS merges of 50,000 updated rows into main,
# wall time and the backend's own CPU time, against the best untracked set-based update of the same
# rows. Best-of because the laptop these ran on is shared and has performance and efficiency cores.
#   PGHOST=... bench/merge_best.sh <port> [rounds]
set -uo pipefail
P=$1; R=${2:-4}; N=50000; DB=${DB:-gnomon_merge_best}
export PGPORT=$P
q() { psql -X -q -At -d $DB "$@"; }
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null 2>&1
q >/dev/null <<SQL
set client_min_messages = warning;
create extension gnomon;
create table big (id int primary key, v int not null, doc jsonb, name text);
insert into big select g, g, jsonb_build_object('k', g), 'n' || g from generate_series(1, 200000) g;
create table plain (like big including all); insert into plain select * from big;
vacuum analyze big, plain;
select gnomon.track('big');
select gnomon.heartbeat();
update big set v = v + 1 where id <= $N;
SQL
CM=$(q -c "select coalesce(current_setting('gnomon.c_module', true), '')")
[ "$CM" = on ] && q -c "set client_min_messages = warning" -c "create extension gnomon_c" -c "select gnomon.use_c_trigger('big')" >/dev/null
best_m=99; best_mc=99; best_u=99
for i in $(seq $R); do
  q -c "select gnomon.create_branch('mb$i')" -c "select gnomon.use('mb$i')" -c "update big set name = 'merged$i' where id <= $N" >/dev/null
  q -c "select gnomon.heartbeat()" >/dev/null
  out=$(psql -X -q -At -d $DB <<SQL
select pg_backend_pid() as pid \gset
\setenv GPID :pid
\! echo "c0 \$(ps -o time= -p \$GPID)"
\timing on
select gnomon.merge('mb$i') is not null;
\timing off
\! echo "c1 \$(ps -o time= -p \$GPID)"
\timing on
update plain set name = 'merged$i' where id <= $N;
SQL
)
  read m mc u <<<"$(echo "$out" | python3 -c "
import sys,re
t={}; times=[]
for l in sys.stdin:
    m=re.match(r'(c\d) +(\d+):([\d.]+)', l.strip())
    if m: t[m.group(1)]=int(m.group(2))*60+float(m.group(3))
    m=re.match(r'Time: ([\d.]+) ms', l.strip())
    if m: times.append(float(m.group(1))/1000)
print(times[0], t['c1']-t['c0'], times[1])")"
  best_m=$(python3 -c "print(min($best_m, $m))"); best_mc=$(python3 -c "print(min($best_mc, $mc))"); best_u=$(python3 -c "print(min($best_u, $u))")
done
python3 -c "print(f'c_module=${CM:-off}: best of $R merges of $N rows: wall {$best_m:.2f} s = {$N/$best_m:,.0f} rows/s (backend cpu {$best_mc:.2f} s); untracked set-based update {$best_u:.3f} s')"
echo "  load $(uptime | sed 's/.*averages*: //')"
psql -X -q -d postgres -c "drop database if exists $DB" >/dev/null 2>&1
