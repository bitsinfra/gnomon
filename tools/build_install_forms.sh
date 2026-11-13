#!/usr/bin/env bash
# Build the other install forms from sql/gnomon--<version>.sql:
#   build/dist/gnomon-plain--<v>.sql   plain SQL, for providers that allow neither custom
#                                      extensions nor pg_tle: psql -f it as a superuser-like role
#   build/dist/gnomon-pgtle--<v>.sql   a pg_tle package (RDS, Aurora; Supabase via database.dev)
set -euo pipefail
cd "$(dirname "$0")/.."
V=$(sed -n "s/^default_version = '\(.*\)'/\1/p" gnomon.control)
make -s sql/gnomon--$V.sql
mkdir -p build/dist
SRC=sql/gnomon--$V.sql
{
  echo "-- gnomon $V, plain SQL install (no CREATE EXTENSION). Run once per database:"
  echo "--   psql -v ON_ERROR_STOP=1 -f gnomon-plain--$V.sql"
  echo "-- Upgrades: apply gnomon-plain--<old>--<new>.sql scripts in order."
  echo "begin;"
  echo "create schema gnomon;"
  grep -v '^\\echo Use "CREATE EXTENSION' "$SRC"
  echo "insert into gnomon.setting_default values ('install_form', 'plain', 'Installed from the plain SQL script.') on conflict do nothing;"
  echo "commit;"
} > build/dist/gnomon-plain--$V.sql
{
  echo "-- gnomon $V as a pg_tle package. As a role that may run pgtle.install_extension:"
  echo "--   psql -f gnomon-pgtle--$V.sql && psql -c 'create extension gnomon'"
  echo "-- pg_tle cannot load the C module; this is the SQL core. Event triggers need a role that may"
  echo "-- create them; without it gnomon falls back to fingerprint checks (run gnomon.sync() after DDL)."
  echo "select pgtle.install_extension('gnomon', '$V',"
  echo "  'Version history, time travel, branches and three-way merges for PostgreSQL tables',"
  echo "\$_gnomon_pgtle_\$"
  grep -v '^\\echo Use "CREATE EXTENSION' "$SRC"
  # (the schema, as gnomon.control's schema = gnomon: CREATE EXTENSION creates it; pg_tle 1.4+)
  echo "\$_gnomon_pgtle_\$, schema => 'gnomon');"
} > build/dist/gnomon-pgtle--$V.sql
ls -la build/dist
