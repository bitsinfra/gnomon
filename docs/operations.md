# Operating gnomon

## Install forms

| Form | How | Notes |
|---|---|---|
| Extension | `make install` (PGXS), then `create extension gnomon` as a superuser | Creates the roles `gnomon_reader`, `gnomon_writer`, `gnomon_merger`, `gnomon_admin` once per cluster. |
| pg_tle | `tools/build_install_forms.sh`, then run `build/dist/gnomon-pgtle--1.0.1.sql` and `create extension gnomon` | For RDS and Aurora; Supabase through database.dev. Needs pg_tle 1.4 or later (the package names its schema), and is tested against pg_tle 1.5.3 (`test/shell/pgtle.sh`). pg_tle refuses the package on a server that also has gnomon installed as files. Without event-trigger rights gnomon falls back to fingerprint checks. |
| Plain SQL | `psql -v ON_ERROR_STOP=1 -f build/dist/gnomon-plain--1.0.1.sql` | For providers with neither. The whole suite runs against this form too (`GNOMON_PLAIN=1 test/run.sh`). |
| C module | `make -C src/c install`, `shared_preload_libraries = 'gnomon_c'`, `create extension gnomon_c` | Optional. See `src/c/README.md`. |
| Container image | `docker build -f docker/Dockerfile -t gnomon/postgres .` (`docker/compose.yml`: a database, the review app and a seeded example) | PostgreSQL 18 with both extensions, the C module preloaded and the CLI. `GNOMON_DATABASES` lists the databases that get gnomon at first start; `GNOMON_C_MODULE=off` leaves the module out. |

PostgreSQL 15-18. MERGE through branch views needs 17+.

## The heartbeat

`select gnomon.heartbeat()` once a second: records a clock tick when something changed, applies
scheduled (future-dated) changes that came due, runs the early-warning watcher, seals a ledger
block, creates version partitions ahead of need (moving any rows that landed in the default
partition), sweeps abandoned scratch branches, and runs retention hourly. Run it with one of:

- the C module's worker: `gnomon.heartbeat_databases = 'app, other'`, `gnomon.heartbeat_interval = 1s`;
- pg_cron: `select cron.schedule('gnomon', '1 second', 'select gnomon.heartbeat()')`;
- the CLI: `gnomon --dsn ... daemon`.

The heartbeat also marks branches over quota, closes and drops expired branches,
flips change requests whose approvals went stale, opens change requests for idle assigned branches
(`idle_review_after`), runs history-checkpoint policies, rebases branches whose `auto_rebase`
option allows it, and re-freezes thawed partitions past `thaw_ttl`.

**The job loop.** `gnomon daemon` runs, after each heartbeat, what the database cannot do inside a
`SECURITY DEFINER` function or without credentials it does not have: thaw requests (restored with
the archiver and its store credentials), scheduled merges (run as the daemon's role, which must be
a `gnomon_merger`; each is re-checked against the scheduler's rights and the change request),
notification webhooks, and sinks. Each kind is a table polled with `FOR UPDATE SKIP LOCKED`, so
several daemons can run. Run it as a role that is a member of `gnomon_admin` and `gnomon_merger`,
not a superuser. The C worker runs the heartbeat only; with it (or with pg_cron), run
`gnomon daemon --no-heartbeat` for the jobs.

An idle database's heartbeat takes no xid and writes nothing, so it records no ticks either; a tick
is due once some transaction has taken an xid, or one running at the last tick has ended. Without a
heartbeat, "as of 15:00" can only resolve to ticks taken by branch, tag and merge operations, and
`gnomon doctor` warns once changes are waiting for a tick.

## Durability

Exact replay across a crash needs `synchronous_commit = on` (the default). With asynchronous
commit a crash can lose acknowledged transactions, and their transaction ids are reused, so a
coordinate handed out before the crash may disagree with the database afterwards. The history
checker demonstrates both cases (`cmd/gnomon-histcheck --kill`).

## Standbys

Capture coordinates on the primary (`gnomon.coordinate()` raises on a standby: a standby's snapshot
does not report the transactions still running on the primary). On a standby:

- `gnomon.use(branch, coordinate)`, `gnomon.as_of()` and `gnomon.begin()` wait until the standby
  has replayed past the coordinate (`gnomon.standby_wait`, default 30 seconds), then read exactly
  what the primary had there. `select gnomon.wait_for(coordinate)` waits on its own; under
  REPEATABLE READ call it before `BEGIN`, since the transaction's snapshot is taken at its first
  statement.
- A read at a coordinate set some other way (`SET gnomon.as_of`, a connection option) is answered
  only if the standby is known to have replayed past it, and refused (SQLSTATE 55000) otherwise.
  Coordinates older than every transaction still running on the standby always qualify.
- Branches, tags and timestamps read without waiting: the catalog rows that name them were
  committed after their coordinates, so a standby that has them has replayed far enough.
- Diffs work; `gnomon.changes()` needs an explicit `until` coordinate.
- Scratch branches are unlogged, so they are not replicated: `gnomon.use()` refuses them on a
  standby. Their routing views live in separate schemas (`gnomon_r_<schema>__s`); the routing views
  everything else reads (`gnomon_r_<schema>`) contain no unlogged table, which a standby could not
  open.

Tested in `test/shell/standby.sh`, and by the history checker replaying every logged read on a
synchronous standby (`test/shell/histcheck.sh`).

## Epochs: dump/restore, pg_upgrade, logical cutover, failover

An epoch is a (system identifier, timeline) pair; a new one starts at the first write after either
changes. Coordinates of an older epoch keep reading exactly, and versions of older epochs count as
committed before every coordinate of a newer one.

- **Dump and restore.** Every catalog table is an extension config table, so `pg_dump` carries
  branches, tags, ticks, history metadata and setting overrides; the per-table storage, routing
  views, triggers and policies are ordinary objects in the dump (`test/shell/dump_restore.sh`).
- **pg_upgrade** gives the cluster a new system identifier; transaction ids continue
  (`test/shell/pg_upgrade.sh`, 16 to 18).
- **Logical-replication cutover.** Publish every table, gnomon's catalog and storage included
  (`for all tables`); unlogged scratch tables are left out by PostgreSQL. The versioning trigger
  is `ENABLE ALWAYS` and does nothing inside an apply worker, so history arrives once, with its
  original stamps. Take the initial copy with `pg_dump --snapshot` of the slot's exported snapshot
  (the extension's own catalog rows are filtered out of the dump, so it never collides with the
  subscriber's), subscribe with `copy_data = false`, and at cutover copy the sequences across
  (`setval`). Do not run the heartbeat on the subscriber before cutover: its ticks would collide
  with the publisher's. `test/shell/logical_cutover.sh` does all of it.
- **Physical failover and point-in-time recovery** change the timeline. Transaction ids assigned
  on the abandoned side of the fork (never replicated, or past the recovery target) are assigned
  again on the new timeline; the new epoch keeps them from showing at old coordinates. With
  synchronous replication (`synchronous_commit = on` and a synchronous standby) every coordinate
  handed out on the old primary replays exactly on the promoted standby; with asynchronous
  replication, commits the standby never received are lost, and coordinates that saw them cannot
  replay (as after a crash with `synchronous_commit = off`). `test/shell/standby.sh` and the history checker's
  failover run (`--failover`) test it.

The event triggers skip their work while a dump is being restored (pg_dump scripts run with an
empty `search_path`), so restored objects stay as they were dumped.

## DDL on tracked tables

Event triggers re-sync gnomon's objects after `ALTER TABLE`, policy and trigger changes on tracked
tables, and give new tables and views in routed schemas their routing views. Added columns keep
their history correct: versions written before the column existed read its fast default. Renamed
columns keep their history (values are stored by slot). Where event triggers are not allowed, run
`select gnomon.sync()` after DDL; until then branch writes to a changed table are refused (its
fingerprint no longer matches).

Renaming a tracked table (`ALTER TABLE ... RENAME`) or moving it to another schema (`SET SCHEMA`)
keeps it tracked: its routing views follow the new name; its storage keeps its names.

Re-syncing after `ALTER TABLE` also re-enables a disabled versioning trigger. `gnomon doctor`
samples current rows against their latest versions to catch writes made with triggers disabled.

Row-level security follows DDL too: enabling RLS on a tracked table, or creating a policy on it,
makes the table's own policies govern it (gnomon drops its permissive `true` policy); disabling RLS
returns it to gnomon's (gnomon keeps RLS enabled for its own branch policies).

## Retention, partitions, cold storage

- `gnomon.set_retention('t', '{"keep_all": "30 days", "daily": "1 year", "monthly": true}')`: older
  versions are thinned to those visible at the retained tick coordinates and at tags; kept deltas
  are rewritten as keyframes. Each old partition with versions to remove is rewritten with what it
  keeps and swapped in (no dead rows left behind; writes to that partition wait for the swap,
  reads do not); the partition new versions go to is thinned in place. A long-running transaction
  holds the horizon back.
- What still needs history keeps it (`gnomon.history_pins()`): main's state at every branch's
  cutoff and every unapplied merge's base stays readable, and every change after a feed consumer's
  position, the last sealed ledger block and the watch point stays. Drop consumers you no longer
  read (`gnomon.feed_drop`).
- Below the thinned horizon, reads are exact only at the coordinates retention kept (tags, the
  retained ticks, branch cutoffs): a read at any other coordinate there fails with a clear error
  instead of returning a state that never existed.
- `gnomon.drop_history_before('t', '2026-01-01')` drops whole version partitions; each partition is
  self-contained (carry-forward keyframes). Reads that would need dropped history fail clearly. It
  refuses to drop what `history_pins()` lists (`force => true` overrides), and never lowers the
  read horizon archiving set.
- `gnomon archive t --before 2026-01-01 --to /mnt/archive` writes partitions to Parquet (one file
  per partition, every column as text plus its type in the file metadata, readable by DuckDB),
  verifies the file, records the manifest with checksum and ledger root, and drops the partition.
  Past reads into the archived range fail naming the file; `gnomon restore t <partition>` loads it
  back. `--to` takes a path, `s3://bucket/prefix` (AWS Signature V4; credentials from
  `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, optional `AWS_SESSION_TOKEN`, region from
  `AWS_REGION`; `AWS_ENDPOINT_URL` for MinIO, Ceph, R2 and other S3 servers) or
  `gs://bucket/prefix` (Google Cloud Storage's S3-compatible API with HMAC keys). Each file is
  read back from the store and checked before its partition is dropped; restore and
  `gnomon erase-archives` work on archives in any of them. Azure Blob Storage needs a mounted
  path (blobfuse2).

- **Thawing.** A session that asks for a moment inside the archived range (`gnomon.use(b,
  at)`, `begin`, `as_of`) requests a thaw instead of failing later: rows in `gnomon.thaw_request`,
  restored by the daemon's job loop, re-frozen `thaw_ttl` (1 day) after. Until then the read fails
  with 55000 "being thawed"; `gnomon thaw status` shows the queue. A request above
  `thaw_max_rows` is refused with a pointer to `gnomon restore`. To wait instead of retrying:
  `CALL gnomon.thaw('<moment>', '5 minutes')` requests, commits and waits; with `thaw_wait` set
  (`gnomon.set('thaw_wait', '2 min')`, or `SET gnomon.thaw_wait` per session) `gnomon.use` waits too
  for requests made earlier (its own request is not visible to the daemon until it commits).
- **Thin instead of drop.** `gnomon archive t --before ... --to ... --keep '{"daily": "1 year"}'`
  writes the whole partition to the store, then keeps the partition locally thinned to what the
  policy retains (its ticks and the tags), so reads at those moments stay local and exact; the
  manifest records it as thinned.
- **Format 2.** `gnomon archive` writes typed Parquet (`archive.format = 2`): native types for
  integers, floats, booleans, timestamps and binary, text for the rest, row groups of
  65,536 rows, and Bloom filters on the key columns, so engines skip files and row groups by key.
  Format 1 files (every column as text) stay readable; restore reads both.
- **Reading archives in place.** `gnomon archive t ... --engine file_fdw` keeps each archived
  partition readable without a restore: the archive becomes a foreign table attached as the
  history partition (`gnomon.attach_archive`; `detach_archive` and `restore_partition` take it
  off). Engines are rows of `gnomon.archive_engine`, templates with `{table}`, `{parent}`, `{from}`,
  `{to}`, `{location}`: `file_fdw` (PostgreSQL's own, over a CSV copy the archiver writes next to
  the Parquet file, at a path the server can read; tested in `archive_test`), `duckdb_fdw` and
  `pg_lake` (templates written from their documentation). Whether reads use them is
  `cold_scans`: `thaw` (the default) requests a thaw as for any archive, `allow` scans the
  foreign partition (slow: no index, the whole file per scan), `refuse` fails with 55000.

## History checkpoints

A past scan rebuilds every row changed since the moment it reads: 200,000 changed rows cost about
0.6 s. A checkpoint is a full copy of a table at one coordinate (`T__ck`, one partition per
checkpoint); with `gnomon.set('checkpoints', 'on')`, a past read uses the nearest checkpoint and
rebuilds only the rows changed between it and the moment (27 ms in the same case). Make one
by hand (`gnomon checkpoints create t --at tag:release`) or on a policy
(`gnomon checkpoints policy t --every 1d --keep 3`, run by the heartbeat). Each costs a copy of
the table. `gnomon.truncate()` on main takes one at the truncate's moment, so reads before it stay
exact.

## Sinks and notifications

`gnomon sink add hook webhook --config '{"url": "https://...", "secret": "...", "batch": 500}'`
(also `file`, `nats`, `kafka` and `parquet`; `--format gnomon|debezium|cloudevents`; `--tables`; `--since`). Delivery
is at least once with exact positions: a batch's position moves in the transaction that delivered
it, so a failure sends the same batch again. Webhooks carry an HMAC signature
(`X-Gnomon-Signature`) and an `Idempotency-Key`; NATS messages a `Nats-Msg-Id`; deduplicate on the
change id. Failures back off; a batch that keeps failing goes to `gnomon.sink_dead` and the sink
pauses (`gnomon sink dead`, `gnomon sink resume`). `gnomon sink replay <name> --since <ref>` sends
again from a moment. Notification targets (`gnomon.add_notify_target`) receive "change request
opened" events: webhooks through the daemon, `NOTIFY` channels at once; set `review_url` for
links into the review app.

- **Kafka.** `gnomon sink add k kafka --config '{"brokers": "k1:9092,k2:9092", "topic": "shop.changes"}'`.
  The daemon speaks Kafka's protocol itself (no client library; plaintext listeners, no SASL or
  TLS yet): a row's key is the message key, partitioned as Kafka's default partitioner does, so
  one row's changes stay in order; the change id is in the `gnomon-id` header. The producer is
  idempotent and its sequences are saved with the sink's position, so a batch sent again after a
  lost acknowledgement is not appended twice: exactly once per partition. Create the topic first.
  Tested against a fake broker that checks CRCs and sequences and drops acknowledgements
  (`TestKafkaAndParquetSinks`); not against a real Kafka here. That a sink's accounting survives
  the daemon killed with `kill -9` mid-stream is tested with a webhook sink
  (`TestSinkSurvivesKill9`).
- **Parquet.** `gnomon sink add lake parquet --config '{"to": "s3://bucket/changes"}'` writes one
  Parquet file per batch (the archiver's stores), named by the batch's first and last change, so a
  retry overwrites its own file: readers see each change once.

## Serving the review app, MCP and metrics

`gnomon serve --addr 127.0.0.1:8090` serves the review app, `/api/v1`, `/metrics` (Prometheus text
from `gnomon.metrics()`; or point `postgres_exporter` at that function) and, with `--mcp`, MCP over
HTTP. Two ways in: `--auth login` (a database login form) or `--auth header:X-Forwarded-User` behind
a proxy that authenticates, with `--role-map` mapping users to roles. The server's own login must
be a member of every role it acts as; each request runs `SET ROLE` to the user's role in its own
transaction, so the database's checks apply to the person, not to the server. Terminate TLS in the
proxy. `gnomon mcp --http :8091` serves MCP alone, authenticated by agent tokens
(`gnomon agent create`).

## Erasure

`select gnomon.erase('customer', '{"id": 7}', array['email', 'name'], 'request 42')` (gnomon_admin
only) is the one path that rewrites history: the current row, every version, branch heads and
branch history, and blob-store values no other version references. It records the ledger's hash
of each erased value (per version and value slot), so `gnomon.verify_ledger()` still passes and
still checks the rest of the row's history. `gnomon erase-archives` applies erasures to archived
Parquet files (wide keys included). **PostgreSQL's WAL, backups and replicas keep the old values until they
expire**; pair erasure with backup expiry.

**Crypto-shredding** reaches archives that cannot be rewritten (object lock, WORM buckets):

```sql
select gnomon.set_subject('customer', 'id', array['email', 'name']);   -- whose data, which columns
-- gnomon archive now encrypts those columns, a key per customer (AES-256-GCM)
select gnomon.erase_subject('customer', '7', 'request 42');
```

`erase_subject` deletes the subject's key, so every archive of the table forgets the subject's
encrypted values at once, and erases the columns in the database as `gnomon.erase` does
(`gnomon.subject_erased` records it). Restores and thaws decrypt with the keys that remain; a value
whose key is gone comes back NULL. Ledger leaves hash the plain values, so `verify_ledger` still
passes. Keys live in `_gnomon.subject_key`, readable by gnomon_admin only, and travel with
`pg_dump`: a backup holds them until it expires, which bounds how long an erased subject stays
recoverable from backups.

## The ledger

Each heartbeat seals the changes since the previous block into a Merkle block chained to the
previous one. `gnomon.verify_ledger()` recomputes chain, roots and every still-present version's
leaf; versions removed by retention or archiving and values replaced by erasure are accounted for.
A leaf (format 2) covers the table by its tracked id, the key by its values, and each value by its
storage slot, under fixed text settings: renaming tables or columns, adding or dropping columns, or
another session time zone leave sealed history verifiable. Blocks sealed before format 2 are
verified as they were sealed.
`gnomon ledger digest` exports block hashes for storage the database owner cannot rewrite.

## Merges that fail part-way

An atomic merge is one transaction: cancelled by `statement_timeout`, out of disk, or killed, it
leaves nothing behind and can simply run again. `call gnomon.merge_incremental(...)` commits per
batch; after a failure the batches it committed stay applied (readers may see a partly applied
merge) and `call gnomon.merge_incremental(source, resume => <merge id>)` continues from the merge
record without applying any batch twice. If the change request's checks fail at the end, the
merge is marked `failed` with what failed: fix the target and resume, or `gnomon.undo_merge(id)`. `test/shell/merge_faults.sh` covers statement_timeout,
kill -9 and a full disk under the target table.

## gnomon doctor

`select * from gnomon.doctor()` (or `gnomon doctor`): ticks (warned only when changes are waiting
for one), event triggers, each table's versioning trigger and fingerprint, a consistency sample,
rows in default partitions, a `part_span` too small for the cluster's xids (a partition number is
xid / part_span, at most 999,999 per epoch), the SQL-only DML gaps when the C module is absent,
lost scratch branches, early-warning counts.

## Upgrading gnomon

`tools/build_upgrade.sh <old version>` writes `sql/gnomon--<old>--<new>.sql` (shipped by
`make install`) and `build/dist/gnomon-plain--<old>--<new>.sql`. Then, as a superuser:

```sql
alter extension gnomon update;                -- or: psql -f gnomon-plain--<old>--<new>.sql
```

One transaction: it takes down what gnomon generated from its old code (per-table triggers,
routing views, policies, write functions), applies the catalog migrations in `src/upgrade`, loads
the new code, and regenerates every tracked table's objects. Data is untouched: catalog rows,
versions, branch tables. It refuses to start if one of your own objects (a view, a column default,
a policy) calls a gnomon function, naming them, since the old functions are dropped; drop those
objects around the upgrade. It takes ACCESS EXCLUSIVE locks on tracked tables while it rebuilds
their triggers, so plan it like other DDL. With the C module, upgrade `gnomon_c` afterwards.
`test/shell/ext_upgrade.sh` upgrades a live database (history, branches, a merge, a bitemporal
table, a held outbox, a mask profile) from the last committed version to the working tree, checks
reads at old coordinates, writes, merges, undo and a dump of the upgraded database, and does the
same for the plain-SQL form. How the scripts are built: `src/upgrade/README.md`.

## Settings

`select * from gnomon.settings` lists them with their defaults; change one with
`select gnomon.set('blob_threshold', '4096')`. Notable: `blob_threshold`, `part_span`,
`scratch_ttl`, `merge_batch`, `require_change_request`, `stale_reads` (`warn` or `refuse`),
`read_sample`, `stale_approvals`, `merge_window`, `logged_ttl`, `expire_grace`,
`idle_review_after`, `checkpoints`, `feed_setbased_min`, `thaw_max_rows`, `thaw_ttl`, `review_url`,
`runs_role`, `ddl_lock_timeout` and `ddl_concurrent_rows` ([sql-reference.md](sql-reference.md#more-settings)).

`part_span` (default 2^24 xids, applied to tables tracked afterwards) sets how many xids one version
partition covers. Each key's first write in a partition carries a keyframe forward, which costs a
second version insert. Spans that roll over every few seconds under load measurably cost writes,
WAL and storage. Retention and `drop_history_before` work in whole partitions, so a
larger span means coarser history drops.
