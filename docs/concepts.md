# Concepts

Five ideas carry the whole system: tracked tables, coordinates, branches, merges and runs.

## Tracked tables

`select gnomon.track('orders')` puts a tracked table under version control. Gnomon generates
storage beside the table and a trigger on it, so every insert, update and delete records a version:
the row's key, which columns changed, who changed them and the exact position in the write stream.

Tracking copies nothing and backfills nothing. It takes a brief lock while the objects are created,
and history starts from that moment. The table itself is untouched — same name, same columns, same
indexes, same plans for the queries you already run.

Reads and writes of a tracked table on a branch go through a *routing view* in
`gnomon_r_<schema>`, which Gnomon keeps in step with the table. On main, nothing is in the way.

## Coordinates

A coordinate is an exact position in the database's history: a snapshot, written as text, that
names precisely which transactions had committed. `select gnomon.coordinate_text()` returns the one
the current statement read.

Every read in the past takes a reference, and Gnomon resolves it to a coordinate:

| Reference | Example |
|---|---|
| A coordinate | `'e1:880:882:881@0/1A2B3C4'` |
| A timestamp | `'2026-10-31 23:59'`, resolved through clock ticks |
| A tag | `'tag:before-migration'` |

A timestamp is approximate — it resolves to the latest tick at or before it, so it is as precise as
your heartbeat. A coordinate is exact: reading at one gives the same rows every time, however much
has changed since. That is what makes an agent's reads replayable.

## Branches

A branch is a line of its own. It starts from a coordinate on its parent and keeps only what it
changes:

- Rows it hasn't touched are read from main, live, with no copy.
- Rows it has written live in the branch's own storage.
- Rows that changed on main *after* the branch started are rebuilt from history, so the branch
  keeps seeing the database as of its own starting point.

So a branch opens in about a millisecond and costs what it writes, whether the database holds a
thousand rows or a billion. Branches nest: a branch of a branch sees its whole lineage. Scratch
branches are unlogged and swept automatically, which suits tests; logged branches survive a
restart and can be reviewed and merged.

Choosing a branch is a session setting, so your application doesn't change:

```sql
select gnomon.use('feature');     -- this session
select gnomon.begin('feature');   -- this transaction only, behind a pooler
```

[Working on a branch →](branches.md)

## Merges

A merge is three-way, like a merge in Git: Gnomon compares the branch against the *base* — the
state at the fork — and against the target now, field by field.

- Only the branch changed a field: the branch's value lands.
- Only main changed it: main's value stays.
- Both changed it: the column's strategy decides.

Strategies are per column (`gnomon.set_merge_strategy`). `counter` adds the two deltas, so two
sales of the last item are two sales. `jsonb` merges key by key, `set` unions, `text3` merges text
line by line, and `conflict` — the default — refuses to guess. Anything a strategy can't settle
becomes a row in `gnomon.conflict` for a person or a query to resolve.

Merges run into main or into another branch, a whole branch or one transaction
(`gnomon.cherry_pick`). Undo uses the same engine, and refuses when a later change would be
overwritten.

[Merges →](merges.md) · [Review →](review.md) · [History →](history.md)

## Runs

A run is a task with a branch of its own. The SDKs create one per unit of agent work, with limits
already set: it is discarded unless it is merged or submitted for review, it can't read another
run's branch even when runs share a database login, and every statement it makes is recorded with
the moment it read.

```ts
await using run = await gnomon.startRun({ task: "Refund order 4182", actor: "support-bot" });
await run.sql("update orders set status = 'refunded' where id = 4182");
if ((await run.summary()).checks.passed) await run.merge();
```

[Agents →](agents.md) · [Runs and the SDKs →](sdk.md)

## What Postgres enforces

None of this depends on an agent, an ORM or an application behaving well. A confined role's writes
are checked inside the database: it can write only the branches in its access list, it cannot merge
into main without `gnomon_merger`, and a schema-qualified name does not get it past the routing
views. An auto-merge policy's rules are evaluated by Postgres at merge time, whatever the agent was
told to do.

[Security →](security.md)
