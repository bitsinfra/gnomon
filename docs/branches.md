# Working on a branch

A branch of production, in an instant. It reads everything from main and keeps only what it
changes, so it opens in about a millisecond and copies nothing, however big your database is. Give
one to every agent run, every pull request and every test.

Your application doesn't change. A branch is a connection string: point a session at it, and the
queries it already runs read and write the branch instead of main.

Underneath, a branch is a row in `gnomon.branch` with a frozen lineage: the parent at the fork, and the
parent's own lineage as of the fork. Reads and writes of tracked tables on a branch go through
routing views (`gnomon_r_<schema>.<table>`), a `UNION ALL` of main's table (rows the branch did not
touch, filtered by policies that apply only to the view owner), the branch's heads, and a history
arm that rebuilds ancestor and past rows. Main's own queries never see a policy filter.

## Choosing a branch

```sql
select gnomon.use('feature');            -- session: gnomon.branch + routing search_path
select gnomon.begin('feature');          -- this transaction only (transaction poolers)
select gnomon.use('feature', 'tag:v1');  -- the branch as of a coordinate, tag or timestamp (read-only)
select gnomon.use('main');               -- back
```

Connection strings: `gnomon branch url feature` prints
`options=-c gnomon.branch=feature -c search_path=gnomon_r_public,public`. With the C module loaded,
`-c gnomon.branch=feature` alone is enough and schema-qualified names are routed too.

Connection-level `options` do not survive transaction pooling; behind pgbouncer in transaction
mode, start each transaction with `select gnomon.begin('feature')` (the Python, Node and Ruby
helpers do this; PostgREST does it through `db-pre-request = gnomon.postgrest_pre_request`).

## The DML matrix

Executable: `test/sql/07_dml_matrix.sql` (both modes), `test/shell/dml_locks.sh`, `src/c/test/`.

| Statement | SQL core | C module |
|---|---|---|
| `SELECT`, joins, CTEs, window functions, prepared statements | works | works |
| `INSERT`, `UPDATE`, `DELETE`, `RETURNING`, `COPY FROM` | works | works (`COPY t FROM` writes the branch, `COPY t TO` reads it) |
| `MERGE` | works on PG17+ | works on PG17+ |
| `INSERT ... ON CONFLICT DO NOTHING` (no target) | accepted, but a duplicate still raises 23505 | works |
| `INSERT ... ON CONFLICT (cols) ...` | error 42P10 | `DO NOTHING` and `DO UPDATE SET c = EXCLUDED.c` work; a concurrent upsert of the same key waits, then takes the conflict action |
| `SELECT ... FOR UPDATE / SHARE` | **returns rows, takes no row lock** | copies the row up and locks it on the branch |
| Concurrent updates of one row on one branch | the later writer gets SQLSTATE 40001 (retry) | same (the C module does not change branch write locking) |
| `TRUNCATE` | refused; use `select gnomon.truncate('t')` | rewritten to `gnomon.truncate` |
| Schema-qualified names (`public.t`) | read main; writes to tracked tables are refused (25006), writes to untracked tables are unchecked | routed to the branch |
| DDL | out of scope: it changes main's table | out of scope |

`gnomon doctor` reports the SQL-only gaps when the C module is not loaded.

Branch-per-test works well in SQL-only mode: one connection per branch, upserts written as plain
insert-or-update. Branch-per-request apps with concurrent writers and row locks need the C module.

## How a branch write behaves

- **Constraints**: primary keys, unique constraints and unique indexes on plain columns are
  checked against the merged view (ancestor rows included) and, for concurrent writers on the same
  branch, by unique indexes on the heads. Partial and expression unique indexes are checked among
  the branch's own rows only (a clash with an ancestor row surfaces when the merge applies).
  Foreign keys are checked against the parent's routing view; `ON DELETE` / `ON UPDATE` `CASCADE`,
  `SET NULL`, `SET DEFAULT`, `RESTRICT` and `NO ACTION` are emulated through the child's routing view.
  A key change is a delete plus an insert, and the rows referencing the old key follow the
  `ON UPDATE` rule, as on main. CHECK and NOT NULL constraints are declared on the heads.
- **Defaults and identity columns** come from the routing view, so branches draw from main's
  sequences and merged rows never collide. Generated columns are computed on the heads.
- **User triggers** on the table are mirrored onto the heads and fire on branch writes, with these
  differences: they run as `gnomon_writer` (not the caller), `TG_TABLE_NAME` is `<table>__b`, row
  types carry an extra `gn_branch` column at the end, and statement-level triggers fire once per row.
  Unqualified table names inside trigger functions resolve through the routing search path, so side
  effects such as audit rows land on the branch.
- **Writes are refused** while `gnomon.as_of` is set, on merged or closed branches (masked writes
  too), and for confined roles on branches their acl does not allow.
- **Row-level security of the table's own** (Supabase style) applies on branches as on main: reads
  through the routing view are filtered for the caller, and branch writes are checked against the
  table's INSERT, UPDATE and DELETE policies as the caller (rows they hide are skipped; new rows
  they refuse are an error). RLS enabled without policies denies, as PostgreSQL does.
- **Untracked tables** are visible on a branch through read-only pass-through views; writes fail.

## Nested branches, rebase, merge

```sql
select gnomon.create_branch('child', 'feature');   -- sees feature as of now, and feature's lineage
select gnomon.rebase('feature');                   -- carry feature onto main's current state
select * from gnomon.merge_preview('feature');     -- what a merge would do, including conflicts
select gnomon.merge('feature');                    -- into its parent; returns the merge id
call gnomon.merge_incremental('feature');          -- a commit per batch (readers may see a partial merge)
select * from gnomon.conflict where merge_id = 3;  -- conflicts are rows
select gnomon.resolve(17, 'theirs');               -- or 'ours', 'base', 'value' with a jsonb value
select gnomon.merge('feature', resume => 3);
select gnomon.undo_merge(3);
```

Column strategies (`gnomon.set_merge_strategy(table, column, strategy)`): `conflict` (default),
`ours`, `theirs`, `counter`, `jsonb` (recursive by key), `set` (arrays), `text3` (line diff3), or a
function `(base jsonb, ours jsonb, theirs jsonb) returns jsonb` that returns SQL NULL for a conflict.

After a merge the branch's base moves to the merge result, so later merges of the same branch only
consider what changed since; keys whose merged value differs from the branch's are refreshed on the
branch. A partial merge (`tables =>` or `keys =>`) does not move the base.

## Scratch branches

`gnomon.create_branch('t1', kind => 'scratch')` or `gnomon.create_scratch('test')` uses unlogged
storage: faster, never replicated, lost in a crash (a restart marks them `lost`; `sweep_scratch`
drops them and abandoned ones after their TTL). The pytest, Jest/Vitest and RSpec fixtures in
`integrations/` give every test its own scratch branch of one seeded database.

Scratch branches are read through their own routing schemas, `gnomon_r_<schema>__s`, which add the
unlogged tables to the views; `gnomon.use()`, `gnomon.connection_options()` (`gnomon branch url`)
and the C module pick them for a scratch branch. The views in `gnomon_r_<schema>` contain no
unlogged table, so a standby can read main's past and logged branches through them, and they
refuse a scratch branch (SQLSTATE 55000) rather than show it without its rows. A scratch branch
can have scratch children; a logged branch cannot be created from a scratch one. Masked profiles
read main and logged branches.

## Confinement

```sql
select gnomon.confine('agent', array['agent-1']);   -- may write only agent-1 (and branches it creates)
```

The role loses DML on base tables, may not merge (merging into main needs `gnomon_merger`), and its
branch writes are checked against `gnomon.acl`. `gnomon mcp` is meant to run with such a role: the
database, not the tool list, enforces what an agent can do. With a mask profile
(`gnomon.confine(role, ..., mask_profile => 'support')`), the role reads masked columns through
`gnomon_r_<schema>__m<n>` and its writes keep the real values of masked columns it did not change.

Confined roles read only the branches in their access list and those branches' ancestors; a
read of another branch is refused (42501). The shared login of SDK runs is narrower
still: each transaction is bound to one run (`gnomon.begin(run)`), and reads only that run's branch.

## A role is a branch

```sql
select gnomon.assign('alice', 'alice-dev');   -- every new session of alice starts on alice-dev
select gnomon.unassign('alice');
```

`assign` sets the role's defaults for `gnomon.branch` and `search_path` in this database, so a
plain connection string is all a person or an agent needs: no call to `gnomon.use()`. With the
role confined and holding no grant on the base tables, a schema-qualified name fails loudly instead
of reading main, and resetting its own settings does not let it write main. `gnomon agent create`
does all of it (role, confinement, branch, assignment, token) and prints the connection string.
Defaults apply when a session starts; a pooler that logs in as one user and switches roles needs
`gnomon.begin()` per transaction instead.

## Merges between any two branches

`gnomon.merge(source, target)` takes any open target. Between siblings the base is their common
ancestor at the earlier cutoff; a second merge of the same pair starts from what the first one
read (`merge.source_at`). A source that forked later than its target carries its parent's changes
in between, as merging a newer branch does in git; `strict => true` refuses that and asks for a
rebase of the target. `gnomon.cherry_pick(xids, source, target)` applies what some transactions of
a branch did. `gnomon.revert(tbl, at, ...)` sets rows back to a past moment (undoable), and
`gnomon.checkpoint(name, branch)` / `gnomon.rewind(branch, name)` do it for a whole branch.
`gnomon.dry_run(statements)` runs statements on a throwaway child and returns the diff and checks
without keeping anything.

## Searching on a branch

Main's arm of a routing view is filtered by a policy, and PostgreSQL does not use an index for an
operator that is not leakproof under a policy: jsonb `@>`, `LIKE` and full-text search scan main's
table on a branch. `gnomon.use(branch, mode => 'search')` puts the search views
(`gnomon_q_<schema>`) first on the path: the same rows, with the branch filter as an ordinary
`WHERE`, so the index is used (a GIN `@>` on 200,000 rows: 5 ms against 30 ms). They do not push
join keys, so use them for searching and the routing views for joins. Only roles that may read the
table itself get them; confined and masked roles never do. With the C module nothing needs
choosing: a query on one table whose restriction needs such an index reads the search view by
itself, for the roles that may (`gnomon.c_search_views`, on by default); joins and keyed reads stay
on the routing views.

## Schema changes and errors

Adding a column, renaming one or creating a table on a branch has a page of its own:
[Schema changes on a branch](schema-changes.md). Every error Gnomon raises, with what to do about
it, is in [Errors](errors.md).
