#!/usr/bin/env bash
# Upgrade scripts from an older version to the one in gnomon.control (src/upgrade/README.md):
#   tools/build_upgrade.sh <old version>
#     sql/gnomon--<old>--<new>.sql             for ALTER EXTENSION gnomon UPDATE (make install ships it)
#     build/dist/gnomon-plain--<old>--<new>.sql for the plain-SQL install form (psql -f)
# Every migration in src/upgrade is idempotent, so the scripts work from any older version.
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -eq 1 ] || { echo "usage: $0 <old version>" >&2; exit 2; }
OLD=$1
NEW=$(sed -n "s/^default_version = '\(.*\)'/\1/p" gnomon.control)
[ "$OLD" != "$NEW" ] || { echo "the old version must differ from $NEW" >&2; exit 2; }
make -s "sql/gnomon--$NEW.sql"
mkdir -p build/dist
python3 tools/build_upgrade.py "sql/gnomon--$NEW.sql" "$OLD" "$NEW" > "sql/gnomon--$OLD--$NEW.sql"
python3 tools/build_upgrade.py "sql/gnomon--$NEW.sql" "$OLD" "$NEW" --plain > "build/dist/gnomon-plain--$OLD--$NEW.sql"
# Register both the new full version and its upgrade path in an existing pg_tle installation.
{
  echo "begin;"
  echo "select pgtle.install_extension_version_sql('gnomon', '$NEW', \$_gnomon_pgtle_\$"
  grep -v '^\\echo ' "sql/gnomon--$NEW.sql"
  echo "\$_gnomon_pgtle_\$);"
  echo "select pgtle.install_update_path('gnomon', '$OLD', '$NEW', \$_gnomon_pgtle_\$"
  grep -v '^\\echo ' "sql/gnomon--$OLD--$NEW.sql"
  echo "\$_gnomon_pgtle_\$);"
  echo "select pgtle.set_default_version('gnomon', '$NEW');"
  # pg_tle executes the registered update in its function's configuration scope.
  # Save outbox channels in the outer transaction, then regenerate ordinary routing
  # objects after ALTER EXTENSION so that pg_dump continues to include them.
  cat <<'SQL'
select set_config('gnomon._up_outbox', coalesce(jsonb_agg(jsonb_build_object(
  'rel', tgrelid::regclass::text,
  'channel', convert_from(substring(tgargs from 1 for position('\x00'::bytea in tgargs) - 1), 'UTF8'))), '[]')::text, true)
from pg_trigger where tgname = 'gnomon_outbox';
SQL
  echo "alter extension gnomon update to '$NEW';"
  echo "select _gnomon.upgrade_regenerate();"
  echo "commit;"
} > "build/dist/gnomon-pgtle--$OLD--$NEW.sql"
ls -la "sql/gnomon--$OLD--$NEW.sql" "build/dist/gnomon-plain--$OLD--$NEW.sql" "build/dist/gnomon-pgtle--$OLD--$NEW.sql"
