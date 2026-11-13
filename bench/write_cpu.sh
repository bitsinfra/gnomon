#!/usr/bin/env bash
# Server-side CPU per single-row write: a procedure runs N UPDATEs by random key, each in its own
# transaction, on an untracked table and on a table versioned by the C trigger; the backend's CPU
# time (from ps, before and after) gives microseconds per write. CPU time leaves out the client
# round trip and is far less sensitive to other load on the machine than throughput. Best of
# ROUNDS, tables alternating. Needs gnomon_c preloaded.
#   PGHOST=... bench/write_cpu.sh <port> [rounds] [n] [rows]
set -uo pipefail
P=$1; R=${2:-5}; N=${3:-30000}; ROWS=${4:-50000}; DB=${DB:-gnomon_write_cpu}
export PGPORT=$P
psql -X -q -d postgres -c "drop database if exists $DB with (force)" -c "create database $DB" >/dev/null 2>&1
psql -X -q -d $DB >/dev/null <<SQL
set client_min_messages = warning;
create extension gnomon; create extension gnomon_c;
create table u (id int primary key, a int not null, b int not null, c text not null);
insert into u select g, 0, g, md5(g::text) from generate_series(1, $ROWS) g;
create table cc (like u including all); insert into cc select * from u;
select gnomon.track('cc'); select gnomon.use_c_trigger('cc');
select gnomon.heartbeat();
update cc set a = 1; update cc set a = 2; update u set a = 2;   -- the steady state
vacuum analyze;
create procedure w(tbl text, n int) language plpgsql as \$\$
declare k int;
begin
  for i in 1..n loop
    k := 1 + (random() * ($ROWS - 1))::int;
    execute format('update %I set a = a + 1 where id = \$1', tbl) using k;
    commit;
  end loop;
end \$\$;
SQL
# CPU milliseconds of one call: the backend's own ps TIME before and after
cpu() {
  psql -X -q -At -d $DB <<SQL 2>/dev/null | grep ':' | awk 'function s(x,  a){split(x,a,":"); return a[1]*60+a[2]} NR==1{b=s($1)} NR==2{e=s($1)} END {printf "%.0f", (e-b)*1000}'
call w('$1', 2000);
select pg_backend_pid() as pid \gset
\setenv GNPID :pid
\! ps -o time= -p \$GNPID
call w('$1', $N);
\! ps -o time= -p \$GNPID
SQL
}
bu=; bc=
for i in $(seq $R); do
  v=$(cpu u); [ -z "$bu" ] || [ $v -lt $bu ] && bu=$v
  v=$(cpu cc); [ -z "$bc" ] || [ $v -lt $bc ] && bc=$v
done
us() { echo "scale=1; 1000 * $1 / $N" | bc; }
echo "CPU per single-row UPDATE, best of $R x $N: untracked $(us $bu) us | C trigger $(us $bc) us"
echo "load $(uptime | sed 's/.*averages*: //')"
psql -X -q -d postgres -c "drop database if exists $DB with (force)" >/dev/null 2>&1
