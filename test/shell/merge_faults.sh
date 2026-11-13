#!/usr/bin/env bash
# Merges that fail part-way (statement_timeout, disk full, a crash):
#  * an atomic merge cancelled by statement_timeout leaves nothing behind, and can be run again;
#  * an incremental merge keeps the batches it committed and resumes from its merge record,
#    after a statement_timeout and after kill -9 of the server, without applying a batch twice;
#  * a merge that runs out of disk (the target table on a full volume) fails with 53100, rolls
#    back, and succeeds once there is room. The volume is a small macOS disk image (hdiutil);
#    that part is skipped elsewhere.
source "$(dirname "$0")/_cluster.sh"
export PGOPTIONS='-c client_min_messages=warning'
P=54371
tc_init mf $P "" "synchronous_commit = on" "fsync = on"
q() { psql -X -q -At -v ON_ERROR_STOP=1 -p $P -d app "$@"; }
psql -X -q -p $P -d postgres -c "create database app"
q -c "set client_min_messages = warning" -c "create extension gnomon" >/dev/null
# a table whose writes on main are slow on demand (test.slow), so merges take a while
q >/dev/null <<'SQL'
create table t (id int primary key, v int not null);
insert into t select g, 0 from generate_series(1, 400) g;
select gnomon.track('t');
create function slow() returns trigger language plpgsql as $$
begin
  if current_setting('test.slow', true) = 'on' then perform pg_sleep(0.002); end if;
  return new;
end $$;
create trigger slow before update on t for each row execute function slow();
SQL
merge_versions() {   # versions written by a merge's transactions
  q -c "select count(*) from _gnomon.t__v v, gnomon.merge m
         where m.id = $1 and (((v.gn_key & 281474976710655) - v.gn_xoff)::text)::xid8 = any (m.xids) and v.gn_flags & 48 = 0"
}

# 1. atomic merge, cancelled
q -c "select gnomon.create_branch('b1')" -c "select gnomon.use('b1')" -c "update t set v = 1" >/dev/null
nv=$(q -c "select count(*) from _gnomon.t__v")
out=$(q -c "set test.slow = on" -c "set statement_timeout = '200ms'" -c "select gnomon.merge('b1')" 2>&1) && fail "the merge should time out"
grep -q "canceling statement due to statement timeout" <<<"$out" || fail "timeout error: $out"
[ "$(q -c "select count(*) from t where v = 1")" = 0 ] || fail "a cancelled atomic merge changed main"
[ "$(q -c "select count(*) from gnomon.merge")" = 0 ] || fail "a cancelled atomic merge left a merge record"
[ "$(q -c "select count(*) from _gnomon.t__v")" = "$nv" ] || fail "a cancelled atomic merge left versions"
m1=$(q -c "set test.slow = on" -c "select gnomon.merge('b1')")
[ "$(q -c "select count(*) from t where v = 1")" = 400 ] || fail "atomic merge after the timeout"
echo "atomic merge cancelled and rerun ok"

# 2. incremental merge, cancelled, resumed
q -c "select gnomon.create_branch('b2')" -c "select gnomon.use('b2')" -c "update t set v = 2" >/dev/null
out=$(q -c "set test.slow = on" -c "set statement_timeout = '300ms'" -c "call gnomon.merge_incremental('b2', batch => 25)" 2>&1) && fail "the incremental merge should time out"
m2=$(q -c "select max(id) from gnomon.merge where mode = 'incremental'")
done2=$(q -c "select count(*) from t where v = 2")
[ "$(q -c "select status from gnomon.merge where id = $m2")" = applying ] || fail "merge record after the timeout"
[ "$done2" -gt 0 ] && [ "$done2" -lt 400 ] && [ $((done2 % 25)) = 0 ] || fail "committed batches after the timeout: $done2"
q -c "set test.slow = on" -c "call gnomon.merge_incremental('b2', resume => $m2)" >/dev/null
[ "$(q -c "select count(*) from t where v = 2")" = 400 ] || fail "resumed incremental merge"
[ "$(q -c "select status from gnomon.merge where id = $m2")" = applied ] || fail "merge record after resuming"
[ "$(merge_versions $m2)" = 400 ] || fail "each row merged exactly once: $(merge_versions $m2) versions"
echo "incremental merge cancelled after $done2 rows and resumed ok"

# 3. incremental merge, server killed, resumed after crash recovery
q -c "select gnomon.create_branch('b3')" -c "select gnomon.use('b3')" -c "update t set v = 3" >/dev/null
( q -c "set test.slow = on" -c "call gnomon.merge_incremental('b3', batch => 25)" >/dev/null 2>&1 || true ) &
sleep 0.4
kill -9 "$(head -1 "$(tc_dir mf)/postmaster.pid")"
wait
rm -f "$(tc_dir mf)/postmaster.pid"
"$(pg_config --bindir)/pg_ctl" -D "$(tc_dir mf)" -l "$(tc_dir mf).log" -w start >/dev/null
m3=$(q -c "select max(id) from gnomon.merge where mode = 'incremental'")
done3=$(q -c "select count(*) from t where v = 3")
[ "$done3" -lt 400 ] && [ $((done3 % 25)) = 0 ] || fail "committed batches after the crash: $done3"
q -c "call gnomon.merge_incremental('b3', resume => $m3)" >/dev/null
[ "$(q -c "select count(*) from t where v = 3")" = 400 ] || fail "incremental merge resumed after a crash"
[ "$(merge_versions $m3)" = 400 ] || fail "each row merged exactly once across the crash: $(merge_versions $m3) versions"
echo "incremental merge killed after $done3 rows and resumed ok"

# 4. disk full under the target table
if command -v hdiutil >/dev/null 2>&1; then
  V="$ROOT/build/tc-mf-vol"
  [ -d "$V/mnt" ] && hdiutil detach "$V/mnt" -force >/dev/null 2>&1 || true   # left over from an interrupted run
  rm -rf "$V"; mkdir -p "$V"
  hdiutil create -size 8m -fs HFS+ -volname gnmf "$V/vol.dmg" >/dev/null
  hdiutil attach "$V/vol.dmg" -mountpoint "$V/mnt" -nobrowse >/dev/null
  trap 'tc_cleanup; hdiutil detach "$V/mnt" -force >/dev/null 2>&1; rm -rf "$V"' EXIT
  mkdir "$V/mnt/ts"
  q -c "create tablespace tiny location '$V/mnt/ts'" >/dev/null
  q -c "create table d (id int primary key using index tablespace tiny, pad text) tablespace tiny" \
    -c "alter table d alter pad set storage plain" \
    -c "insert into d select g, repeat('x', 1000) from generate_series(1, 100) g" -c "select gnomon.track('d')" >/dev/null
  q -c "select gnomon.create_branch('c')" -c "select gnomon.use('c')" \
    -c "insert into d select g, repeat('y', 1000) from generate_series(101, 3100) g" >/dev/null
  # fill the volume
  q -c "create table filler (x text) tablespace tiny" -c "alter table filler alter x set storage plain" >/dev/null
  q -c "do \$\$ begin loop insert into filler select repeat('f', 1000) from generate_series(1, 500); end loop;
        exception when disk_full then null; end \$\$" >/dev/null
  nv=$(q -c "select count(*) from _gnomon.d__v")
  out=$(q -c "select gnomon.merge('c')" 2>&1) && fail "the merge should run out of disk"
  grep -q "No space left on device" <<<"$out" || fail "disk-full error: $out"
  [ "$(q -c "select count(*) from d")" = 100 ] || fail "a merge that ran out of disk changed main"
  [ "$(q -c "select count(*) from gnomon.merge m join gnomon.branch b on b.id = m.source where b.name = 'c'")" = 0 ] || fail "merge record left behind"
  [ "$(q -c "select count(*) from _gnomon.d__v")" = "$nv" ] || fail "versions left behind by the failed merge"
  q -c "drop table filler" -c "checkpoint" >/dev/null
  q -c "select gnomon.merge('c')" >/dev/null
  [ "$(q -c "select count(*) from d")" = 3100 ] || fail "merge after freeing disk"
  [ "$(q -c "select count(*) from gnomon.doctor() where status = 'error'")" = 0 ] || fail "doctor after the disk-full merge"
  echo "merge out of disk rolled back and rerun ok"
else
  echo "skip disk full: no hdiutil"
fi
