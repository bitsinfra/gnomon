#!/usr/bin/env bash
# The SDKs' conformance scenarios behind a connection pooler in transaction mode
# (gnomon-txpool: a server connection per transaction, shared between clients with no session
# reset, startup options dropped, as pgbouncer's transaction mode). The envelope begins every
# transaction with gnomon.begin, so nothing depends on a session. Skipped without Node or the
# Python environment.
source "$(dirname "$0")/_lib.sh"
command -v node >/dev/null || { echo "skip: no node"; exit 0; }
[ -x "$ROOT/build/venv/bin/python" ] || { echo "skip: no build/venv"; exit 0; }
(cd "$ROOT/cli" && go build -o "$ROOT/build/gnomon-txpool" ./cmd/gnomon-txpool)
PPORT=${POOLER_PORT:-54390}
"$ROOT/build/gnomon-txpool" -listen 127.0.0.1:$PPORT -server "host=$PGHOST port=$PGPORT" -size 2 2>"$ROOT/build/txpool.log" &
PID=$!
trap 'kill $PID 2>/dev/null; psql -X -q -d postgres -c "drop database if exists $DB" >/dev/null 2>&1 || true' EXIT
for i in $(seq 1 50); do psql -X -q -h 127.0.0.1 -p $PPORT -d postgres -c 'select 1' >/dev/null 2>&1 && break; sleep 0.1; done
# a session setting does not survive: the next transaction may get another server (or this one, reset by nobody)
psql -X -q -h 127.0.0.1 -p $PPORT -d "$DB" -c "create table pt (id int primary key, v int)" -c "insert into pt values (1, 1)" -c "select gnomon.track('pt')" -c "select gnomon.create_branch('pb')" >/dev/null
[ "$(psql -X -At -h 127.0.0.1 -p $PPORT -d "$DB" -c "begin" -c "select gnomon.begin('pb')" -c "update pt set v = 2 where id = 1" -c "commit" | tail -1)" = COMMIT ] || fail "a transaction on a branch through the pooler"
[ "$(psql -X -At -h 127.0.0.1 -p $PPORT -d "$DB" -c "select v from pt where id = 1")" = 1 ] || fail "main through the pooler"
# The pytest plugin registers itself when the package is installed in build/venv; naming it with
# -p as well would register the same module twice, which pytest refuses.
PYP=$("$ROOT/build/venv/bin/python" -c "import importlib.metadata as m; print('' if any(e.name == 'gnomon' for e in m.entry_points(group='pytest11')) else '-p gnomon.pytest_plugin')")
(cd "$ROOT/sdk/ts" && GNOMON_SDK_HOST=127.0.0.1 GNOMON_SDK_PORT=$PPORT GNOMON_SDK_POOLED=1 node --test test/conformance.test.ts test/run.test.ts) >"$ROOT/build/test-out/pooler_ts.out" 2>&1 \
  || { tail -30 "$ROOT/build/test-out/pooler_ts.out"; fail "the TypeScript SDK behind the pooler"; }
GNOMON_SDK_HOST=127.0.0.1 GNOMON_SDK_PORT=$PPORT PYTHONPATH="$ROOT/integrations/python" "$ROOT/build/venv/bin/python" -m pytest -q $PYP \
  "$ROOT/integrations/python/tests/test_sdk.py" >"$ROOT/build/test-out/pooler_py.out" 2>&1 \
  || { tail -30 "$ROOT/build/test-out/pooler_py.out"; fail "the Python SDK behind the pooler"; }

# the same behind pgbouncer itself, in transaction mode, when it is installed
if command -v pgbouncer >/dev/null; then
  B=$ROOT/build/pgbouncer; BPORT=${PGBOUNCER_PORT:-54394}
  rm -rf "$B"; mkdir -p "$B"
  # trust on the server's socket: pgbouncer takes any role the server has (auth_query through
  # auth_user) and logs in as it, so the runs login stays itself
  printf '"postgres" ""\n' > "$B/userlist.txt"
  cat > "$B/pgbouncer.ini" <<INI
[databases]
* = host=$PGHOST port=$PGPORT
[pgbouncer]
listen_addr = 127.0.0.1
listen_port = $BPORT
unix_socket_dir =
auth_type = trust
auth_file = $B/userlist.txt
auth_user = postgres
pool_mode = transaction
default_pool_size = 4
max_client_conn = 500
ignore_startup_parameters = extra_float_digits,options
logfile = $B/pgbouncer.log
pidfile = $B/pgbouncer.pid
INI
  pgbouncer -d "$B/pgbouncer.ini"
  trap 'kill $PID 2>/dev/null; [ -f "$B/pgbouncer.pid" ] && kill "$(cat "$B/pgbouncer.pid")" 2>/dev/null; psql -X -q -d postgres -c "drop database if exists $DB" >/dev/null 2>&1 || true' EXIT
  for i in $(seq 1 50); do psql -X -q -h 127.0.0.1 -p $BPORT -d postgres -c 'select 1' >/dev/null 2>&1 && break; sleep 0.1; done
  [ "$(psql -X -At -h 127.0.0.1 -p $BPORT -d "$DB" -c "begin" -c "select gnomon.begin('pb')" -c "update pt set v = 3 where id = 1" -c "commit" | tail -1)" = COMMIT ] || fail "a transaction on a branch through pgbouncer"
  [ "$(psql -X -At -h 127.0.0.1 -p $BPORT -d "$DB" -c "select v from pt where id = 1")" = 1 ] || fail "main through pgbouncer"
  (cd "$ROOT/sdk/ts" && GNOMON_SDK_HOST=127.0.0.1 GNOMON_SDK_PORT=$BPORT GNOMON_SDK_POOLED=1 \
     node --test test/conformance.test.ts test/run.test.ts) >"$ROOT/build/test-out/pgbouncer_ts.out" 2>&1 \
    || { tail -30 "$ROOT/build/test-out/pgbouncer_ts.out"; fail "the TypeScript SDK behind pgbouncer"; }
  GNOMON_SDK_HOST=127.0.0.1 GNOMON_SDK_PORT=$BPORT PYTHONPATH="$ROOT/integrations/python" "$ROOT/build/venv/bin/python" -m pytest -q $PYP \
    "$ROOT/integrations/python/tests/test_sdk.py" >"$ROOT/build/test-out/pgbouncer_py.out" 2>&1 \
    || { tail -30 "$ROOT/build/test-out/pgbouncer_py.out"; fail "the Python SDK behind pgbouncer"; }
  echo "pgbouncer $(pgbouncer --version | head -1 | awk '{print $2}'): ok"
else
  echo "skip pgbouncer: not installed"
fi
echo ok
