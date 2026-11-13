#!/usr/bin/env bash
# A throwaway PostgreSQL cluster in build/pgdata for development and tests.
#   tools/devcluster.sh start|stop|restart|status [pg_bin_dir]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
export LC_ALL=${LC_ALL:-en_US.UTF-8}
BIN=${PGBIN:-$(pg_config --bindir)}
DATA=${PGDATA_DIR:-$ROOT/build/pgdata}
PORT=${PGPORT:-54329}
case "${1:-start}" in
  start)
    if [ ! -f "$DATA/PG_VERSION" ]; then
      mkdir -p "$ROOT/build/ext/extension" "$ROOT/build/lib"
      "$BIN/initdb" -U postgres -A trust --no-sync -D "$DATA" >/dev/null
      cat >> "$DATA/postgresql.conf" <<CONF
port = $PORT
unix_socket_directories = '$ROOT/build'
listen_addresses = ''
max_connections = 200
shared_buffers = 256MB
fsync = off
synchronous_commit = off
full_page_writes = off
wal_level = logical
max_locks_per_transaction = 256
log_min_messages = warning
CONF
      # PostgreSQL 18 finds the dev build in build/ext; older servers need `make install`
      if [ "$(cat "$DATA/PG_VERSION")" -ge 18 ]; then
        printf "extension_control_path = '%s/build/ext:\$system'\ndynamic_library_path = '%s/build/lib:\$libdir'\n" "$ROOT" "$ROOT" >> "$DATA/postgresql.conf"
      fi
      [ -n "${EXTRA_CONF:-}" ] && printf '%s\n' "$EXTRA_CONF" >> "$DATA/postgresql.conf"
    fi
    if ! "$BIN/pg_ctl" -D "$DATA" status >/dev/null 2>&1; then
      "$BIN/pg_ctl" -D "$DATA" -l "$DATA.log" -w start >/dev/null
    fi
    echo "running on $ROOT/build:$PORT";;
  stop) "$BIN/pg_ctl" -D "$DATA" -m fast stop;;
  restart) "$BIN/pg_ctl" -D "$DATA" -m fast -l "$DATA.log" -w restart;;
  status) "$BIN/pg_ctl" -D "$DATA" status;;
esac
