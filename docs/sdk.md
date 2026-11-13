# Runs and the SDKs

Build it into your product. The TypeScript and Python SDKs give each task your agents take on a
*run*: a branch of its own, with limits already set. Merge it, send it for review, or let it go.

```bash
npm install @bitsinfra/gnomon      # TypeScript
pip install gnomon-postgres  # Python
```

The SDKs create no agents and call no model. They connect Gnomon to the application, the drivers
and the agent framework you already have.

## A run

```ts
import { Gnomon } from "@bitsinfra/gnomon";
import { nodePostgres } from "@bitsinfra/gnomon/pg";

const gnomon = new Gnomon({
  app: nodePostgres(appPool),   // your application's own login
  runs: nodePostgres(runsPool), // one login shared by every agent run
});

await using run = await gnomon.startRun({
  task: "Refund order 4182",
  actor: "support-bot",
});
await run.sql("update orders set status = 'refunded' where id = 4182");

const { checks, changes } = await run.summary();
if (checks.passed && changes.rows <= 20) await run.merge();
else await run.submit({ title: "Refund order 4182" });
```

The same thing in Python:

```python
from gnomon import Gnomon

gn = Gnomon(app="dbname=shop user=shop_app", runs="dbname=shop user=shop_runs")
with gn.start_run("Refund order 4182", actor="support-bot") as run:
    run.sql("update orders set status = 'refunded' where id = 4182")
    summary = run.summary()
    if summary["checks"]["passed"] and summary["changes"]["rows"] <= 20:
        run.merge()
    else:
        run.submit("Refund order 4182")
```

Leaving the block without `merge()` or `submit()` discards the branch, so an abandoned task leaves
nothing behind.

## Two logins

A run is safe because of how it connects, not because of what the agent is asked to do.

- **app** is your application's own login, a member of `gnomon_runner`. It starts runs, reads
  diffs and merges.
- **runs** is one restricted login every run shares. Each statement goes out in a small envelope:
  begin on the run's branch, attribution, timeouts, one statement. The database refuses a second
  statement in the envelope, any write outside the run's branch, reads of other runs' branches,
  reads of the real tables, and merges — whatever SQL arrives.

```sql
select gnomon.set('runs_role', 'app_runs');
select gnomon.confine('app_runs', array[]::text[], false);
```

Runs can't read each other's branches even though they share that login, because each transaction
is bound to one run.

## What a run can do

| | |
|---|---|
| `run.sql(statement, params?)` | One statement on the run's branch; rows are capped, and a serialization failure is retried. |
| `run.transaction(fn)` | Several statements in one envelope. |
| `run.diff()`, `run.summary()`, `run.checks()` | What changed, typed per table (`gnomon types --lang ts`). |
| `run.merge()`, `run.submit()`, `run.discard()` | Into the real data, to a person, or away. |
| `run.checkpoint(name)`, `run.rewind(name)`, `run.dryRun(...)` | Savepoints across calls; try a change without keeping it. |
| `run.url()`, `run.connection(connect)` | A connection string of the run's own, for a tool that brings its own connection (a migration runner, a BI client). |

## Your agent framework

The same few tools — explore the schema, run SQL, see the diff, try a change without keeping it,
checkpoint, rewind, finish — are exported for the framework you use, each bound to one run:

| | |
|---|---|
| TypeScript | `@bitsinfra/gnomon/anthropic`, `/claude-agent`, `/ai` (Vercel AI SDK), `/openai-agents`, `/langchain`, `/mcp` |
| Python | `gnomon.tools.anthropic_tools(run)`, `openai_agents_tools(run)`, `langchain_tools(run)`, `mcp_handler(run)` |

Or hand the agent a connection string and no library at all — it is only Postgres.
[The MCP server →](mcp.md)

## Drivers and ORMs

Runs work through the drivers you already use, and the bindings put ordinary sessions on a branch:
node-postgres, postgres.js, Prisma, Drizzle and Kysely; psycopg, asyncpg, SQLAlchemy and Django;
pg and ActiveRecord; pgx and `database/sql`; JDBC, HikariCP and Spring; Postgrex and Ecto; Npgsql
and EF Core; PDO and Laravel.

[TypeScript →](../sdk/ts/README.md) · [Python →](../integrations/python/README.md) ·
[The wire protocol every SDK implements →](../sdk/spec/SPEC.md)

## Your own review UI

The Approve, Reject and Undo buttons in your own product call the same review as the built-in app:

```ts
const requests = await gnomon.requests.open();
await gnomon.requests.get(id).approve();
await gnomon.requests.get(id).merge();
```

[Review →](review.md)

## In your tests

Each test gets its own branch of one seeded database, and can assert exactly what it changed.
[Testing →](testing.md)
