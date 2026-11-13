#!/usr/bin/env bash
# The plain-SQL install form installs and works without CREATE EXTENSION.
source "$(dirname "$0")/_lib.sh"
"$ROOT/tools/build_install_forms.sh" >/dev/null
# the version in the control file, so older builds left in build/dist are ignored
V=$(sed -n "s/^default_version = '\(.*\)'/\1/p" "$ROOT/gnomon.control")
P=gts_plain
psql -X -q -d postgres -c "drop database if exists $P" -c "create database $P" >/dev/null 2>&1
psql -X -q -v ON_ERROR_STOP=1 -d $P -c "set client_min_messages=warning" -f "$ROOT/build/dist/gnomon-plain--$V.sql" >/dev/null || fail "plain install failed"
p() { psql -X -q -At -v ON_ERROR_STOP=1 -d $P "$@"; }
[ "$(p -c "select count(*) from pg_extension where extname = 'gnomon'")" = 0 ] || fail "should not be an extension"
p -c "create table a (id int primary key, v int); insert into a values (1, 1); select gnomon.track('a')" >/dev/null
p -c "select gnomon.create_branch('f')" >/dev/null
p -c "select gnomon.use('f')" -c "update a set v = 2" >/dev/null
[ "$(p -c "select v from a")" = 1 ] || fail "main changed"
p -c "select gnomon.merge('f')" >/dev/null
[ "$(p -c "select v from a")" = 2 ] || fail "merge"
grep -q "pgtle.install_extension('gnomon'" "$ROOT/build/dist/gnomon-pgtle--$V.sql" || fail "pg_tle package"
psql -X -q -d postgres -c "drop database $P" >/dev/null 2>&1
echo ok
