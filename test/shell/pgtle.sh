#!/usr/bin/env bash
# The pg_tle package: on a server with pg_tle (RDS and Aurora ship it;
# locally it is built from github.com/aws/pg_tle), install gnomon with pgtle.install_extension and
# CREATE EXTENSION, then track, branch, merge and read the past. Skipped where pg_tle is missing.
source "$(dirname "$0")/_cluster.sh"
BIN=$(pg_config --bindir)
if [ ! -f "$(pg_config --sharedir)/extension/pg_tle.control" ]; then
  echo "skip: pg_tle is not installed in this server (see test/shell/pgtle.sh)"
  exit 0
fi
# pg_tle refuses a TLE named like an extension installed as files on the server, as on a provider
# none is: this test needs a server without gnomon's own files (make uninstall)
if [ -f "$(pg_config --sharedir)/extension/gnomon.control" ]; then
  echo "skip: gnomon is installed as files in this server; pg_tle refuses a TLE of the same name (make uninstall PG_CONFIG=...)"
  exit 0
fi
"$ROOT/tools/build_install_forms.sh" >/dev/null
P=54347
EXTRA=()   # (PostgreSQL 18: only the server's own extension files, not the dev build's)
[ "$(pg_config --version | sed 's/[^0-9]*\([0-9]*\).*/\1/')" -ge 18 ] && EXTRA=("extension_control_path = '\$system'")
tc_init pgtle $P "" "shared_preload_libraries = 'pg_tle'" ${EXTRA[@]+"${EXTRA[@]}"}
psql -X -q -p $P -d postgres -c "create database app" >/dev/null
q() { psql -X -q -At -v ON_ERROR_STOP=1 -p $P -d app "$@"; }
export PGOPTIONS='-c client_min_messages=warning'
q -c "create extension pg_tle" >/dev/null
# a role that may install TLEs (on RDS: the master user, a member of pgtle_admin)
GN_VERSION=$(sed -n "s/^default_version = '\(.*\)'/\1/p" "$ROOT/gnomon.control")
q -f "$ROOT/build/dist/gnomon-pgtle--$GN_VERSION.sql" >/dev/null || fail "pgtle.install_extension"
[ "$(q -c "select count(*) from pgtle.available_extensions() where name = 'gnomon'")" = 1 ] || fail "gnomon not available as a TLE"
q -c "create extension gnomon" >/dev/null || fail "create extension gnomon from the pg_tle package"
[ "$(q -c "select extversion from pg_extension where extname = 'gnomon'")" = "$(sed -n "s/^default_version = '\(.*\)'/\1/p" "$ROOT/gnomon.control")" ] \
  || fail "extension version"
q >/dev/null <<'SQL'
create table acct (id int primary key, owner text not null, bal int not null default 0);
insert into acct select g, 'o' || g, 100 from generate_series(1, 10) g;
select gnomon.track('acct');
update acct set bal = bal + 1 where id <= 3;
SQL
c1=$(q -c "select gnomon.coordinate_text()")
q -c "update acct set bal = 0 where id = 1" >/dev/null
q -c "select gnomon.create_branch('feat')" >/dev/null
q -c "select gnomon.use('feat')" -c "update acct set owner = 'branch' where id = 2" >/dev/null
[ "$(q -c "select owner from acct where id = 2")" = o2 ] || fail "main changed by a branch write"
[ "$(q -c "select gnomon.use('feat')" -c "select owner from acct where id = 2" | tail -1)" = branch ] || fail "branch read"
q -c "select gnomon.merge('feat')" >/dev/null
[ "$(q -c "select owner from acct where id = 2")" = branch ] || fail "merge"
[ "$(q -c "select gnomon.use('main', '$c1')" -c "select bal from acct where id = 1" | tail -1)" = 101 ] || fail "as-of read"
[ "$(q -c "select count(*) from gnomon.changes('$c1')")" -ge 2 ] || fail "change feed"
[ "$(q -c "select count(*) from pg_event_trigger where evtname like 'gnomon%'")" = 2 ] || fail "event triggers"
# DDL is followed (event triggers), and the extension drops cleanly
q -c "alter table acct add column note text" -c "select gnomon.use('feat')" -c "update acct set note = 'x' where id = 3" >/dev/null || fail "write after DDL"
q -c "drop extension gnomon cascade" >/dev/null || fail "drop extension"
q -c "select pgtle.uninstall_extension('gnomon')" >/dev/null || fail "uninstall the TLE"
echo "pg_tle package ok"
