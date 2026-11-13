#!/usr/bin/env bash
# The tutorial (docs/tutorial.md) end to end, as written, against a database seeded with
# examples/shop.sql. Every step runs as one of the example's logins, none of them a superuser.
#   PGHOST=... PGPORT=... examples/tutorial.sh [database]
# GNOMON: the CLI (default: gnomon on PATH). The dev cluster: tools/devcluster.sh start.
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${1:-shop}
GNOMON=${GNOMON:-gnomon}
HOST=${PGHOST:-localhost} PORT=${PGPORT:-5432}
dsn() { echo "host=$HOST port=$PORT dbname=$DB user=$1"; }
APP=$(dsn shop_app) REVIEWER=$(dsn shop_reviewer) OPS=$(dsn shop_ops)
say() { printf '\n== %s\n' "$*"; }
check() { [ "$1" = "$2" ] || { echo "FAILED: $3 (got '$1', expected '$2')" >&2; exit 1; }; }

say "Part 1: tests on branches"
if [ -n "${PYTHON:-}" ]; then
  # PYTHON has gnomon-postgres installed, which registers the pytest plugin by itself
  GNOMON_TEST_DSN="$APP" "$PYTHON" -m pytest -q examples/tests
else
  echo "(set PYTHON to a Python with gnomon-postgres and pytest installed to run examples/tests)"
fi

say "Part 2: a reviewed data change"
"$GNOMON" --dsn "$APP" branch create price-fix
"$GNOMON" --dsn "$APP" --branch price-fix sql "update products set price = price * 1.10 where id <= 5"
"$GNOMON" --dsn "$APP" diff price-fix
check "$(psql -X -At "$APP" -c 'select price from products where id = 1')" "1.50" "main is unchanged"
cr=$("$GNOMON" --dsn "$APP" --json cr open price-fix "Raise five prices by 10%" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if isinstance(d, list) else d["id"])')
echo "change request $cr"
if "$GNOMON" --dsn "$APP" cr review "$cr" approve 2>/dev/null; then echo "FAILED: the author approved" >&2; exit 1; fi
"$GNOMON" --dsn "$REVIEWER" cr review "$cr" approve "looks right"
"$GNOMON" --dsn "$REVIEWER" merge price-fix --preview
mid=$("$GNOMON" --dsn "$REVIEWER" --json merge price-fix | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if isinstance(d, list) else d["id"])')
check "$(psql -X -At "$APP" -c 'select price from products where id = 1')" "1.65" "the merge reached main"
"$GNOMON" --dsn "$APP" log --limit 5
"$GNOMON" --dsn "$REVIEWER" undo --merge "$mid"
check "$(psql -X -At "$APP" -c 'select price from products where id = 1')" "1.50" "the undo"

say "Part 3: an agent on a role"
out=$("$GNOMON" --dsn "$OPS" agent create support)
printf '%s\n' "$out" | sed -n '1,3p'
agent=$(echo "$out" | sed -n '2p' | sed 's/^ *//')
# the agent knows nothing of gnomon: a plain connection string, plain SQL
psql -X -q "$agent" -c "update orders set status = 'refunded' where id = 7"
check "$(psql -X -At "$agent" -c 'select status from orders where id = 7')" "refunded" "the agent sees its write"
check "$(psql -X -At "$APP" -c 'select status from orders where id = 7')" "new" "main does not"
if psql -X -q "$agent" -c "update public.orders set status = 'x' where id = 8" 2>/dev/null; then echo "FAILED: the agent wrote main" >&2; exit 1; fi
if psql -X -q "$agent" -c "select gnomon.merge('support/1')" 2>/dev/null; then echo "FAILED: the agent merged" >&2; exit 1; fi
psql -X -At "$agent" -c "select gnomon.done('Refunded order 7: the customer returned it')"
"$GNOMON" --dsn "$REVIEWER" cr list
"$GNOMON" --dsn "$REVIEWER" diff support/1
acr=$(psql -X -At "$REVIEWER" -c "select id from gnomon.change_request where branch = (select id from gnomon.branch where name = 'support/1') order by id desc limit 1")
"$GNOMON" --dsn "$REVIEWER" cr review "$acr" approve
"$GNOMON" --dsn "$REVIEWER" merge support/1
check "$(psql -X -At "$APP" -c 'select status from orders where id = 7')" "refunded" "the agent's change reached main"
"$GNOMON" --dsn "$APP" blame orders '{"id": 7}' | sed -n '1,5p'
"$GNOMON" --dsn "$OPS" agent stop support

say "done"
