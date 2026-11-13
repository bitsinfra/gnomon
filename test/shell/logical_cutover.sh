#!/usr/bin/env bash
# Logical-replication cutover: a gnomon database moved to another cluster with
# logical replication, history included, then switched over.
#  * Replicated writes are not versioned again on the subscriber: the versioning trigger is
#    ENABLE ALWAYS and skips inside an apply worker; versions arrive with their original stamps.
#  * After cutover the subscriber (a new system identifier) writes in a new epoch, and
#    coordinates handed out on the old cluster still read exactly there.
# The initial copy is a pg_dump taken while the publisher is quiet right after the slot was made
# (production would use the slot's exported snapshot: pg_dump --snapshot).
source "$(dirname "$0")/_cluster.sh"
AP=54361 BP=54362
tc_init lc-a $AP
tc_init lc-b $BP
a() { psql -X -q -At -v ON_ERROR_STOP=1 -p $AP -d app "$@"; }
b() { psql -X -q -At -v ON_ERROR_STOP=1 -p $BP -d app "$@"; }
psql -X -q -p $AP -d postgres -c "create database app"
psql -X -q -p $BP -d postgres -c "create database app"
a -c "set client_min_messages = warning" -c "create extension gnomon" \
  -c "create table acct(id int primary key, name text, bal int)" \
  -c "insert into acct select g, 'a' || g, 100 from generate_series(1, 30) g" \
  -c "select gnomon.track('acct')" -c "update acct set bal = bal - 1 where id <= 10" >/dev/null
rows() { echo "select string_agg(id || ':' || name || ':' || bal, ',' order by id) from acct"; }
c1=$(a -c "select gnomon.coordinate_text()"); r1=$(a -c "$(rows)")

# publish everything; slot first, then the copy, with no writes in between
a -c "create publication cut for all tables" -c "select pg_create_logical_replication_slot('cut', 'pgoutput')" >/dev/null
pg_dump -p $AP -d app > "$ROOT/build/lc_dump.sql" 2>"$ROOT/build/lc_dump.err"
b -c "set client_min_messages = warning" -f "$ROOT/build/lc_dump.sql" >/dev/null 2>"$ROOT/build/lc_restore.err" || { cat "$ROOT/build/lc_restore.err"; fail "restore"; }
b -c "create subscription cut connection 'host=$ROOT/build port=$AP dbname=app user=postgres' publication cut
        with (copy_data = false, create_slot = false, slot_name = 'cut')" >/dev/null

# writes on the publisher while replicating: rows, a branch, a tag, a tick
a -c "update acct set bal = 0 where id = 1" -c "insert into acct values (31, 'new', 5)" -c "delete from acct where id = 30" \
  -c "select gnomon.create_branch('feat')" -c "select gnomon.use('feat')" -c "update acct set name = 'branch' where id = 2" \
  -c "select gnomon.use('main')" -c "insert into gnomon.tag(name, coord) select 'v1', gnomon.coordinate()" \
  -c "select gnomon.heartbeat()" >/dev/null
c2=$(a -c "select gnomon.coordinate_text()"); r2=$(a -c "$(rows)")
target=$(a -c "select pg_current_wal_insert_lsn()")
for i in $(seq 1 100); do
  [ "$(a -c "select confirmed_flush_lsn >= '$target' from pg_replication_slots where slot_name = 'cut'")" = t ] && break
  sleep 0.1
done
[ "$(a -c "select confirmed_flush_lsn >= '$target' from pg_replication_slots where slot_name = 'cut'")" = t ] || fail "subscriber did not catch up"

# replicated writes carry the publisher's versions, once
for q in "select count(*) from _gnomon.acct__v" "select count(*) from _gnomon.acct__bv" "$(rows)" \
         "select string_agg(gn_key || '/' || gn_lsn, ',' order by gn_key, gn_lsn) from _gnomon.acct__v"; do
  [ "$(b -c "$q")" = "$(a -c "$q")" ] || fail "replicated state differs: $q"
done
[ "$(b -c "select gnomon.use('main', '$c2')" -c "$(rows)" | tail -1)" = "$r2" ] || fail "as-of read on the subscriber before cutover"

# cutover: stop replication, carry the sequences over, write on the new cluster
b -c "alter subscription cut disable" -c "alter subscription cut set (slot_name = none)" -c "drop subscription cut" >/dev/null
a -c "select pg_drop_replication_slot('cut')" >/dev/null
a -c "select format('select setval(%L, %s, true);', quote_ident(schemaname) || '.' || quote_ident(sequencename), last_value)
        from pg_sequences where last_value is not null" > "$ROOT/build/lc_seq.sql"
b -f "$ROOT/build/lc_seq.sql" >/dev/null
b -c "update acct set bal = 42 where id = 3" >/dev/null
[ "$(b -c "select max(gn_key >> 48) from _gnomon.acct__v")" = "2" ] || fail "the new cluster writes in epoch 2"
c3=$(b -c "select gnomon.coordinate_text()")
[ "${c3%%:*}" = "e2" ] || fail "new coordinates in epoch 2: $c3"
for pair in "$c1|$r1" "$c2|$r2"; do
  [ "$(b -c "select gnomon.use('main', '${pair%%|*}')" -c "$(rows)" | tail -1)" = "${pair#*|}" ] || fail "replay of ${pair%%|*} after cutover"
done
[ "$(b -c "select gnomon.use('main', '$c3')" -c "select bal from acct where id = 3" | tail -1)" = "42" ] || fail "new-epoch read"
[ "$(b -c "select gnomon.use('main', 'tag:v1')" -c "select bal from acct where id = 1" | tail -1)" = "0" ] || fail "tag after cutover"
[ "$(b -c "select gnomon.use('feat')" -c "select name from acct where id = 2" | tail -1)" = "branch" ] || fail "branch after cutover"
[ "$(b -c "select string_agg(key->>'id', ',' order by vkey, vlsn) from gnomon.changes('$c1') where tbl = 'acct'::regclass")" = "1,31,30,3" ] \
  || fail "feed across cutover: $(b -c "select string_agg(key->>'id' || ':' || op, ',' order by vkey, vlsn) from gnomon.changes('$c1')")"
b -c "select gnomon.create_branch('after')" >/dev/null   # the branch id sequence was carried over
b -c "select gnomon.merge('feat')" >/dev/null
[ "$(b -c "select name from acct where id = 2")" = "branch" ] || fail "merge after cutover"
[ "$(b -c "select count(*) from gnomon.doctor() where status = 'error'")" = "0" ] || fail "doctor after cutover"
echo "logical cutover ok"
