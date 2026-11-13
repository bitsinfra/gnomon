# @bitsinfra/gnomon

Give your application's agents (and your own code) a branch of the database per task: everything
they write lands on the branch, you look at the diff, and merge it or throw it away. The SDK
creates no agents and calls no model; it connects gnomon to what you already have.

```ts
import { Gnomon } from "@bitsinfra/gnomon";
import { nodePostgres } from "@bitsinfra/gnomon/pg";

const gnomon = new Gnomon({ app: nodePostgres(appPool), runs: nodePostgres(runsPool) });
await using run = await gnomon.startRun({ task: "Refund order 3", actor: "support-bot" });
await run.sql("update orders set status = 'refunded' where id = 3");
const summary = await run.summary();                 // changes, checks, conflicts, warnings
if (summary.checks.passed && summary.changes.rows <= 20) await run.merge();
else await run.submit({ title: "Refund order 3" });  // a change request for a person
```

Leaving the `await using` block without `merge()` or `submit()` discards the branch. A tool that
needs a connection string of its own gets one from `run.url()`: a login of the run's own, since the
shared runs login binds each transaction, not a connection, to one run.

## Two logins

- **app**: your application's login, a member of `gnomon_runner` (and of `gnomon_merger` if your
  code merges into main). It starts runs, reads diffs and merges.
- **runs**: one restricted login every run shares, named once with
  `select gnomon.set('runs_role', 'app_runs')` and confined with
  `select gnomon.confine('app_runs', array[]::text[], false)`. Each statement of a run goes out in a
  small envelope: begin on the run's branch, attribution, timeouts, one statement. The database
  refuses a second statement, writes outside the run, reads of other runs and of the real tables,
  and merges, whatever SQL arrives.

## What a run does

| | |
|---|---|
| `run.sql(statement, params?, { reason?, timeoutMs? })` | One statement on the run's branch. Rows are capped (`truncated` says so). A 40001 is retried. |
| `run.transaction(fn)` | Several statements in one envelope. |
| `run.diff()`, `run.summary()`, `run.checks()` | What changed, typed per table with `Gnomon<DB>` (see `gnomon types --lang ts`). |
| `run.merge()`, `run.submit()`, `run.discard()` | Into the real data, to review, or away. |
| `run.checkpoint(name)`, `run.rewind(name)`, `run.dryRun(statements)` | Savepoints across calls; try without keeping. |
| `run.url(base?)`, `run.connection(connect, base?)` | A connection string, or a connection opened with your driver, pinned to the run: a login of the run's own (`gnomon.run_login`), confined to its branch and dropped when the run ends. For a tool that wants its own connection (a migration runner, a BI client). `base` is the `url` option by default. |

`gnomon.requests` (open, `get(id).approve()`, `reject()`, `comment()`, `merge()`, `undo()`,
`wait()`) is what your product's own Approve, Reject and Undo buttons call. `gnomon.branches`,
`history`, `blame`, `revert`, `status()` and `doctor()` are the core layer.

## Adapters

| Import | For |
|---|---|
| `@bitsinfra/gnomon/pg`, `@bitsinfra/gnomon/postgres` | node-postgres pools and clients; postgres.js |
| `@bitsinfra/gnomon/bun` | Bun's built-in client: `bunSql(new SQL(url))` (with `prepare: false` behind a transaction pooler) |
| `@bitsinfra/gnomon/kysely` | A Kysely instance the application already has: `kysely(db, CompiledQuery)` |
| `@bitsinfra/gnomon/neon` | Neon's serverless driver: `neon({ pool })` over its WebSocket `Pool`, or `neon({ http: neon(url) })` over HTTP, where each run statement is one HTTP transaction with its envelope (`run.transaction()` with several statements needs the pool) |
| `@bitsinfra/gnomon/drizzle`, `@bitsinfra/gnomon/prisma` | A branch through your ORM: `branchPoolConfig(gnomon, poolConfig, branch)`, a node-postgres pool config whose sessions start on the branch, for Drizzle or Kysely; `prismaBranchUrl(gnomon, databaseUrl, branch)`, a Prisma datasource URL for the branch |
| `@bitsinfra/gnomon/anthropic`, `/claude-agent`, `/ai`, `/openai-agents`, `/langchain`, `/mcp` | The same seven tools (`sql`, `describe`, `diff`, `dry_run`, `checkpoint`, `rewind`, `done`) bound to one run, in each framework's shape |
| `@bitsinfra/gnomon/testing` | `withScratch`, `gnomonDiff` (snapshots), `assertNoChanges`, `assertChanged` |

Frameworks are optional peer dependencies: the core pulls in none of them.

## Errors

Every error is a `GnomonError` with `code` (the stable `[gnomon:<slug>]` of the database's hint),
`sqlstate`, `hint` and the driver's error; subclasses for what callers branch on
(`SerializationError`, `PermissionError`, `BranchClosedError`, `MergeConflictError`,
`ChecksFailedError`, `NotRoutedError`, `StatementTimeoutError`, ...). Messages are written for a
model to read. The meaning of each code: [Errors](https://gnomon.bitsinfra.com/errors).

## Observability

`onStatement` receives each statement with its run, login, duration and outcome; pass a `tracer`
shaped like `@opentelemetry/api`'s for spans per run and statement (statement text off by default).

## Versions

The SDK checks `gnomon.api_version()` when it connects (it needs 2). The wire protocol, the tool
descriptions and the conformance scenarios are in [the specification](https://gnomon.bitsinfra.com/sdks/specification); the Python SDK passes the same
scenarios.
