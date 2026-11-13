#!/usr/bin/env bash
# Reads on a physical standby and physical failover.
#  * Coordinates are captured on the primary only.
#  * A read at coordinate C on a standby waits until the standby has replayed past C, and a read
#    that cannot be proven to have waited is refused, never answered from a lagging standby.
#  * Branches, tags and as-of reads give the primary's answers on the standby.
#  * After promotion the coordinates and the history are unchanged; the new timeline starts a new
#    epoch, so xids of the old timeline that are assigned again never show at old coordinates.
source "$(dirname "$0")/_cluster.sh"
PP=54341 SP=54342
tc_init sb-primary $PP
p() { psql -X -q -At -v ON_ERROR_STOP=1 -p $PP -d app "$@"; }
s() { psql -X -q -At -v ON_ERROR_STOP=1 -p $SP -d app "$@"; }
psql -X -q -p $PP -d postgres -c "create database app"
p -c "set client_min_messages = warning" -c "create extension gnomon" \
  -c "create table acct(id int primary key, name text, bal int)" \
  -c "insert into acct select g, 'a' || g, 100 from generate_series(1, 50) g" \
  -c "select gnomon.track('acct')" -c "update acct set bal = bal - 1 where id <= 10" >/dev/null
tc_standby sb-standby $SP $PP
rows() { echo "select string_agg(id || ':' || name || ':' || bal, ',' order by id) from acct"; }

c1=$(p -c "select gnomon.coordinate_text()"); r1=$(p -c "$(rows)")
p -c "select gnomon.create_branch('feat')" -c "select gnomon.use('feat')" -c "update acct set name = 'branch' where id = 2" \
  -c "select gnomon.use('main')" -c "insert into gnomon.tag(name, coord) select 'v1', gnomon.coordinate()" >/dev/null
p -c "select gnomon.create_branch('tmp', kind => 'scratch')" -c "select gnomon.use('tmp')" -c "update acct set name = 'scratch' where id = 3" >/dev/null
p -c "update acct set bal = 0 where id = 1" >/dev/null
c2=$(p -c "select gnomon.coordinate_text()"); r2=$(p -c "$(rows)")

# 1. waiting reads: gnomon.use waits for replay, then reads exactly what the primary had at C
[ "$(s -c "select gnomon.use('main', '$c1')" -c "$(rows)" | tail -1)" = "$r1" ] || fail "as-of read at c1 on the standby"
[ "$(s -c "select gnomon.use('main', '$c2')" -c "$(rows)" | tail -1)" = "$r2" ] || fail "as-of read at c2 on the standby"
[ "$(s -c "select gnomon.use('feat')" -c "select name from acct where id = 2" | tail -1)" = "branch" ] || fail "branch read on the standby"
[ "$(s -c "select gnomon.use('main', 'tag:v1')" -c "select bal from acct where id = 1" | tail -1)" = "99" ] || fail "tag read on the standby"
[ "$(s -c "$(rows)")" = "$r2" ] || fail "current read on the standby"
s -c "select gnomon.coordinate()" >/dev/null 2>&1 && fail "coordinates must not be captured on a standby"
out=$(s -c "select gnomon.use('tmp')" 2>&1) && fail "a scratch branch must not be readable on a standby"
grep -q "not replicated" <<<"$out" || fail "scratch on standby: $out"
out=$(s -c "set gnomon.branch = 'tmp'" -c "set search_path = gnomon_r_public, public" -c "$(rows)" 2>&1) && fail "scratch context through logged views"
grep -q "gnomon_r_<schema>__s" <<<"$out" || fail "scratch guard on standby: $out"
[ "$(s -c "select count(*) from gnomon.diff('main', 'feat')")" -ge 1 ] || fail "diff on the standby"
# schema versions: a branch's version views and branch-only values on the standby
p -c "select gnomon.create_branch('vers')" -c "select gnomon.use('vers')" \
  -c "select gnomon.ddl('alter table acct add column tier text default ''basic''')" \
  -c "select gnomon.ddl('alter table acct rename column name to full_name')" \
  -c "update acct set tier = 'gold' where id = 6" >/dev/null
cv=$(p -c "select gnomon.coordinate_text()")
s -c "select gnomon.wait_for('$cv')" >/dev/null
[ "$(s -c "select gnomon.use('vers')" -c "select full_name || ':' || tier from acct where id = 6" | tail -1)" = "a6:gold" ] || fail "a schema version read on the standby"
[ "$(s -c "select gnomon.use('vers')" -c "select tier from acct where id = 7" | tail -1)" = "basic" ] || fail "an added column's default on the standby"
[ "$(s -c "select gnomon.use('main')" -c "select name from acct where id = 6" | tail -1)" = "a6" ] || fail "main's shape on the standby"
echo "standby reads ok"

# 2. a lagging standby: replay paused, a newer coordinate is refused or waited for, never misread
s -c "select pg_wal_replay_pause()" >/dev/null
for i in 1 2 3 4 5; do [ "$(s -c "select pg_get_wal_replay_pause_state()")" = paused ] && break; sleep 0.2; done
p -c "update acct set bal = 7 where id = 3" >/dev/null
c3=$(p -c "select gnomon.coordinate_text()"); r3=$(p -c "$(rows)")
out=$(s -c "set gnomon.standby_wait = '300ms'" -c "select gnomon.use('main', '$c3')" 2>&1) && fail "use() must time out on a paused standby"
grep -q "has not replayed" <<<"$out" || fail "timeout message: $out"
out=$(s -c "set gnomon.as_of = '$c3'" -c "set search_path = gnomon_r_public, public" -c "$(rows)" 2>&1) && fail "a read at an unreplayed coordinate must be refused"
grep -q "may not have replayed" <<<"$out" || fail "refusal message: $out"
# an old coordinate set directly (no wait) is still fine: every xid below its xmax has finished
[ "$(s -c "set gnomon.as_of = '$c1'" -c "set search_path = gnomon_r_public, public" -c "$(rows)" | tail -1)" = "$r1" ] || fail "old coordinate without a wait"
# resume in the background while a waiting read is in flight
( sleep 0.5; s -c "select pg_wal_replay_resume()" >/dev/null ) &
[ "$(s -c "select gnomon.use('main', '$c3')" -c "$(rows)" | tail -1)" = "$r3" ] || fail "waited read at c3"
wait
# under REPEATABLE READ the wait must come before the transaction's snapshot
[ "$(s -c "select gnomon.wait_for('$c3')" -c "begin isolation level repeatable read" -c "set local gnomon.as_of = '$c3'" \
       -c "set local search_path = gnomon_r_public, public" -c "$(rows)" -c "commit" | sed -n 2p)" = "$r3" ] || fail "repeatable read after wait_for"
echo "lagging standby ok"

# 3. failover: promote the standby; epoch, coordinates and history carry over
p -c "update acct set bal = 8 where id = 4" >/dev/null
c4=$(p -c "select gnomon.coordinate_text()"); r4=$(p -c "$(rows)")
s -c "select gnomon.wait_for('$c4')" >/dev/null
e_before=$(p -c "select string_agg(epoch || '/' || sysid, ',') from gnomon.epoch")
"$(pg_config --bindir)/pg_ctl" -D "$(tc_dir sb-primary)" -m immediate stop >/dev/null
"$(pg_config --bindir)/pg_ctl" -D "$(tc_dir sb-standby)" -w promote >/dev/null
[ "$(s -c "select pg_is_in_recovery()")" = f ] || fail "promotion"
s -c "update acct set bal = 9 where id = 5" >/dev/null
c5=$(s -c "select gnomon.coordinate_text()")
# the new timeline starts epoch 2 (xids of the old timeline that never reached the standby may be
# assigned again; they must not show at old coordinates), same system identifier
[ "$e_before" = "1/$(s -c "select gnomon._sysid()")" ] || fail "epoch before failover: $e_before"
[ "$(s -c "select string_agg(epoch || '/' || tli, ',' order by epoch) from gnomon.epoch")" = "1/1,2/2" ] || fail "failover starts an epoch for the new timeline"
[ "$(s -c "select max(gn_key >> 48) from _gnomon.acct__v")" = "2" ] || fail "writes after failover are stamped in epoch 2"
[ "${c5%%:*}" = "e2" ] || fail "coordinates after failover are in epoch 2: $c5"
for pair in "$c1|$r1" "$c2|$r2" "$c3|$r3" "$c4|$r4"; do
  [ "$(s -c "select gnomon.use('main', '${pair%%|*}')" -c "$(rows)" | tail -1)" = "${pair#*|}" ] || fail "replay after failover at ${pair%%|*}"
done
[ "$(s -c "select gnomon.use('main', '$c5')" -c "select bal from acct where id = 5" | tail -1)" = "9" ] || fail "new coordinate after failover"
# the feed from c1 to now is the four main writes since, in order, ending with the post-failover one
[ "$(s -c "select string_agg(key->>'id', ',' order by vkey, vlsn) from gnomon.changes('$c1') where tbl = 'acct'::regclass")" = "1,3,4,5" ] \
  || fail "change feed across failover: $(s -c "select string_agg(key->>'id', ',' order by vkey, vlsn) from gnomon.changes('$c1')")"
s -c "select gnomon.merge('feat')" >/dev/null
[ "$(s -c "select name from acct where id = 2")" = "branch" ] || fail "merge after failover"
[ "$(s -c "select count(*) from gnomon.doctor() where status = 'error'")" = 0 ] || fail "doctor after failover"
echo "failover ok"
