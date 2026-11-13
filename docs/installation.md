# Installation

Gnomon runs on PostgreSQL 15 to 18, on your own servers or on managed Postgres such as Amazon RDS,
Aurora and Supabase. Pick the form that matches the server you have.

## Release downloads

[Gnomon 1.0.1](https://github.com/bitsinfra/gnomon/releases/tag/v1.0.1) includes the CLI
for macOS, Linux and Windows, both SQL installers, the SDK packages and SHA-256 checksums.
To install the CLI, extract the archive for your operating system and architecture, put the
binary on your PATH, and run `gnomon version`. The extension runs on the database server.

```sh
curl -fsSL https://github.com/bitsinfra/gnomon/releases/download/v1.0.1/gnomon_1.0.1_darwin_arm64.tar.gz | tar -xz gnomon
```

On macOS, a binary a browser downloaded is quarantined and will not open: clear the flag with
`xattr -d com.apple.quarantine gnomon` (a download with `curl` is not quarantined).

You can also install the SDKs directly from the signed release:

```sh
npm install https://github.com/bitsinfra/gnomon/releases/download/v1.0.1/bitsinfra-gnomon-1.0.1.tgz
python -m pip install https://github.com/bitsinfra/gnomon/releases/download/v1.0.1/gnomon_postgres-1.0.1-py3-none-any.whl
```

For a database already running 1.0.0, keep its data in place and use the matching upgrade:

| Existing installation | Upgrade to 1.0.1 |
|---|---|
| Server extension | Install the 1.0.1 server files and run `ALTER EXTENSION gnomon UPDATE TO '1.0.1'`. If installed, update `gnomon_c` afterwards. |
| Plain SQL | Run the release's `gnomon-plain--1.0.0--1.0.1.sql` with `psql -v ON_ERROR_STOP=1 -f` against the existing database. |
| pg_tle | Run the release's `gnomon-pgtle--1.0.0--1.0.1.sql` with `psql -v ON_ERROR_STOP=1 -f`. It registers and applies the upgrade in a single transaction. |

See [Upgrading Gnomon](operations.md#upgrading-gnomon) for the locks and permissions this requires.

## Where you control the server

Build and install the extension, then create it in each database that needs it:

```bash
make && make install          # PGXS; uses the pg_config on your PATH
```

```sql
create extension gnomon;
```

`CREATE EXTENSION` creates the roles `gnomon_reader`, `gnomon_writer`, `gnomon_merger` and
`gnomon_admin` once per cluster, and needs a superuser. Everything after that runs as ordinary
logins.

## On managed Postgres

| Provider | How |
|---|---|
| Amazon RDS, Aurora | `tools/build_install_forms.sh`, then run `build/dist/gnomon-pgtle--1.0.1.sql` and `create extension gnomon`. Needs pg_tle 1.4 or later. |
| Supabase | The same pg_tle package, through database.dev. |
| Anywhere else | `psql -v ON_ERROR_STOP=1 -f build/dist/gnomon-plain--1.0.1.sql`, which installs the same objects without `CREATE EXTENSION`. |

The whole test suite runs against the plain-SQL form, so it is the same Gnomon. Where event
triggers are not allowed, Gnomon checks table fingerprints on branch writes instead of syncing
automatically after DDL; run `select gnomon.sync()` after you change a tracked table.

## The CLI

The release CLI includes the MCP server, the review app and the job loop. To build it from source:

```bash
(cd cli && go build -o gnomon ./cmd/gnomon)
```

`gnomon init` takes an empty database to a tracked schema with a heartbeat running, and
`gnomon doctor` checks an existing one. [CLI reference →](cli.md)

## The optional C module

The SQL core gives every answer on its own. The C module adds speed and transparency: `SET
gnomon.branch` alone routes reads and writes, branches get real `FOR UPDATE` row locks,
`INSERT ... ON CONFLICT` and `TRUNCATE`, stale-read detection, a faster write path and point reads
by key through a custom scan.

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

## A container with everything switched on

```bash
docker build -f docker/Dockerfile -t gnomon/postgres .
docker compose -f docker/compose.yml up
```

PostgreSQL 18 with both extensions, the C module preloaded, the CLI and the review app.
`GNOMON_DATABASES` lists the databases that get Gnomon at first start; `GNOMON_C_MODULE=off`
leaves the module out.

## The heartbeat

Gnomon needs something that ticks about once a second, so that "as of 15:00" resolves to the right
moment and scheduled changes land. Use one of:

- the C module's background worker (`gnomon.heartbeat_databases`, above);
- pg_cron: `select cron.schedule('gnomon', '1 second', 'select gnomon.heartbeat()')`;
- the CLI: `gnomon --dsn ... daemon`, which also delivers sinks, notifications and thaws.

The same pass marks branches over quota, closes expired branches, dismisses approvals that went
stale, takes history checkpoints and runs retention. Without a heartbeat, history and branches
still work; only time-based features drift.

## Track your first table

```sql
select gnomon.track('orders');
```

Tracking takes a brief lock while Gnomon generates the table's storage and views, and does no work
per row: history starts now, with no backfill and no copy of the table. The next step is
[the tutorial](tutorial.md).
