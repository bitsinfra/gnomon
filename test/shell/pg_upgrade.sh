#!/usr/bin/env bash
# pg_upgrade across major versions: a cluster of every older major version that is
# installed (Homebrew postgresql@15/16/17, or PG_OLD_BINS) with gnomon (plain-SQL install: before 18
# there is no extension_control_path for the dev build), upgraded in place to the server under
# test (pg_config on PATH).
#  * The system identifier changes, so the first write starts a new epoch.
#  * Coordinates handed out before the upgrade still read exactly, before and after new writes.
#  * Branches, tags, the change feed, merges and doctor work across the upgrade.
source "$(dirname "$0")/_cluster.sh"
NEW=$(pg_config --bindir)
nm=$("$NEW/pg_config" --version | sed 's/[^0-9]*\([0-9]*\).*/\1/')
"$ROOT/tools/build_install_forms.sh" >/dev/null
OLDS=${PG_OLD_BINS:-${PG_OLD_BIN:-$(for v in 15 16 17; do echo /opt/homebrew/opt/postgresql@$v/bin; done)}}
ran=0
upgrade_from() {
OLD=$1
om=$("$OLD/pg_config" --version | sed 's/[^0-9]*\([0-9]*\).*/\1/')
OP=54351 NP=54352
tc_init pgu-old $OP "$OLD"
o() { psql -X -q -At -v ON_ERROR_STOP=1 -p $OP -d app "$@"; }
n() { psql -X -q -At -v ON_ERROR_STOP=1 -p $NP -d app "$@"; }
psql -X -q -p $OP -d postgres -c "create database app"
GN_VERSION=$(sed -n "s/^default_version = '\(.*\)'/\1/p" "$ROOT/gnomon.control")
o -c "set client_min_messages = warning" -f "$ROOT/build/dist/gnomon-plain--$GN_VERSION.sql" >/dev/null
o -c "create table acct(id int primary key, name text, bal int, doc jsonb)" \
  -c "insert into acct select g, 'a' || g, 100, jsonb_build_object('g', g) from generate_series(1, 30) g" \
  -c "select gnomon.track('acct')" -c "update acct set bal = bal - 1 where id <= 10" >/dev/null
rows() { echo "select string_agg(id || ':' || name || ':' || bal, ',' order by id) from acct"; }
c1=$(o -c "select gnomon.coordinate_text()"); r1=$(o -c "$(rows)")
o -c "select gnomon.create_branch('feat')" -c "select gnomon.use('feat')" -c "update acct set name = 'branch' where id = 2" \
  -c "select gnomon.use('main')" -c "insert into gnomon.tag(name, coord) select 'v1', gnomon.coordinate()" \
  -c "update acct set bal = 0 where id = 1" -c "select gnomon.feed_create('etl', '$c1')" >/dev/null
c2=$(o -c "select gnomon.coordinate_text()"); r2=$(o -c "$(rows)")
"$OLD/pg_ctl" -D "$(tc_dir pgu-old)" -m fast stop >/dev/null

# the new cluster: same settings, not started; then pg_upgrade (copy mode)
# 18 turns data checksums on by default (and has the option to turn them off); older ones do not
CS=""; [ "$nm" -ge 18 ] && CS=--no-data-checksums
TC_NOSTART=1 TC_INITDB_OPTS=$CS tc_init pgu-new $NP "$NEW"
(cd "$ROOT/build" && "$NEW/pg_upgrade" -U postgres -b "$OLD" -B "$NEW" -d "$(tc_dir pgu-old)" -D "$(tc_dir pgu-new)" \
   -p $OP -P $NP -s "$ROOT/build" > "$ROOT/build/pg_upgrade.out" 2>&1) || { tail -30 "$ROOT/build/pg_upgrade.out"; fail "pg_upgrade"; }
"$NEW/pg_ctl" -D "$(tc_dir pgu-new)" -l "$(tc_dir pgu-new).log" -w start >/dev/null
[ "$(n -c "show server_version_num")" -ge $(( nm * 10000 )) ] || fail "the new cluster should be $nm"

# reads at coordinates from before the upgrade
[ "$(n -c "select gnomon.use('main', '$c1')" -c "$(rows)" | tail -1)" = "$r1" ] || fail "as-of read at c1 after pg_upgrade"
[ "$(n -c "select gnomon.use('main', '$c2')" -c "$(rows)" | tail -1)" = "$r2" ] || fail "as-of read at c2 after pg_upgrade"
[ "$(n -c "select gnomon.use('feat')" -c "select name from acct where id = 2" | tail -1)" = "branch" ] || fail "branch after pg_upgrade"
[ "$(n -c "select gnomon.use('main', 'tag:v1')" -c "select bal from acct where id = 1" | tail -1)" = "99" ] || fail "tag after pg_upgrade"
# new writes: a new epoch (new system identifier); xids continue, keys keep increasing
n -c "update acct set bal = 42 where id = 3" >/dev/null
[ "$(n -c "select max(gn_key >> 48) from _gnomon.acct__v")" = "2" ] || fail "pg_upgrade should start epoch 2"
[ "$(n -c "select count(*) from gnomon.epoch")" = "2" ] || fail "two epochs registered"
c3=$(n -c "select gnomon.coordinate_text()")
[ "${c3%%:*}" = "e2" ] || fail "new coordinates in epoch 2: $c3"
[ "$(n -c "select gnomon.use('main', '$c3')" -c "select bal from acct where id = 3" | tail -1)" = "42" ] || fail "new-epoch read"
[ "$(n -c "select gnomon.use('main', '$c1')" -c "$(rows)" | tail -1)" = "$r1" ] || fail "old-epoch read after new writes"
# the feed consumer created before the upgrade continues across it, in order
[ "$(n -c "select string_agg(key->>'id', ',' order by vkey, vlsn) from gnomon.feed_poll('etl', 100)")" = "1,3" ] || fail "feed across pg_upgrade"
[ "$(n -c "select count(*) from gnomon.history('acct', '{\"id\": 1}') where op <> 'baseline'")" = "2" ] || fail "row history across pg_upgrade"
n -c "select gnomon.merge('feat')" >/dev/null
[ "$(n -c "select name from acct where id = 2")" = "branch" ] || fail "merge after pg_upgrade"
[ "$(n -c "select count(*) from gnomon.doctor() where status = 'error'")" = "0" ] || fail "doctor after pg_upgrade: $(n -c "select string_agg(check_name || ': ' || detail, '; ') from gnomon.doctor() where status = 'error'")"
echo "pg_upgrade $(o -c 'select 1' 2>/dev/null || "$OLD/postgres" --version | awk '{print $3}') -> $(n -c 'show server_version') ok"
ran=$((ran + 1))
}
for OLD in $OLDS; do
  [ -x "$OLD/pg_ctl" ] || continue
  om=$("$OLD/pg_config" --version | sed 's/[^0-9]*\([0-9]*\).*/\1/')
  [ "$om" -lt "$nm" ] || continue
  upgrade_from "$OLD"
done
[ $ran -gt 0 ] || echo "skip: no PostgreSQL older than $nm installed"
