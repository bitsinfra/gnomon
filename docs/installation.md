# Installation

Gnomon runs on PostgreSQL 15 to 18, on your own servers or on managed Postgres such as Amazon RDS,
Aurora and Supabase. Put the extension in your database, then add the CLI and the SDK for the
language your code is in.

```bash
# PostgreSQL 18 with Gnomon
docker run -d --name gnomon -e POSTGRES_PASSWORD=postgres -p 5432:5432 \
  ghcr.io/bitsinfra/gnomon/postgres:v1.0.2

# The SDKs and the CLI
npm install @bitsinfra/gnomon
pip install gnomon-postgres
go install github.com/bitsinfra/gnomon/cli/cmd/gnomon@v1.0.2
```

## Try it in Docker

The image is PostgreSQL 18 with both extensions, the C module preloaded with its heartbeat on, and
the CLI. It is built for linux/amd64 and linux/arm64.

```bash
docker run -d --name gnomon -e POSTGRES_PASSWORD=postgres -p 5432:5432 \
  ghcr.io/bitsinfra/gnomon/postgres:v1.0.2
psql postgresql://postgres:postgres@localhost/postgres -c "select gnomon.create_branch('try')"
```

`GNOMON_DATABASES` lists the databases, comma separated, that get Gnomon at first start
(`postgres` by default). `GNOMON_C_MODULE=off` leaves the C module out. The CLI is in the image:
`docker exec gnomon gnomon version`.

From a checkout, `docker compose -f docker/compose.yml up` builds the same image and adds the review
app and the example shop.

## The extension

### Where you control the server

Build and install the extension, then create it in each database that needs it:

```bash
git clone --branch v1.0.2 https://github.com/bitsinfra/gnomon.git && cd gnomon
make && make install          # PGXS; uses the pg_config on your PATH
```

```sql
create extension gnomon;
```

`CREATE EXTENSION` creates the roles `gnomon_reader`, `gnomon_writer`, `gnomon_merger` and
`gnomon_admin` once per cluster, and needs a superuser. Everything after that runs as ordinary
logins.

### On managed Postgres

The release includes two SQL installers that need no files on the server:

| Provider | Installer |
|---|---|
| Amazon RDS, Aurora | `gnomon-pgtle--1.0.2.sql`, then `create extension gnomon`. Needs pg_tle 1.4 or later. |
| Supabase | The same pg_tle installer. |
| Anywhere else | `gnomon-plain--1.0.2.sql`, which installs the same objects without `CREATE EXTENSION`. |

```bash
curl -fsSLO https://github.com/bitsinfra/gnomon/releases/download/v1.0.2/gnomon-pgtle--1.0.2.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f gnomon-pgtle--1.0.2.sql
psql "$DATABASE_URL" -c "create extension gnomon"
```

The whole test suite runs against the plain-SQL form, so it is the same Gnomon. Where event
triggers are not allowed, Gnomon checks table fingerprints on branch writes instead of syncing
automatically after DDL; run `select gnomon.sync()` after you change a tracked table.

## The CLI

The CLI includes the MCP server, the review app and the job loop. Install it with Go:

```bash
go install github.com/bitsinfra/gnomon/cli/cmd/gnomon@v1.0.2
```

Or download the binary from [the release](https://github.com/bitsinfra/gnomon/releases/tag/v1.0.2),
which has archives for macOS and Linux (amd64 and arm64) and Windows (amd64), with SHA-256
checksums in `checksums.txt`:

```bash
curl -fsSL https://github.com/bitsinfra/gnomon/releases/download/v1.0.2/gnomon_1.0.2_darwin_arm64.tar.gz | tar -xz gnomon
./gnomon version
```

Put the binary on your PATH. On macOS, a binary a browser downloaded is quarantined and will not
open: clear the flag with `xattr -d com.apple.quarantine gnomon` (a download with `curl` is not
quarantined).

`gnomon init` takes an empty database to a tracked schema with a heartbeat running, and
`gnomon doctor` checks an existing one. [CLI reference →](cli.md)

## SDKs and bindings

The SDKs give each task your agents take on a run: a branch of its own, with limits already set
([Runs and the SDKs](sdk.md)). The bindings put your application's sessions and tests on a branch,
through the drivers and ORMs you already use.

| Language | Install |
|---|---|
| [TypeScript](../sdk/ts/README.md) | `npm install @bitsinfra/gnomon` |
| [Python](../integrations/python/README.md) | `pip install gnomon-postgres` |
| [Node](../integrations/node/README.md) | `npm install @bitsinfra/gnomon-postgres` |
| [Go](../integrations/go/README.md) | `go get github.com/bitsinfra/gnomon/integrations/go@v1.0.2` |
| [Ruby](../integrations/ruby/README.md) | `gnomon-postgres`, from a Gemfile line |
| [Elixir](../integrations/elixir/README.md) | `gnomon`, from a `mix.exs` dependency |
| [Java](../integrations/java/README.md) | `dev.gnomon:gnomon`, from the release's jar and pom |
| [.NET](../integrations/dotnet/README.md) | `Gnomon`, `Gnomon.EntityFrameworkCore` and `Gnomon.Xunit`, from the release |
| [PHP and Laravel](../integrations/laravel/README.md) | `gnomon/gnomon`, from the release's Composer package |

Each language's page starts with its install steps. The [GitHub Action](../action/README.md) and the
[dbt package](../dbt/gnomon_dbt/README.md) install from this repository too.

## The heartbeat

Gnomon needs something that ticks about once a second, so that "as of 15:00" resolves to the right
moment and scheduled changes land. Use one of:

- the C module's background worker (`gnomon.heartbeat_databases`, below);
- pg_cron: `select cron.schedule('gnomon', '1 second', 'select gnomon.heartbeat()')`;
- the CLI: `gnomon --dsn ... daemon`, which also delivers sinks, notifications and thaws.

The same pass marks branches over quota, closes expired branches, dismisses approvals that went
stale, takes history checkpoints and runs retention. Without a heartbeat, history and branches
still work; only time-based features drift.

## The optional C module

The SQL core gives every answer on its own. The C module adds speed and transparency: `SET
gnomon.branch` alone routes reads and writes, branches get real `FOR UPDATE` row locks,
`INSERT ... ON CONFLICT` and `TRUNCATE`, stale-read detection, a faster write path and point reads
by key through a custom scan. Build it from the same checkout:

```bash
make -C src/c && make -C src/c install
```

```ini
# postgresql.conf
shared_preload_libraries = 'gnomon_c'
gnomon.heartbeat_databases = 'app'
gnomon.heartbeat_interval = 1s
```

Then `create extension gnomon_c` in each database, after `gnomon`. [The C module →](../src/c/README.md)

## Upgrading from 1.0.0 or 1.0.1

For a database already running an earlier 1.0 release, keep its data in place and use the matching
upgrade from [the release](https://github.com/bitsinfra/gnomon/releases/tag/v1.0.2):

| Existing installation | Upgrade to 1.0.2 |
|---|---|
| Server extension | Install the 1.0.2 server files, including the new library if you use `gnomon_c`. Restart PostgreSQL if `gnomon_c` is preloaded. In each database, run `ALTER EXTENSION gnomon UPDATE TO '1.0.2'`, then `ALTER EXTENSION gnomon_c UPDATE TO '1.0.2'` if installed. |
| Plain SQL | Run the release's `gnomon-plain--<version>--1.0.2.sql` for the version you have (`1.0.0` or `1.0.1`) with `psql -v ON_ERROR_STOP=1 -f` against the existing database. |
| pg_tle | Run the release's `gnomon-pgtle--<version>--1.0.2.sql` with `psql -v ON_ERROR_STOP=1 -f`. It registers and applies the upgrade in a single transaction. |

See [Upgrading Gnomon](operations.md#upgrading-gnomon) for the locks and permissions this requires.

## Track your first table

```sql
select gnomon.track('orders');
```

Tracking takes a brief lock while Gnomon generates the table's storage and views, and does no work
per row: history starts now, with no backfill and no copy of the table. The next step is
[the tutorial](tutorial.md).
