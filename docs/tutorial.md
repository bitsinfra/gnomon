# Tutorial

Three ten-minute paths, each a way gnomon is used: tests on branches, a reviewed data change,
and an agent on a role. They run against one example database, and every step runs as an ordinary
login: the application's, a reviewer's, or an operator's. None is a superuser.
[`examples/tutorial.sh`](../examples/tutorial.sh) runs all of it, with checks, and is how this page
is kept true.

## Setup

You need PostgreSQL 15-18 with gnomon installed (`make install`, the container image in
`docker/`, or the plain-SQL form; see the README), and the `gnomon` CLI (`cd cli && go build -o
gnomon ./cmd/gnomon`, or a released binary).

Create the example database as a superuser, once:

```bash
createdb shop
```

```bash
psql -d shop -f examples/shop.sql
```

[`shop.sql`](../examples/shop.sql) installs gnomon, creates `customers`, `products`, `orders` and
`order_items` with some rows, tracks them (`gnomon.track_schema('public')`), and makes four logins:

| Login | Has | Plays |
|---|---|---|
| `shop_app` | table grants, and `gnomon_runner` and `gnomon_merger` for the SDKs' runs | the application and its tests |
| `shop_reviewer` | table grants and `gnomon_merger` | a person who reviews and merges |
| `shop_ops` | `gnomon_admin` and `gnomon_merger` | whoever hands work to agents |
| `shop_runs` | nothing: confined to the run each transaction is bound to | the runs login every SDK run shares ([sdk.md](sdk.md)) |

Tracking adds no backfill and changes nothing for the application: its queries on main read the
same tables with the same plans. For reads by time, run a heartbeat (`gnomon daemon`, the C
module's worker, or pg_cron); this tutorial does not need one.

Below, `$APP`, `$REVIEWER` and `$OPS` stand for the first three logins' connection strings, for
example `APP="dbname=shop user=shop_app"`.

## 1. Tests on branches

Each test gets a scratch branch of the seeded database: tests see the seed, never each other's
writes, and nothing reaches main. They can run in parallel against one database.

```python
# examples/tests/test_orders.py
def test_cancel_puts_items_back(gnomon_conn):          # a psycopg connection on a fresh branch
    before = gnomon_conn.execute("select stock from products where id = 8").fetchone()[0]
    cancel(gnomon_conn, 1)
    assert gnomon_conn.execute("select stock from products where id = 8").fetchone()[0] == before + 2

def test_what_cancel_changes(gnomon_conn, gnomon_snapshot):
    cancel(gnomon_conn, 2)
    gnomon_snapshot.assert_match(gnomon_conn)           # the branch's diff against a stored file
```

```bash
pip install gnomon-postgres pytest
```

```bash
GNOMON_TEST_DSN="$APP" pytest examples/tests
```

The snapshot is the branch's changes, one line per field, with generated keys replaced by
placeholders so it is stable between runs:

```
public.orders <orders:1> update status: "new" -> "cancelled"
public.products <products:1> update stock: 100 -> 103
```

It is recorded on the first run (or with `--gnomon-update-snapshots`) and reviewed in the pull
request like any other file. The same fixtures exist for Jest and Vitest (`@bitsinfra/gnomon/testing`,
`withScratch`, `gnomonDiff`) and RSpec (`gnomon: true`, `match_gnomon_snapshot`).

## 2. A reviewed data change

A backfill, a support fix, a price change: make it on a branch, look at exactly what it changes,
have someone approve it, merge it, and undo it if it was wrong.

```bash
gnomon --dsn "$APP" branch create price-fix
gnomon --dsn "$APP" --branch price-fix sql "update products set price = price * 1.10 where id <= 5"
gnomon --dsn "$APP" diff price-fix
```

```
table     key       kind    col    old  new
products  {"id":1}  update  price  1.5  1.65
...
```

Main still says 1.50. Ask for review; the author cannot approve their own request:

```bash
gnomon --dsn "$APP" cr open price-fix "Raise five prices by 10%"
gnomon --dsn "$REVIEWER" cr review 1 approve "looks right"
gnomon --dsn "$REVIEWER" merge price-fix --preview
gnomon --dsn "$REVIEWER" merge price-fix
```

The merge is three-way: had someone changed one of those prices on main meanwhile, it would stop
with a conflict to resolve instead of overwriting it. If the branch is written after the approval,
the approval no longer counts. The log shows who did what; one call takes it back:

```bash
gnomon --dsn "$REVIEWER" log --limit 5
gnomon --dsn "$REVIEWER" undo --merge 1
```

The undo is itself a change in history, and refuses if a later edit touched the same rows. The same
flow is in the review app: `gnomon serve` and open http://127.0.0.1:8090.

## 3. An agent on a role

Give an agent (or a contractor, or a script you do not fully trust) a database it can use with
nothing but a connection string, where everything it does lands on its own branch for review.

```bash
gnomon --dsn "$OPS" agent create support
```

```
connection string (the agent needs nothing else; its sessions start on branch support/1):
  host=... dbname=shop user=gnomon_agent_support password=...
```

The agent writes plain SQL; it does not need to know gnomon exists:

```bash
psql "$AGENT" -c "update orders set status = 'refunded' where id = 7"
psql "$AGENT" -c "select status from orders where id = 7"        # refunded
psql "$APP"   -c "select status from orders where id = 7"        # new: main is untouched
```

What the database refuses it, whatever SQL it sends: writing main by a qualified name
(`update public.orders ...`), merging, approving, and reading other branches. When it is done it can
say so, which opens a change request (or, if it never does, the heartbeat opens one after
`idle_review_after`):

```bash
psql "$AGENT" -c "select gnomon.done('Refunded order 7: the customer returned it')"
```

The reviewer sees it like any other request:

```bash
gnomon --dsn "$REVIEWER" cr list
gnomon --dsn "$REVIEWER" diff support/1
gnomon --dsn "$REVIEWER" cr review 2 approve
gnomon --dsn "$REVIEWER" merge support/1
```

`gnomon agent next support` gives the agent a fresh branch for its next task, and
`gnomon agent stop support` is the kill switch: its login is disabled, its branches closed, and
with `--undo-since` its merged work is undone. For agents that speak MCP, `agent create` also
printed an MCP configuration (stdio, or HTTP with a token for `gnomon serve --mcp`). For agents
your own product runs, the SDKs give each task a run: `gnomon.startRun()` in TypeScript,
`gn.start_run()` in Python ([sdk/ts/README.md](../sdk/ts/README.md), [the Python README](../integrations/python/README.md)).

## Next

- Schema changes on a branch: `gnomon migrate <branch> -- migrations/*.sql` ([schema-changes.md](schema-changes.md)).
- A branch per pull request: the GitHub Action ([action/](../action)).
- Time travel, history, blame, the change feed: [sql-reference.md](sql-reference.md).
- What happens on a branch, and what each error code means: [branches.md](branches.md).
- Running it: [operations.md](operations.md); who may do what: [security.md](security.md).
