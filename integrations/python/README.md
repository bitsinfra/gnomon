# gnomon-postgres (Python)

Branches, time travel and merges for PostgreSQL apps on the gnomon extension: the SDK (runs for
agents and tasks, review, the core), psycopg helpers, SQLAlchemy and Django, and pytest fixtures
with snapshots. `import gnomon`.

## Install

```bash
pip install gnomon-postgres
```

Python 3.9 or later. Extras: `sqlalchemy`, `django`, `asyncpg` and `test` (the pytest plugin), as in
`pip install "gnomon-postgres[sqlalchemy]"`. It connects through psycopg 3, which needs libpq; on a
machine without it, add `"psycopg[binary]"`.

## A run

```python
from gnomon import Gnomon

gn = Gnomon(app="dbname=shop user=shop_app", runs="dbname=shop user=shop_runs")
with gn.start_run("Refund order 3", actor="support-bot") as run:   # a branch for this task
    run.sql("update orders set status = 'refunded' where id = 3")
    if run.summary()["checks"]["passed"]: run.merge()
    else: run.submit("Refund order 3")                               # a change request instead
```

Leaving the `with` block without `merge()` or `submit()` discards the branch. `run.url(base)` and
`run.connection(base)` give a tool a connection string, or a psycopg connection, pinned to the run
(a login of the run's own, confined to its branch, dropped when the run ends). With asyncpg:
`AsyncGnomon(app=asyncpg_source(pool), runs=asyncpg_source(runs_pool))` (`from gnomon.asyncpg import
asyncpg_source`; the `asyncpg` extra). `AsyncGnomon` is the
same API for `psycopg.AsyncConnection` (the sync client is generated from it, so they cannot
drift). `gn.requests`, `gn.branches`, `history`, `blame`, `revert`, `status()` and `doctor()` are
the review and core layers. Tools for agent frameworks bound to one run:
`gnomon.tools.anthropic_tools(run)`, `openai_agents_tools(run)`, `langchain_tools(run)`,
`mcp_handler(run)`. The two logins, the envelope and the errors are as in the TypeScript SDK
([the TypeScript SDK](https://gnomon.bitsinfra.com/sdks/typescript)); both pass the same conformance scenarios
([the specification](https://gnomon.bitsinfra.com/sdks/specification)).

## Helpers

```python
import gnomon, psycopg
conn = psycopg.connect(gnomon.branch_dsn("dbname=shop", "feature"))   # sessions start on a branch
with gnomon.branch(conn, "feature"): ...                               # or switch one connection
opts = gnomon.connection_options(admin_conn, "feature")                # what the database says the
                                                                       # branch needs (schema versions, masks)
```

`use`, `begin` (one transaction, for poolers), `create_branch`, `create_scratch`, `drop_branch`,
`diff`, `merge`. SQLAlchemy: `gnomon.sqlalchemy.branch_engine(url, branch)` and
`attach_branch(engine, get_branch)` (each transaction on the branch a callable names). Django:
`gnomon.django.BranchMiddleware` (a branch per request from `X-Gnomon-Branch`).

## Tests on branches

```python
def test_signup(gnomon_conn, gnomon_snapshot):     # a psycopg connection on a fresh scratch branch
    signup(gnomon_conn, "a@x.io")
    gnomon_snapshot.assert_match(gnomon_conn)      # the branch's diff against a stored file
```

`GNOMON_TEST_DSN=... pytest` (the plugin loads itself when the package is installed;
`--gnomon-update-snapshots` records, `--gnomon-keep` keeps the branches).
`gnomon.testing.assert_no_changes` and `assert_changed` check a branch's diff directly.
