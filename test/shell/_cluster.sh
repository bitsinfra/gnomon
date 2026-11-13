# Helpers for shell tests that need clusters of their own (standby, failover, pg_upgrade, logical
# replication). Each cluster lives in build/tc-<name> with its socket in build/, and is stopped and
# removed when the test exits.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export LC_ALL=${LC_ALL:-en_US.UTF-8} PGHOST=$ROOT/build PGUSER=postgres
TC_DIRS=()
# tc_rmshm <datadir>: a postmaster killed with SIGKILL leaves its System V segment behind, and a
# restart in the same directory is what normally removes it. Before a dead cluster's directory goes,
# remove the segment named on line 7 of its postmaster.pid (key and id), if it is still that key's
# and nothing is attached: macOS allows only a few dozen, and a long run of kill -9 tests used them up.
tc_rmshm() {
  local d=$1 key id
  [ -f "$d/postmaster.pid" ] || return 0
  read -r key id < <(sed -n 7p "$d/postmaster.pid") || return 0
  [ -n "${id:-}" ] || return 0
  kill -0 "$(head -1 "$d/postmaster.pid")" 2>/dev/null && return 0   # still running: not ours to touch
  if [ "$(uname)" = Darwin ]; then
    ipcs -m -a 2>/dev/null | awk -v id="$id" -v key="$(printf '0x%08x' "$key")" '$1 == "m" && $2 == id && $3 == key && $9 == 0 {f = 1} END {exit !f}' || return 0
  else
    ipcs -m 2>/dev/null | awk -v id="$id" -v key="$(printf '0x%08x' "$key")" '$2 == id && $1 == key && $6 == 0 {f = 1} END {exit !f}' || return 0
  fi
  ipcrm -m "$id" 2>/dev/null || true
}
tc_cleanup() {
  local d
  for d in ${TC_DIRS[@]+"${TC_DIRS[@]}"}; do
    [ -f "$d/postmaster.pid" ] && "${TC_BIN:-$(pg_config --bindir)}/pg_ctl" -D "$d" -m immediate stop >/dev/null 2>&1 || true
    tc_rmshm "$d"
    [ -n "${TC_KEEP:-}" ] || rm -rf "$d" "$d.log"
  done
}
trap tc_cleanup EXIT
fail() { echo "FAILED: $*"; exit 1; }

# tc_init <name> <port> [bindir] [extra conf...]: initdb and start a cluster; prints its data dir.
tc_init() {
  local name=$1 port=$2 bin=${3:-$(pg_config --bindir)}; shift 3 || shift $#
  local d=$ROOT/build/tc-$name
  [ -f "$d/postmaster.pid" ] && "$bin/pg_ctl" -D "$d" -m immediate stop >/dev/null 2>&1 || true
  tc_rmshm "$d"
  rm -rf "$d" "$d.log"
  # PostgreSQL 18 initdb turns data checksums on by default; older servers do not (pg_upgrade
  # wants them to match)
  "$bin/initdb" -U postgres -A trust --no-sync ${TC_INITDB_OPTS:-} -D "$d" >/dev/null
  tc_conf "$d" "port = $port" "$@"
  TC_DIRS+=("$d")
  [ -n "${TC_NOSTART:-}" ] || "$bin/pg_ctl" -D "$d" -l "$d.log" -w start >/dev/null || { tail -20 "$d.log"; return 1; }
}

# tc_conf <datadir> [lines...]: the common settings plus extra lines.
tc_conf() {
  local d=$1; shift
  cat >> "$d/postgresql.conf" <<CONF
unix_socket_directories = '$ROOT/build'
listen_addresses = ''
wal_level = logical
max_wal_senders = 10
max_replication_slots = 10
log_min_messages = warning
CONF
  # extension_control_path (the dev build's extension files) exists from PostgreSQL 18 on
  if [ "$(cat "$d/PG_VERSION")" -ge 18 ]; then
    printf "extension_control_path = '%s/build/ext:\$system'\ndynamic_library_path = '%s/build/lib:\$libdir'\n" "$ROOT" "$ROOT" >> "$d/postgresql.conf"
  fi
  local l
  for l in "$@"; do printf '%s\n' "$l" >> "$d/postgresql.conf"; done
}

# tc_standby <name> <port> <primary port> [extra conf...]: a streaming standby of a running cluster.
tc_standby() {
  local name=$1 port=$2 pport=$3; shift 3
  local d=$ROOT/build/tc-$name bin=${TC_BIN:-$(pg_config --bindir)}
  tc_rmshm "$d"
  rm -rf "$d" "$d.log"
  "$bin/pg_basebackup" -h "$ROOT/build" -p "$pport" -U postgres -D "$d" -R -X stream -c fast \
    --create-slot --slot "slot_${name//-/_}" >/dev/null
  # postgresql.auto.conf is read last and pg_basebackup -R wrote its own primary_conninfo there:
  # override it in the same file (the later entry wins), with an application_name to match
  # synchronous_standby_names
  # a standby has no synchronous standbys of its own: once promoted, it must not wait for one
  printf "port = %s\nprimary_slot_name = %s\nsynchronous_standby_names = ''\n" "$port" "slot_${name//-/_}" >> "$d/postgresql.auto.conf"
  printf "primary_conninfo = 'host=%s port=%s user=postgres application_name=%s'\n" "$ROOT/build" "$pport" "$name" >> "$d/postgresql.auto.conf"
  local l
  for l in "$@"; do printf '%s\n' "$l" >> "$d/postgresql.auto.conf"; done
  TC_DIRS+=("$d")
  "$bin/pg_ctl" -D "$d" -l "$d.log" -w start >/dev/null || { tail -20 "$d.log"; return 1; }
}

tc_dir() { echo "$ROOT/build/tc-$1"; }
