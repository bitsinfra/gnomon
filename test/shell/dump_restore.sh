#!/usr/bin/env bash
# pg_dump a gnomon database and restore it into another cluster (a new system identifier):
# old coordinates still read exactly, branches survive, new writes start a new epoch.
# Needs a second cluster: the other dev cluster (54330 when testing on 54329 and back;
# src/c/test/run.sh starts 54330); skipped otherwise.
source "$(dirname "$0")/_lib.sh"
if [ "$PGPORT" = 54330 ]; then DST_PORT=${DST_PORT:-54329}; else DST_PORT=${DST_PORT:-54330}; fi
[ "$DST_PORT" != "$PGPORT" ] || { echo "skip: destination must be another cluster"; exit 0; }
if ! psql -X -q -p "$DST_PORT" -d postgres -c 'select 1' >/dev/null 2>&1; then echo "skip: no cluster on $DST_PORT"; exit 0; fi
q -c "create table acct(id int primary key, name text, bal int); insert into acct select g, 'a' || g, 100 from generate_series(1, 20) g;
      select gnomon.track('acct'); update acct set bal = bal - 1 where id <= 5;" >/dev/null
c1=$(q -c "select gnomon.coordinate_text()")
rows1=$(q -c "select string_agg(id || ':' || bal, ',' order by id) from acct")
q -c "update acct set bal = 0 where id = 1" -c "select gnomon.create_branch('feat')" \
  -c "insert into gnomon.tag(name, coord) select 'v1', gnomon.coordinate()" -c "select gnomon.use('feat')" -c "update acct set name = 'branch' where id = 2" >/dev/null
# an open schema version: a column and a table made on a branch
q -c "select gnomon.create_branch('sv')" -c "select gnomon.use('sv')" \
  -c "select gnomon.ddl(\$\$alter table acct add column tier text default 'basic'\$\$)" \
  -c "select gnomon.ddl(\$\$create table note (id int primary key, body text)\$\$)" \
  -c "update acct set tier = 'gold' where id = 4" -c "insert into note values (1, 'n')" >/dev/null
DST=gts_restored
psql -X -q -p "$DST_PORT" -d postgres -c "drop database if exists $DST" -c "create database $DST" >/dev/null 2>&1
pg_dump -d "$DB" > "$ROOT/build/dump.sql" 2>"$ROOT/build/dump.err"
psql -X -q -v ON_ERROR_STOP=1 -p "$DST_PORT" -d "$DST" -f "$ROOT/build/dump.sql" >/dev/null 2>"$ROOT/build/restore.err" || { cat "$ROOT/build/restore.err"; fail "restore failed"; }
r() { psql -X -q -At -v ON_ERROR_STOP=1 -p "$DST_PORT" -d "$DST" "$@"; }
[ "$(r -c "select gnomon.use('main', '$c1')" -c "select string_agg(id || ':' || bal, ',' order by id) from acct" | tail -1)" = "$rows1" ] || fail "as-of read after restore"
[ "$(r -c "select gnomon.use('feat')" -c "select name from acct where id = 2" | tail -1)" = "branch" ] || fail "branch after restore"
[ "$(r -c "select gnomon.use('main', 'tag:v1')" -c "select bal from acct where id = 1" | tail -1)" = "0" ] || fail "tag after restore"
r -c "update acct set bal = 42 where id = 3" >/dev/null
[ "$(r -c "select max(gn_key >> 48) from _gnomon.acct__v")" = "2" ] || fail "restore should start epoch 2"
c2=$(r -c "select gnomon.coordinate_text()")
[ "$(r -c "select gnomon.use('main', '$c2')" -c "select bal from acct where id = 3" | tail -1)" = "42" ] || fail "new-epoch read"
[ "$(r -c "select gnomon.use('main', '$c1')" -c "select bal from acct where id = 3" | tail -1)" = "99" ] || fail "old-epoch read after new writes"
[ "$(r -c "select gnomon.use('sv')" -c "select tier || ',' || (select count(*) from note) from acct where id = 4" | tail -1)" = "gold,1" ] || fail "schema version after restore"
r -c "select gnomon.merge('sv')" >/dev/null
[ "$(r -c "select tier from acct where id = 4")" = "gold" ] || fail "schema version merge after restore"
r -c "select gnomon.merge('feat')" >/dev/null
[ "$(r -c "select name from acct where id = 2")" = "branch" ] || fail "merge after restore"
[ "$(r -c "select count(*) from gnomon.doctor() where status = 'error'")" = "0" ] || fail "doctor after restore"
psql -X -q -p "$DST_PORT" -d postgres -c "drop database $DST" >/dev/null 2>&1
echo ok
