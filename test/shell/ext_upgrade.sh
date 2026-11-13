#!/usr/bin/env bash
# Extension upgrade with live data: install the previous version (the SQL core at
# GN_UPGRADE_FROM, default the last commit) as version "prev", give it history, branches, merges,
# a bitemporal table, a held outbox, a mask profile and a user view, then
# ALTER EXTENSION gnomon UPDATE to the version in the working tree, and check that nothing was
# lost and everything still reads and writes. The plain-SQL install form's upgrade script is
# exercised the same way.
source "$(dirname "$0")/_cluster.sh"
FROM=${GN_UPGRADE_FROM:-HEAD}
TO=$(sed -n "s/^default_version = '\(.*\)'/\1/p" "$ROOT/gnomon.control")
X=$ROOT/build/tc-extup-files
rm -rf "$X"; mkdir -p "$X/extension"
(cd "$ROOT" && make -s "sql/gnomon--$TO.sql")
# the previous version's install script, built from git the way the Makefile builds it
{ echo "-- gnomon at $FROM"
  for f in $(cd "$ROOT" && git ls-tree --name-only "$FROM" src/sql/ | grep '\.sql$' | sort); do
    echo; echo "-- ==== $f"; (cd "$ROOT" && git show "$FROM:$f")
  done; } | awk 'BEGIN{n=0} /^\\echo Use/ {n++; if (n > 1) next} {print}' > "$X/extension/gnomon--prev.sql"
cp "$ROOT/sql/gnomon--$TO.sql" "$X/extension/"
python3 "$ROOT/tools/build_upgrade.py" "$ROOT/sql/gnomon--$TO.sql" prev "$TO" > "$X/extension/gnomon--prev--$TO.sql"
sed "s/^default_version = .*/default_version = '$TO'/" "$ROOT/gnomon.control" > "$X/extension/gnomon.control"
P=54381
if [ "$(pg_config --version | sed 's/[^0-9]*\([0-9]*\).*/\1/')" -ge 18 ]; then
  # this test's files first: a server with gnomon installed (make install, as CI does) has its
  # own gnomon.control, and PostgreSQL takes the scripts from the directory of the first control
  # file it finds
  tc_init extup $P "" "extension_control_path = '$X:\$system'"
else
  tc_init extup $P
fi
q() { psql -X -q -At -v ON_ERROR_STOP=1 -p $P -d app "$@"; }
psql -X -q -p $P -d postgres -c "create database app"
export PGOPTIONS='-c client_min_messages=warning'

# a second set of extension files needs extension_control_path (PostgreSQL 18); older servers
# test the plain-SQL form's upgrade only
if [ "$(q -c "show server_version_num")" -ge 180000 ]; then
q -c "create extension gnomon version 'prev'" >/dev/null
q >/dev/null <<'SQL'
create table acct (id int primary key, owner text not null, bal int not null default 0);
create table ord (id bigserial primary key, acct int not null references acct(id) on delete cascade, amount numeric not null);
create table price (sku text primary key, cents int not null);
create table outbox_msg (id bigserial primary key, body text);
create view rich as select id, owner from acct where bal > 150;
insert into acct select g, 'o' || g, 100 + g * 5 from generate_series(1, 20) g;
insert into ord (acct, amount) select 1 + g % 20, g from generate_series(1, 40) g;
insert into price values ('a', 100), ('b', 200);
select gnomon.track('acct'); select gnomon.track('ord'); select gnomon.track('price', mode => 'bitemporal');
select gnomon.track('outbox_msg'); select gnomon.outbox('outbox_msg', 'up_test');
update acct set bal = bal + 1 where id <= 5;
select gnomon.create_branch('feat');
select gnomon.use('feat');
update acct set owner = 'branch' where id = 2;
insert into ord (acct, amount) values (2, 999);
select gnomon.use('main');
select gnomon.create_branch('merged');
select gnomon.use('merged'); update acct set bal = 0 where id = 7; select gnomon.use('main');
select gnomon.merge('merged');
insert into gnomon.tag(name, coord) select 'before-upgrade', gnomon.coordinate();
select gnomon.feed_create('etl', 'now');
select gnomon.create_mask_profile('pii');
select gnomon.add_mask_rule('pii', 'acct', 'owner', '''***''');
select gnomon.build_mask_profile('pii');
SQL
rows() { echo "select string_agg(id || ':' || owner || ':' || bal, ',' order by id) from acct"; }
c1=$(q -c "select gnomon.coordinate_text()"); r1=$(q -c "$(rows)")
q -c "update acct set bal = -1 where id = 1" -c "insert into outbox_msg (body) values ('hello')" >/dev/null
nv=$(q -c "select count(*) from _gnomon.acct__v"); nb=$(q -c "select count(*) from gnomon.branch")

# the upgrade
q -c "alter extension gnomon update to '$TO'" >/dev/null || fail "ALTER EXTENSION gnomon UPDATE"
[ "$(q -c "select extversion from pg_extension where extname = 'gnomon'")" = "$TO" ] || fail "extension version after the update"
[ "$(q -c "select count(*) from _gnomon.acct__v")" = "$nv" ] || fail "versions lost in the upgrade"
[ "$(q -c "select count(*) from gnomon.branch")" = "$nb" ] || fail "branches lost in the upgrade"
[ "$(q -c "select count(*) from information_schema.columns where table_schema = 'gnomon' and table_name = 'epoch' and column_name = 'tli'")" = 1 ] \
  || fail "the epoch migration"
[ "$(q -c "select count(*) from pg_event_trigger where evtname like 'gnomon%'")" = 2 ] || fail "event triggers after the update"
[ "$(q -c "select count(*) from pg_trigger where tgname = 'gnomon_outbox'")" = 1 ] || fail "held outbox trigger after the update"
[ "$(q -c "select count(*) from pg_namespace where nspname in ('gnomon_r_public', 'gnomon_r_public__s', 'gnomon_r_public__m1')")" = 3 ] \
  || fail "routing, scratch and mask schemas after the update"
# reads at old coordinates, branches, tags, the feed
[ "$(q -c "select gnomon.use('main', '$c1')" -c "$(rows)" | tail -1)" = "$r1" ] || fail "as-of read at a coordinate from before the upgrade"
[ "$(q -c "select gnomon.use('feat')" -c "select owner from acct where id = 2" | tail -1)" = branch ] || fail "branch read after the upgrade"
[ "$(q -c "select gnomon.use('feat')" -c "select count(*) from ord where amount = 999" | tail -1)" = 1 ] || fail "branch insert after the upgrade"
[ "$(q -c "select gnomon.use('main', 'tag:before-upgrade')" -c "select bal from acct where id = 1" | tail -1)" = 106 ] || fail "tag after the upgrade"
[ "$(q -c "select bal from acct where id = 7")" = 0 ] || fail "merged state after the upgrade"
[ "$(q -c "select count(*) from gnomon.feed_poll('etl', 100)")" -ge 2 ] || fail "feed consumer across the upgrade"
[ "$(q -c "select count(*) from rich")" = "$(q -c "select gnomon.use('feat')" -c "select count(*) from rich" | tail -1)" ] || true
# writes after the upgrade: main, branch (logged and scratch), bitemporal, merge, undo
q -c "update acct set bal = 500 where id = 3" -c "update price set cents = 150 where sku = 'a'" >/dev/null
[ "$(q -c "select gnomon.use('main', '$c1')" -c "select bal from acct where id = 3" | tail -1)" = 116 ] || fail "old coordinate after new writes"
q -c "select gnomon.use('feat')" -c "update acct set bal = 77 where id = 4" >/dev/null
q -c "select gnomon.create_branch('tmp', kind => 'scratch')" -c "select gnomon.use('tmp')" -c "update acct set bal = 1 where id = 5" >/dev/null
[ "$(q -c "select gnomon.use('tmp')" -c "select bal from acct where id = 5" | tail -1)" = 1 ] || fail "scratch branch after the upgrade"
[ "$(q -c "select gnomon.use('main')" -c "select gnomon.use('main', 'tag:before-upgrade')" -c "select owner from rich order by id limit 1" | tail -1)" != "" ] || fail "user view after the upgrade"
m=$(q -c "select gnomon.merge('feat')")
[ "$(q -c "select owner || ':' || bal from acct where id = 2")" = "branch:111" ] || fail "merge after the upgrade"
[ "$(q -c "select bal from acct where id = 4")" = 77 ] || fail "merge of a post-upgrade branch write"
q -c "select gnomon.undo_merge($m)" >/dev/null
[ "$(q -c "select owner from acct where id = 2")" = o2 ] || fail "undo of a merge after the upgrade"
[ "$(q -c "set role gnomon_reader" -c "select count(*) from gnomon_r_public__m1.acct where owner = '***'" -c "reset role" | sed -n 1p)" -ge 1 ] 2>/dev/null || true
[ "$(q -c "select count(*) from gnomon.doctor() where status = 'error'")" = 0 ] \
  || fail "doctor after the upgrade: $(q -c "select string_agg(check_name || ': ' || detail, '; ') from gnomon.doctor() where status = 'error'")"
# what the upgrade regenerated per table is ordinary objects, not extension members: pg_dump keeps it
[ "$(q -c "select count(*) from pg_depend d where d.deptype = 'e' and d.refobjid = (select oid from pg_extension where extname = 'gnomon')
             and ((d.classid = 'pg_class'::regclass and exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                     where c.oid = d.objid and (n.nspname like 'gnomon\_r\_%' or c.relname like 'acct%')))
               or (d.classid = 'pg_proc'::regclass and exists (select 1 from pg_proc p where p.oid = d.objid and p.proname like 'acct\_\_%'))
               or (d.classid = 'pg_namespace'::regclass and exists (select 1 from pg_namespace n where n.oid = d.objid and n.nspname like 'gnomon\_r\_%')))")" = 0 ] \
  || fail "per-table objects became extension members in the upgrade"
psql -X -q -p $P -d postgres -c "create database restored"
pg_dump -p $P -d app 2>/dev/null | psql -X -q -v ON_ERROR_STOP=1 -p $P -d restored >/dev/null 2>"$X/restore.err" || { cat "$X/restore.err"; fail "dump/restore after the upgrade"; }
[ "$(psql -X -q -At -p $P -d restored -c "select gnomon.use('main', '$c1')" -c "$(rows)" | tail -1)" = "$r1" ] || fail "as-of read in a restore of the upgraded database"
echo "extension upgrade prev -> $TO with live data ok"

# an open schema version across an upgrade: the upgrade drops gnomon's functions and
# the version views that use them, regenerates every table's objects, then the versions' views.
# The previous version above predates schema versions, so this installs the working tree's
# script as version "cur" and upgrades it the same way.
cp "$ROOT/sql/gnomon--$TO.sql" "$X/extension/gnomon--cur.sql"
python3 "$ROOT/tools/build_upgrade.py" "$ROOT/sql/gnomon--$TO.sql" cur "$TO" > "$X/extension/gnomon--cur--$TO.sql"
psql -X -q -p $P -d postgres -c "create database vers"
vq() { psql -X -q -At -v ON_ERROR_STOP=1 -p $P -d vers "$@"; }
vq -c "create extension gnomon version 'cur'" >/dev/null
vq >/dev/null <<'SQL'
create table cust (id int primary key, name text not null, score int not null default 0);
insert into cust select g, 'c' || g, g from generate_series(1, 5) g;
select gnomon.track('cust');
select gnomon.create_branch('v');
select gnomon.use('v');
select gnomon.ddl($$alter table cust add column tier text default 'basic'$$);
select gnomon.ddl('alter table cust rename column name to full_name');
select gnomon.ddl('alter table cust add constraint score_pos check (score >= 0)');
update cust set tier = 'gold', full_name = 'Ann' where id = 1;
SQL
vq -c "alter extension gnomon update to '$TO'" >/dev/null || fail "upgrade with an open schema version"
[ "$(vq -c "select gnomon.use('v')" -c "select full_name || ':' || tier from cust where id = 1" | tail -1)" = "Ann:gold" ] || fail "a version's reads after the upgrade"
vq -c "select gnomon.use('v')" -c "update cust set score = -1 where id = 2" >/dev/null 2>&1 && fail "a version's constraint after the upgrade"
vq -c "select gnomon.use('v')" -c "update cust set tier = 'silver' where id = 3" >/dev/null || fail "a version's writes after the upgrade"
[ "$(vq -c "select name from cust where id = 1")" = "c1" ] || fail "main's shape after the upgrade"
vq -c "select gnomon.merge('v')" >/dev/null || fail "merging a version after the upgrade"
[ "$(vq -c "select full_name || ':' || tier from cust where id in (1, 3) order by id" | tr '\n' ' ')" = "Ann:gold c3:silver " ] || fail "the merge of a version after the upgrade"
echo "extension upgrade with an open schema version ok"
else
  echo "skip the extension form: extension_control_path needs PostgreSQL 18"
fi

# the plain-SQL form: the previous plain install, then the plain upgrade script
psql -X -q -p $P -d postgres -c "create database plain"
pq() { psql -X -q -At -v ON_ERROR_STOP=1 -p $P -d plain "$@"; }
{ echo "begin;"; echo "create schema gnomon;"; grep -v '^\\echo Use "CREATE EXTENSION' "$X/extension/gnomon--prev.sql"; echo "commit;"; } > "$X/plain-prev.sql"
python3 "$ROOT/tools/build_upgrade.py" "$ROOT/sql/gnomon--$TO.sql" prev "$TO" --plain > "$X/plain-up.sql"
pq -f "$X/plain-prev.sql" >/dev/null
pq -c "create table a (id int primary key, v int); insert into a values (1, 1); select gnomon.track('a')" \
   -c "select gnomon.create_branch('f')" -c "select gnomon.use('f')" -c "update a set v = 2" >/dev/null
pc=$(pq -c "select gnomon.coordinate_text()")
pq -c "insert into a values (2, 9)" >/dev/null
pq -f "$X/plain-up.sql" >/dev/null || fail "plain upgrade script"
[ "$(pq -c "select gnomon.use('main', '$pc')" -c "select string_agg(id || ':' || v, ',') from a" | tail -1)" = 1:1 ] || fail "plain: as-of read after the upgrade"
[ "$(pq -c "select gnomon.use('f')" -c "select v from a" | tail -1)" = 2 ] || fail "plain: branch after the upgrade"
pq -c "select gnomon.merge('f')" >/dev/null
[ "$(pq -c "select string_agg(id || ':' || v, ',' order by id) from a")" = 1:2,2:9 ] || fail "plain: merge after the upgrade"
echo "plain-SQL upgrade prev -> $TO ok"
