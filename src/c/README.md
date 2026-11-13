# gnomon_c: the optional C module

Everything gnomon does works in plain SQL. This module adds speed and transparency on top of it.
The SQL core gives the same answers without it: every test runs both ways (`src/c/test/run.sh`).

```bash
make -C src/c && make -C src/c install
# postgresql.conf
shared_preload_libraries = 'gnomon_c'
gnomon.heartbeat_databases = 'app'      # the background worker's databases
gnomon.heartbeat_interval = 1s
```

Then `create extension gnomon_c` in each database (after `gnomon`). Without the preload, the C
trigger still works (`gnomon.use_c_trigger(tbl)`); the hooks, the worker and the shared-memory
watermarks need it. `gnomon.c_module` reads `on` only when preloaded.

| Part | What it does | Setting |
|---|---|---|
| Background worker | Runs `gnomon.heartbeat()` (ticks, partitions ahead of the writes, scratch sweeping, ledger sealing) in each listed database; survives errors. | `gnomon.heartbeat_databases`, `gnomon.heartbeat_interval` |
| Routing | `SET gnomon.branch` alone routes reads and writes, schema-qualified names and `COPY` included; real `FOR UPDATE` row locks, `INSERT ... ON CONFLICT` (a concurrent upsert of the same key waits, then takes the conflict action) and `TRUNCATE` on branches. | `gnomon.routing` |
| Read sets | Records the keys a branch transaction reads, with the cutoff each read saw, for stale-read detection at merge; on per branch with `gnomon.track_reads(branch, sample)`. | `gnomon.track_reads` |
| Reported coordinate | After each top-level statement, the coordinate it read, in the reported setting `gnomon.last_coordinate` (the client receives it as a ParameterStatus message; replay with `gnomon.as_of`). | `gnomon.report_coordinate` |
| C trigger | Versions writes with direct heap and index inserts into the current partition and direct index probes; the default for new known-time, row-mode tables without wide keys (`c_trigger` setting `auto`). The partition and its indexes stay open for the rest of the statement, with their index state kept for the session. | `gnomon.c_direct_inserts` |
| Read context and watermarks | A planner hook replaces gnomon's read-context functions with C ones, cached across statements and checked against the catalog rows they came from. A per-table watermark in shared memory answers "has this table changed since C?". | `gnomon.c_substitute` |
| Touched-key filter | A bit array in shared memory, set by a trigger on each table's touched-key tables, that tells a branch point read a key no level touched without scanning for it. Rebuilt from the tables after a restart, on first use. | `gnomon.touched_filter_kb` (server), `gnomon.c_touched_filter` |
| Point reads | `SELECT ... WHERE <key> = <value>` on one routing view becomes the `GnomonPoint` custom scan: a few index probes instead of the view (the touched keys of every level at once, the branch head, main's row, or main's row rebuilt from its history), falling back to the view itself whenever they cannot answer. The rows are always the view's (`test/point.sql`). | `gnomon.c_point_reads` |
| Schema changes from a branch session | `ProcessUtility` sends `ALTER TABLE`, `CREATE TABLE`, `CREATE`/`DROP INDEX`, `DROP TABLE`, renames and comments on tracked tables (or in a tracked schema) of a session on a branch to `gnomon.ddl`, so migration tools change the branch's schema version (`test/ddl_search.sql`). | (always; gnomon's own DDL, temporary tables and main pass through) |
| Search views per query | A SELECT on one tracked table whose restriction has a non-leakproof operator that an index serves reads `gnomon_q_<schema>` instead of the routing view, for roles the search view is granted to. | `gnomon.c_search_views` |
| Counters | Point reads by answer, touched-key filter skips and scans, DDL redirects, search-view queries and upserts, in shared memory for every session: `_gnomon.c_counters()`, `gnomon.metrics()`. | (always, when preloaded) |

`EXPLAIN` shows `Custom Scan (GnomonPoint)` for a rewritten point read, and
`_gnomon.c_point_stats()` counts how this session's point reads were answered: no row, main's
row, the branch head, the view, or main's row rebuilt from its history in C; then how many
touched-key scans the filter saved, and how many it could not.

Tests: `src/c/test/run.sh` runs the SQL-core suite with the module loaded, then the module's own
tests (`routing.sql`, `watermark.sql`, `point.sql`, the two-session context cache test, the reported
coordinate, row locks and concurrent upserts, the worker). The history checker's `--c-module` mode checks the C trigger and point reads under
concurrency (`test/shell/histcheck.sh`).
