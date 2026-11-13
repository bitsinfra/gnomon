# gnomon GitHub Action

A branch of your database per pull request. Migrations and tests run against the branch; the PR
gets a comment with the schema and data changes; the branch is dropped when the PR closes. Main is
never touched until someone merges the branch (`gnomon merge pr-<n>`), which brings the schema
changes and then the data.

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, closed]
jobs:
  db:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - id: branch
        uses: bitsinfra/gnomon/action@v1.0.1
        with:
          database-url: ${{ secrets.STAGING_DATABASE_URL }}
          migrations: db/migrations/*.sql      # optional: DDL on the branch only (gnomon migrate)
      - if: github.event.action != 'closed'
        run: npm test
        env:
          DATABASE_URL: ${{ steps.branch.outputs.database-url }}
      - if: github.event.action != 'closed'
        uses: bitsinfra/gnomon/action@v1.0.1
        with:
          database-url: ${{ secrets.STAGING_DATABASE_URL }}
          mode: comment
```

Inputs: `database-url` (required), `branch` (default `pr-<number>`), `parent` (default `main`),
`mode` (`auto`, `create`, `comment`, `drop`), `c-module` (`true` when the server loads the C module,
so the branch setting alone routes), `migrations` (files run on the branch with `gnomon migrate`
before its URL is computed), `github-token`, `gnomon-version` (a released CLI, or `source`).

Outputs: `branch`, `database-url` (sessions start on the branch; masked in logs), `options`.

Notes:
- In SQL-only mode the URL carries `options=-c gnomon.branch=... -c search_path=gnomon_r_...`.
  Tools that qualify table names (Prisma, PostgREST) need the C module or the routing schema
  (see `integrations/`).
- Schema changes: pass the migration files as `migrations`. DDL goes through `gnomon.ddl` and stays
  on the branch (a schema version), the rest runs on the branch, all in one transaction, and the
  URL then names the version's views. Additions, constraints, renames, drops and type changes
  are supported; the run fails on anything a branch cannot change, naming the operation ([docs/schema-changes.md](../docs/schema-changes.md)). Migration
  tools that run their own DDL over their own connection need their script output fed to
  `migrations` instead (`prisma migrate diff --script`, `alembic upgrade --sql`).
- `action/test.sh` runs the action's script against a local database.
