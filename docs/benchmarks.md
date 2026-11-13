# Performance

What Gnomon costs, measured. Every figure comes from a script in `bench/`, so you can run the same
numbers on your own hardware.

**Conditions.** PostgreSQL 18.3 on an Apple Silicon laptop, not dedicated server hardware, with
`fsync = off` and `synchronous_commit = off`. The machine was shared with other work, so absolute
numbers are pessimistic; the ratios taken within one run (tracked against untracked, branch against
main) are the ones to read. Point reads and writes are pgbench with prepared statements on a
200,000-row table, with the heartbeat running once a second as in production.

```bash
PGHOST=$PWD/build PGPORT=54330 bench/targets.sh 200000 4        # the whole set, with the C module
PGHOST=$PWD/build PGPORT=54330 bench/point_reads.sh 200000 8 3  # main, branch depth 1 and 4, and the past, at once
PGHOST=$PWD/build bench/write_best.sh 54330 3 5                 # writes, bulk updates, WAL and storage
PGHOST=$PWD/build bench/write_cpu.sh 54330 5 30000              # server CPU per tracked write
PGHOST=$PWD/build bench/merge_best.sh 54330 4                   # merges
PGHOST=$PWD/build PGPORT=54329 bench/soak_branches.sh 100000 5  # 100,000 open branches
```

## Reading

Reads on main are untouched: tracking adds one permissive policy and changes no plan.

| | |
|---|---|
| Point read on main, untracked vs tracked | 54.5k vs 54.6k tps — the same, within noise |
| `jsonb @>` with a GIN index, untracked vs tracked | 11.2k vs 11.6k tps |
| Point read on a branch (C module) | 0.035 ms against 0.031 ms on main: +13% at depth 1, and the same at depth 4 — depth costs nothing |
| Point read in the past, table unchanged | +6% against a current read |
| Point read in the past, 10% of rows changed since | 0.027 ms, so one read in ten is rebuilt from history |
| Past scan of 200,000 rows | 25 ms as of now; 143 ms with 10% changed since, about 7.7 µs per changed row |

With a history checkpoint near the moment you read, a past scan of a table where everything
changed drops from 595 ms to 27 ms.

## Writing

Each write on a tracked table also writes its version: one probe for the row's latest version, one
heap insert and one index entry. With the C trigger that is about 5 µs of server CPU per write: a
single-row `UPDATE` in its own transaction takes 10.0 µs untracked and 15.0 µs tracked.

| | |
|---|---|
| Single-row `UPDATE`, 1 client | untracked 52.6k tps; C trigger 41.0k (77%); PL/pgSQL trigger 21.6k (41%) |
| Single-row `UPDATE`, 8 clients | untracked 182k tps; C trigger 139k (76%); PL/pgSQL trigger 93.0k (51%) |
| Bulk `UPDATE` of 200,000 rows | untracked 215 ms; C trigger 609 ms; PL/pgSQL trigger 2.3 s |
| WAL per write | 224 bytes untracked; 434 with the C trigger: the version's heap insert (about 105 bytes) and its index entry (about 75) |
| Storage per version | 141-147 bytes, lazy baselines and carried-forward keyframes included |
| Branch writes, 4 clients | 9.2k tps on a logged branch, 6.1k on a scratch branch |

The C module's trigger is the one to use under write load: it inserts versions into the partition
and probes indexes directly, keeps the partition and its indexes open for the rest of the
statement, and opens SPI only for the cases that need it.

## Branching and merging

| | |
|---|---|
| Create a branch | 0.13 ms each, or 0.05 ms each when creating 100,000 |
| 100,000 open branches | no effect on main's reads or writes; 53 MB of catalog |
| Merge into main | 105k rows/s with the C trigger (50,000 updated rows), no table lock |
| Diff of 1,000 changed rows in a 200,000-row table | 33 ms; it scales with the changes, not the table |
| Track an existing table | 52 ms for 200,000 rows — the lock is held while objects are generated, and nothing is done per row |

## The change feed

| | |
|---|---|
| Change set, no row images | 2.0-2.3M rows/s over 266,666 versions |
| With row images, new and old | about 220k rows/s |
| Draining a 152,000-change backlog in pages of 1,000 | 5.0 s, since each page continues from the consumer's position |
| Capture a coordinate | 0.017 ms per round trip, about 5 µs inside the server |

## Correctness under load

The history checker runs eight concurrent sessions against main and three branches, at every
isolation level, and verifies after each run that every logged read replays exactly, that the feed
has no gaps or duplicates, that a branch read matches main at its cutoff for untouched keys, and
that version keys never go backwards along a row. It does this across `kill -9`, a crash-restart
and a failover to a promoted standby. The merge fuzzer runs ten million random three-way cases
against the strategy invariants, about 20k cases/s.

[Operations →](operations.md)
