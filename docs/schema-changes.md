# Schema changes on a branch

Schema changes come along too. Add a column, rename one or create a table on a branch, and main
stays as it is until the merge, which brings the new shape and its data across together. Every
pull request can carry its migration as well as its rows.

```sql
select gnomon.use('feature');
select gnomon.ddl($$alter table accounts add column tier text not null default 'basic'$$);
select gnomon.ddl($$create table notes (id int primary key, account_id int references accounts(id), body text)$$);
select gnomon.ddl($$create index on accounts (tier)$$);
update accounts set tier = 'gold' where id = 1;     -- the session reads the new shape at once
```

Or from files: `gnomon migrate feature -- migrations/*.sql` sends DDL through `gnomon.ddl` and runs
the rest on the branch, in one transaction. Plain DDL on a tracked table from a branch session is
refused (`[gnomon:ddl_on_branch]`): it would change main for every branch. With the C module it
is not refused but sent to `gnomon.ddl`, so a migration tool that runs its own DDL (Rails, Prisma
`migrate deploy`, Alembic online, Flyway) changes the branch's schema version unchanged; name
tables without a schema, as `gnomon.ddl` wants.

The first DDL on a branch makes a *schema version*. The branch and its children read it through
`gnomon_r_<schema>__v<n>`, which `gnomon.use()`, `begin()`, `connection_options()` and `assign()`
put first on the path; main and other branches do not see it. A new table is created for real,
empty, in a hidden schema and tracked there, so its rows live on the branch like any others.
`gnomon schema feature` (or `gnomon.schema_changes('feature')`) lists the changes; the review app's
schema page and the GitHub Action's comment show them.

What `gnomon.ddl` takes:

- **Additions**: `ADD COLUMN` (nullable, or with a constant default; NOT NULL needs a default),
  `CREATE TABLE` (with a primary key), `CREATE INDEX` (a unique one becomes a unique constraint of
  the version), `COMMENT`.
- **Constraints**: `SET NOT NULL`, `CHECK`, `UNIQUE`, foreign keys (to main's tables or the
  branch's own), each checked against the branch's rows when it is added (a violation fails the
  statement) and enforced on every write through the version's views; `DROP NOT NULL` and
  `DROP CONSTRAINT` of what the branch added; `SET DEFAULT` and `DROP DEFAULT`.
- **Renames, drops, type changes**: `RENAME COLUMN` (the view shows the column under its new name),
  `DROP COLUMN` (hidden; main keeps it until the merge), `ALTER COLUMN ... TYPE` with an `up` and a
  `down` expression, as pgroll has them, and `DROP TABLE`:

```sql
select gnomon.ddl($$alter table accounts alter column balance type numeric(12,2)$$,
                  up => 'balance / 100.0',              -- main's value, read on the branch
                  down => '(balance * 100)::bigint');   -- a branch value, in main's type
```

  Without them the version casts each way. The branch's own values in the new type are kept as
  they are; main's rows are read through `up` until the merge, which converts the column with it.

What it refuses, by name: renaming, dropping or retyping a key column, primary keys and exclusion
constraints, defaults that are not constants, expressions that call functions outside
`pg_catalog`, dropping a table another table references, and any statement that reaches main's
tables (name tables without a schema). Tracked tables must be in one schema. Scratch branches do
not take schema changes, and a scratch child of a versioned branch reads main's shape.

The merge into main replays the changes first, then the data: columns are added (constant
defaults do not rewrite the table), the hidden tables move into the user schema, indexes are built
(in the merge transaction, under `ddl_lock_timeout`; on tables of `ddl_concurrent_rows` rows or
more they are listed in the merge's `stats.indexes_to_build` and `gnomon merge` builds them
`CONCURRENTLY` once the merge has committed), the branch's values are copied into the real
columns, and the version closes. Constraints are added `NOT VALID` and then validated, so the
merge holds a weak lock while it checks main's rows; a type change converts main's history with
`up`; a dropped table is dropped. What main has meanwhile done the same way is adopted (a column
added with the same type, the same constraint, a column already gone). What it did another way is
a conflict of kind `schema` that stops the merge: a column added with another type (the branch
gets a warning at once: `gnomon.warning`, kind `schema`), a table or column the branch changes
that main dropped or renamed, a rename onto a name main took, a constraint of the same name with
another definition.

DDL on main still reaches every branch, versions included: a rename on main keeps branch rows
under the new name, a dropped column stops being required in branch storage, and a type change
converts branch rows and history with a cast (an event trigger cannot see a `USING`
expression, so a conversion that needs one fails with `[gnomon:retype_history]`; run that change
through a branch and `gnomon.ddl` with `up`). Versions regenerate over the new shape. A branch that stands on
another branch's version is merged into that branch, or after it. Undoing the merge reverts the
data; the DDL stays. With the C module, route a versioned branch with `gnomon.use()` or
`connection_options()`: `SET gnomon.branch` alone does not put the version's views on the path,
and is refused with `[gnomon:schema_version_routing]` rather than reading main's shape. Qualified
names (`public.accounts`) then reach the version's views for main's columns; a column added on the
branch needs the unqualified name, because PostgreSQL resolves columns before the module swaps the
table for its view.

## Migration tools

On main, migration tools run as always; where event triggers are not allowed (some managed
providers), finish each run with `select gnomon.sync()`. On a branch, feed their SQL to
`gnomon migrate`, which sends the DDL through `gnomon.ddl`:

| Tool | On a branch |
|---|---|
| Plain SQL files | `gnomon migrate pr-12 -- db/migrations/*.sql` (files run in the order given) |
| Flyway | `gnomon migrate pr-12 -- $(ls -v db/migration/V*.sql)`; on main, an `afterMigrate.sql` callback with `select gnomon.sync();` where event triggers are off |
| Alembic | `alembic upgrade head --sql > /tmp/m.sql && gnomon migrate pr-12 -- /tmp/m.sql` (offline mode writes the SQL); on main, `connection.execute(text("select gnomon.sync()"))` at the end of `run_migrations_online` in `env.py` where event triggers are off |
| Prisma | `prisma migrate diff --from-url "$MAIN_URL" --to-schema-datamodel prisma/schema.prisma --script > /tmp/m.sql && gnomon migrate pr-12 -- /tmp/m.sql` |
| Rails | `bin/rails db:migrate` runs its DDL over its own connection, which a branch session refuses; run Rails migrations on main, or write the change as SQL for `gnomon migrate` |

The GitHub Action's `migrations` input runs `gnomon migrate` for you.
