#!/bin/bash
# First start: gnomon in each database of GNOMON_DATABASES (comma separated), and the C module's
# heartbeat worker ticking them. An image built without the C module (or GNOMON_C_MODULE=off)
# gets the SQL core alone, ticked by `gnomon daemon` or pg_cron instead.
set -euo pipefail
dbs=${GNOMON_DATABASES:-${POSTGRES_DB:-postgres}}
cmod=${GNOMON_C_MODULE:-on}
if [ "$cmod" != off ] && ! psql --username "$POSTGRES_USER" -d postgres -Atc "select 1 from pg_available_extensions where name = 'gnomon_c'" | grep -q 1; then
  echo "gnomon: the C module is not in this image; the SQL core alone" >&2
  cmod=off
fi
for db in ${dbs//,/ }; do
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -d postgres -tc "select 1 from pg_database where datname = '$db'" | grep -q 1 \
    || psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -d postgres -c "create database \"$db\""
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -d "$db" -c "create extension if not exists gnomon cascade"
  if [ "$cmod" != off ]; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -d "$db" -c "create extension if not exists gnomon_c"
  fi
done
if [ "$cmod" != off ]; then
  echo "gnomon.heartbeat_databases = '${dbs}'" >> "$PGDATA/postgresql.auto.conf"
fi
