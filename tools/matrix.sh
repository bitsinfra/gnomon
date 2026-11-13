#!/usr/bin/env bash
# The test matrix for one PostgreSQL major version (15-18), on this machine:
#   tools/matrix.sh 15|16|17|18 [bindir]
# Installs gnomon and gnomon_c into that server (make install), starts two clusters of its own
# (SQL core; C module preloaded), and runs the whole suite on each, the C module's tests too.
# The install goes into that version's own directories, so when it is also the PostgreSQL on PATH
# the dev clusters see it too (they search build/ first). Undo the install with
#   make uninstall PG_CONFIG=<bindir>/pg_config; make -C build/c<v> uninstall PG_CONFIG=...
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
export LC_ALL=${LC_ALL:-en_US.UTF-8}
V=$1
BIN=${2:-/opt/homebrew/opt/postgresql@$V/bin}
PGC=$BIN/pg_config
[ -x "$PGC" ] || { echo "no PostgreSQL $V in $BIN" >&2; exit 2; }
make -s "sql/gnomon--$(sed -n "s/^default_version = '\(.*\)'/\1/p" gnomon.control).sql"
make -s install PG_CONFIG="$PGC" >/dev/null
rm -rf "build/c$V"; mkdir -p "build/c$V"
cp src/c/gnomon_c.c src/c/Makefile src/c/gnomon_c.control src/c/gnomon_c--*.sql "build/c$V/"
make -s -C "build/c$V" PG_CONFIG="$PGC" >/dev/null 2>&1
make -s -C "build/c$V" install PG_CONFIG="$PGC" >/dev/null
export PATH=$BIN:$PATH PGHOST=$ROOT/build PGUSER=postgres
SQLPORT=$((54400 + V)) CPORT=$((54500 + V))
echo "== PostgreSQL $("$BIN/postgres" --version | awk '{print $3}'): SQL core (port $SQLPORT)"
PGBIN=$BIN PGDATA_DIR=$ROOT/build/pgdata-m$V PGPORT=$SQLPORT tools/devcluster.sh start >/dev/null
rc=0
GNOMON_EXTERNAL=1 PGPORT=$SQLPORT ./test/run.sh || rc=1
echo "== PostgreSQL $V: C module (port $CPORT)"
EXTRA_CONF="shared_preload_libraries = 'gnomon_c'
gnomon.heartbeat_databases = 'gc_worker'
gnomon.heartbeat_interval = 200" PGBIN=$BIN PGDATA_DIR=$ROOT/build/pgdata-m$V-c PGPORT=$CPORT tools/devcluster.sh start >/dev/null
GNOMON_SKIP_BUILD=1 C_PGDATA=$ROOT/build/pgdata-m$V-c CPORT=$CPORT PGBIN=$BIN src/c/test/run.sh || rc=1
PGBIN=$BIN PGDATA_DIR=$ROOT/build/pgdata-m$V-c tools/devcluster.sh stop >/dev/null 2>&1 || true
PGBIN=$BIN PGDATA_DIR=$ROOT/build/pgdata-m$V tools/devcluster.sh stop >/dev/null 2>&1 || true
exit $rc
