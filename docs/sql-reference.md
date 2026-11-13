# SQL reference

All functions live in schema `gnomon`. References (`ref`) accept `main`, a branch name,
`branch@<coordinate ref>`, a coordinate (`e1:880:882:881@0/1A2B3C4`), `tag:<name>`, `now`, or a
timestamp (resolved to the latest clock tick at or before it).

## Session settings

| Setting | Meaning |
|---|---|
| `gnomon.branch` | branch name (empty or `main` for main) |
| `gnomon.as_of` | read point: coordinate, `tag:<name>`, `now`, or timestamp (read-only) |
| `gnomon.valid_at` | valid-time read point for bitemporal tables |
| `gnomon.valid_from` | valid-time write point (a future value schedules the change) |
| `gnomon.actor`, `gnomon.reason` | commit-log attribution for the transaction |
| `gnomon.standby_wait` | how long `gnomon.use()`/`wait_for()` wait on a standby for replay (default `30 seconds`) |
| `gnomon.routing` (C module) | `off` disables transparent routing for the session |
| `gnomon.track_reads` (C module) | record keys read on a branch, for stale-read detection |
| `gnomon.c_substitute` (C module) | `off` makes the session use the SQL core's read context and probes instead of the C module's |
| `gnomon.c_point_reads` (C module) | `off` turns off the point-read path: `SELECT ... WHERE <key> = <value>` on one routing view is otherwise answered by the `GnomonPoint` custom scan, with the same rows as the view |
| `gnomon.c_touched_filter` (C module) | `off` makes branch point reads scan the touched keys even when the shared-memory filter says no level touched the key (`gnomon.touched_filter_kb`, a server setting, sizes the filter; 0 turns it off) |
| `gnomon.c_direct_inserts` (C module) | `off` makes the C trigger insert versions through SPI plans instead of directly into the partition |

All work with `SET`, `SET LOCAL`, `set_config(..., true)` and `options=-c ...`.

## Tracking

The functions of this section may be called by a superuser, the role that installed gnomon, or a
member of `gnomon_admin` that owns the table. Renaming a tracked table or moving it to another
schema keeps it tracked.

| Function | |
|---|---|
| `track(tbl, mode => 'known'\|'bitemporal', write_mode => 'row'\|'statement', key => name[], key_index => 'brin'\|'btree', part_span => int8, merge => jsonb, protected => bool)` | Start versioning a table (needs a primary key or a unique NOT NULL key). No backfill; metadata-only locks with `lock_timeout` and retries. Returns the tracked id. |
| `track_schema(schema, mode, write_mode)` | Track every table with a primary key. |
| `untrack(tbl, keep_history => false)` | Removes gnomon's triggers, policies and routing view (and storage unless kept); RLS gnomon enabled is turned off, RLS the table had of its own stays. |
| `sync(tbl => null)` | Re-generate gnomon's objects after DDL (automatic with event triggers). |
| `set_write_mode(tbl, 'row'\|'statement')` | Row triggers for OLTP, statement triggers for bulk loads. |
| `set_merge_strategy(tbl, col, strategy)` | `conflict`, `ours`, `theirs`, `counter`, `jsonb`, `set`, `text3`, or a function `(base jsonb, ours jsonb, theirs jsonb) -> jsonb` (null: a conflict), resolved on your search_path and stored schema-qualified. |
| `protect(tbl, on_off)` | Changes only through merges. |
| `outbox(tbl, channel)` | Held outbox: NOTIFY on main inserts (branch rows deliver when merged). |
| `use_c_trigger(tbl, on_off)` (gnomon_c) | Switch to the C versioning trigger. |

## Coordinates, time

| Function | |
|---|---|
| `coordinate()`, `coordinate_text()` | The calling statement's snapshot as a coordinate (primary only). |
| `coord(text)`, `coord_text(coord)` | Parse and print. |
| `resolve_coord(ref)` | Any reference to a coordinate. |
| `wait_for(coord or text, timeout => gnomon.standby_wait)` | On a standby, wait until it has replayed past the coordinate; statements that start afterwards read it exactly (call it before `BEGIN` under REPEATABLE READ). `use()`, `as_of()` and `begin()` call it. No-op on a primary. |
| `heartbeat()` | Tick, scheduled changes, watch, ledger, partitions, scratch sweep, retention. Takes no xid and writes nothing when nothing changed. |
| `tick()` | A tick only: the coordinate now with the wall time, written only when something changed since the last (gnomon_admin). |
| `current_epoch()` | |
| `create_tag(name, at => 'now', note)`, `drop_tag(name)` | Name a coordinate (it pins retention); `as_of = 'tag:name'`. A tag's creator or gnomon_admin drops it. |
| `history_pins()` | `(kind, what, coord, all_after)`: what still needs main's history (branch cutoffs, unapplied merge bases, feed consumers, the last ledger block, the watch point); retention, archiving and `drop_history_before` keep it. |

## Branches

| Function | |
|---|---|
| `create_branch(name, parent => 'main', kind => 'logged'\|'scratch', at => ref, ttl => interval, note => text)` | |
| `create_scratch(prefix, parent, ttl)` | Returns a generated name. |
| `use(branch, as_of => null, local => false)`, `begin(branch, as_of)` | Put the session or transaction on a branch. Returns the search_path. |
| `as_of(ref)`, `current_branch()` | |
| `drop_branch(name, cascade)`, `close_branch(name)`, `reopen_branch(name)` | |
| `sweep_scratch()` | Drop lost and abandoned scratch branches; never one a session is still using (it holds a lock on it). |
| `truncate(tbl)` | TRUNCATE on a branch. |
| `confine(role, branches, allow_create, mask_profile)`, `allow(role, branch, can_write)`, `unconfine(role)` | |
| `connection_options(branch, c_module)`, `routing_path(base_path)` | |
| `track_reads(branch, sample => 1.0)` | Read-set tracking for stale reads on this branch (C module): `gnomon.use()` turns it on; `null` falls back to `read_sample` and the session setting. |
| view `branches` | name, parent, kind, status, base, rebases, behind (versions main wrote since the base) |

## Reading history

| Function | Returns |
|---|---|
| `diff(a, b => null, tables => null, keys => null)` | `(tbl, key, kind, col, old, new)`: one row per changed field; `diff(branch)` compares a branch with its base. |
| `diff_summary(a, b)` | inserts, updates, deletes per table |
| `changes(since, until => now, tables => null, images => true)` | `(vkey, vlsn, tbl, key, op, xid, role, new, old)`: exactly the versions visible at `until` and not at `since`, in commit-consistent order. `images => false` leaves `new` and `old` null: the same change set at the speed of the version scan. |
| `feed_create(consumer, since)`, `feed_poll(consumer, lim)`, `feed_drop(consumer)` | A consumer's next batch; positions are stored, and pages follow the last change returned (a poll costs its page, not the window). A consumer belongs to its creator (or gnomon_admin) and keeps its unread history from retention: drop it when done. |
| `history(tbl, key jsonb)` | every version of a row (baseline, inserts, updates, deletes); `at` is the commit time with `track_commit_timestamp`, else the commit log's, else the first tick's (`at_tick`) |
| `blame(tbl, key jsonb)` | per column: the version, role, actor and time (`at`, as in `history`) of its last change |
| `stale_reads(branch)` | keys a branch read (C module tracking) that its target changed since the read |

## Merging

| Function | |
|---|---|
| `merge(source, target => parent, mode => 'atomic', tables => null, keys => null, resume => null, close => false)` | Returns the merge id. Status `applied` or `conflicts`. |
| `merge_incremental(source, target, batch, resume)` (procedure, `CALL`) | A commit per batch: inserts and updates parents first, then deletes children first; each batch is locked, planned and applied once; the same approvals, stale-read check and merge checks as `merge`. Stops at conflicts (resolve, then `resume => id`); a failing check marks it `failed` (resume, or `undo_merge`). |
| `merge_preview(source, target, tables, keys)` | `(tbl, key, action, base, ours, theirs, result, conflicts)` |
| `merge_where(source, tbl, predicate, target, preview => false)` | Partial merge by a key predicate (SQL over the key columns), evaluated with the caller's rights. |
| `resolve(conflict_id, 'ours'\|'theirs'\|'base'\|'value', value jsonb)`, `resolve_all(merge_id, choice)` | |
| `rebase(branch, at => now)` | Carry a branch onto its parent's current state; conflicts land in `gnomon.conflict` with `branch` set. |
| `watch()` | Early warnings into `gnomon.warning`: keys main changed that a branch touched, and branches `warn_changes_since_base` behind (rebased instead with `auto_rebase = on`). |
| `undo(xid, branch => 'main')`, `undo_xids(xids, branch, why)`, `undo_merge(id)`, `undo_role(role, since, until, branch)` | Reverts through the merge engine; later edits to the same fields refuse the undo (40001). |
| tables `merge`, `conflict`, `warning`, `xact` | records |

## Review and control

| Function | |
|---|---|
| `open_change_request(branch, title, body, target, approvals)`, `review(cr, 'approve'\|'reject'\|'comment', body)` | |
| `add_check(name, sql, expect => 'empty'\|'nonempty'\|'true', target)`, `drop_check(name)` | Checks run on request and inside every merge into their target. |
| `run_checks(branch, cr)` | |
| `create_mask_profile(name)`, `add_mask_rule(profile, tbl, col, expr)`, `build_mask_profile(profile)` | Masked routing schemas. |
| `outbox_poll(consumer, tbl, lim)` | Outbox rows that reached main. |
| `note(actor, reason, meta)` | Attribution for the current transaction. |
| `postgrest_pre_request()`, `postgrest_config(c_module)` | PostgREST / Supabase. |

## Valid time

| Function | |
|---|---|
| `correct(tbl, key, valid_from, valid_to, changes jsonb)` | A correction for `[valid_from, valid_to)`. |
| `apply_scheduled()` | Apply future-dated changes that came due (the heartbeat does). |

## History management

| Function | |
|---|---|
| `set_retention(tbl, policy jsonb)`, `apply_retention(tbl)` | `{"keep_all": "30 days", "daily": "1 year", "monthly": true}` |
| `drop_history_before(tbl, before, force => false)` | Drop whole version partitions; refuses history something still needs (`history_pins()`) unless forced. |
| `archive_partition(tbl, part, uri, rows, checksum)`, `restore_partition(tbl, part)`, `restore_done(tbl, part)` | Used by `gnomon archive` / `restore`. |
| `erase(tbl, key, columns, reason)` | |
| `seal_ledger()`, `verify_ledger()`, `ledger_digest()` | Leaves (format 2) hash a version by table id, key values and one hash per value slot: renames and other DDL leave sealed history verifiable; an erased value is checked against the hash erase() recorded. |
| `doctor(sample)` | |
| `set(name, value)`, view `settings` | |

## More settings

Set with `gnomon.set(name, value)`; the view `gnomon.settings` lists every setting with its
documentation. `stale_approvals` (`dismiss`), `runs_role`, `logged_ttl`
(`off`), `expire_grace` (`7 days`), `merge_window` (`HH:MM-HH:MM`, empty: any time),
`idle_review_after` (`off`), `checkpoints` (`off`), `feed_setbased_min` (`20000`), `feed_c` (`off`; `on`: the C module's feed arm), `thaw_max_rows`,
`thaw_ttl` (`1 day`), `thaw_wait` (`off`), `review_url`, `ddl_lock_timeout` (`5s`), `ddl_concurrent_rows` (`1000000`),
`cold_scans` (`thaw`: a read that needs history in an archive read in place requests a thaw;
`allow`: it scans the archive through its foreign partition; `refuse`: 55000). Every gnomon error's hint ends with a
stable `[gnomon:<slug>]`; [errors.md](errors.md) lists them.

## Developer experience

| Function | |
|---|---|
| `status()` | One JSON document: the branch the session names and whether it is routed there, the as-of reference, SQL core or C module, changes per table, distance from main, warnings, change request and whether its approval is stale, quota used, the last tick's age. |
| `assert_routed()` | Raises when `gnomon.branch` names a branch but unqualified names do not resolve to its routing views (call it at start-up). |
| `describe(schema => null)` | Tables the role can read, columns, keys, foreign keys both ways, tracked/protected/outbox, masked columns, row estimates, and the session's branch, base, write rights and quota. |
| `primary_key(rel)` | The key columns of a table or of its routing view (tools that look keys up on a branch). |
| `explain_error(sqlstate, message)` | What an error means on a branch (upserts in the SQL core, untracked tables, confined roles, slugs), or null. The CLI, the MCP server and the SDKs append it. |
| `api_version()` | 2. The SDKs check it when they connect. |
| `connection_options(branch, c_module => false)` | libpq `options` for a branch: knows scratch branches, the caller's mask profile and the branch's schema version. |
| `use(branch, as_of, local, mode => 'routing'\|'search')`, `begin(branch, as_of, mode)` | As above, plus: the reference is resolved when called; archived history it needs is requested for thawing; `mode => 'search'` puts the search views first. |

## Branches as roles, quotas, expiry

| Function | |
|---|---|
| `assign(role, branch, base_path)`, `unassign(role)` | Every new session of the role starts on the branch (role defaults for `gnomon.branch` and `search_path`). Admin only; a privileged role only by a superuser. |
| `set_quota(scope => 'default'\|'role'\|'branch', name, max_branches, max_rows, max_age, max_children)`, `effective_quota(role, branch)`, `branch_usage(branch)` | Limits. Row and age limits are checked by the heartbeat, which marks a branch over quota; writes to it are refused (53400). |
| `set_branch_ttl(branch, ttl)`, `expire_branches()` | A branch unused for its ttl is closed, then dropped `expire_grace` later (skipped with an open change request or open children). |
| `set_auto_rebase(branch, 'off'\|'clean'\|'always')`, `auto_rebase_branches(idle)` | The heartbeat rebases an idle branch that main has left behind (`clean`: only when the rebase has no conflicts). |
| `rebase(branch, at, dry_run => false)` | `dry_run` reports what a rebase would do and rolls it back. |

## Runs and agents

| Function | |
|---|---|
| `run_start(task, actor, kind, ttl, parent)`, `run_end(branch, keep, outcome)` | A branch for one run, writable by the runs login (`runs_role`); members of `gnomon_runner`. The runs login's transactions are bound to one run each. |
| `run_login(branch)` | A login of the run's own (`gnomon_run_<hash>`, a member of the runs role, confined to the run's branch, its sessions starting there): `{role, password, branch, options}`. What the SDKs' `run.url()` and `run.connection()` hand out; `run_end` drops it and ends its sessions. |
| `agent_create(name, parent, password, mask_profile, allow_create, note)` | A login role `gnomon_agent_<name>`, confined, assigned to branch `<name>/1`, with a token; returns the connection string and the MCP configuration. |
| `agent_next(name, parent)`, `agent_rotate(name)`, `agent_auth(token)`, `agent_stop(name, undo_since)`, `set_agent_budget(name, calls_per_minute, max_result_rows, max_result_bytes)`, view `agent_usage` | A fresh branch per task; a new token; the HTTP server's token check; the kill switch (token off, `NOLOGIN`, sessions ended, branches closed, optionally the agent's merges undone); budgets. |
| `record_call(run, tool, args, branch, coord, xid, rows, digest, error, agent)`, `verify_run(run)` | The hash-chained run record and its check. |
| `done(summary)` | Opens (or comments on) the change request for the session's branch. |

## Review

| Function | |
|---|---|
| `review_stale(review_id)` | Whether the branch changed after the review (stale approvals do not count). |
| `change_request_status(cr)`, `run_summary(branch, run_checks)` | One JSON document each: reviews (stale ones marked), comments, check runs, merge state; or a branch's changes, checks, conflicts a merge would hit, and warnings. |
| `wait_for_review(cr, timeout)` | Returns the status when a review arrives, the request is merged or closed, or the timeout passes. |
| `comment(cr, body, tbl, key, col)`, `resolve_comment(id)` | Comments anchored to a row or a field. |
| `diff_keys(a, b, tbl, after, lim)` | A page of the keys that can differ between two references, in key order. |
| `add_notify_target(name, 'webhook'\|'channel', config, events)` | Where "change request opened" goes: a webhook (delivered by the daemon) or a `NOTIFY` channel. |
| `create_merge_policy(name, agents, rules, target)`, `drop_merge_policy(name)`, `policy_eval(branch, policy)` | Auto-merge policies (rules: `max_rows`, `max_rows_per_table`, `tables`, `columns`, `ops`, `no_stale_reads`, `window`, `max_base_lag`; protected and outbox tables are refused unless `allow_protected`/`allow_outbox`; conflicts stop the merge and checks run in it as always); a caller without `gnomon_merger` may merge a covered branch when every rule holds for the plan. |
| `schedule_merge(branch, at, close, require_checks)`, `cancel_scheduled_merge(id)`, `run_scheduled_merges()` | Merges run later by the daemon, re-checked then. |

## Workflows

| Function | |
|---|---|
| `merge(source, target, ..., strict => false)` | Any open target: siblings merge from their common base; repeat merges from the last one; `strict` refuses to carry the parent's changes a newer source forked with. |
| `cherry_pick(xids, source, target)` | What some transactions of a branch did, applied three-way to another branch. |
| `revert(tbl, at, keys, filter, columns, branch, dry_run)`, `revert_tables(tbls, at, ...)` | Set rows back to their state at a past moment (undoable). |
| `checkpoint(name, branch)`, `rewind(branch, to, dry_run)` | A tag on a branch; set the branch back to it. |
| `dry_run(statements, branch, checks)` | Run statements on a throwaway child, return the diff, checks and warnings, keep nothing. |
| `attempts_create(n, prefix, parent)`, `compare(branches)`, `attempts_pick(group, winner, title)` | Parallel attempts at one coordinate, compared by checks, diff and conflicts. |
| `scenario_create(name, parent, kind, note)`, `scenario_apply(name, sql)`, `add_metric(name, sql, unit)`, `compare(scenarios, metrics, baseline_at)`, `scenario_promote(name, title)` | What-if branches and metrics. |
| `bisect(check, good, bad, branch)` | The transaction where a check started failing. |
| `create_action_table(name, channel, schema)` | A tracked outbox table for side effects that run on merge. |

## Time, graph, metrics

| Function | |
|---|---|
| `history(tbl, key, branch)`, `blame(tbl, key, branch)`, `log(branch, lim)` | On any branch; `on_branch` says where each version was written. |
| `changes(since, until, tables, images => 'none'\|'new'\|'both')` | The feed, with the image mode named (the boolean form still works); includes `truncate` changes. |
| `scd2(tbl, view_name)`, `scd2_changes(tbl, since, until)` | A type-2 slowly changing dimension view, and its incremental feed. |
| `series(tbl, key, col, since, until, branch)`, `metric_series(sql, since, until, step, max_points, branch, timeout)`, `metric_series_incremental(tbl, agg, col, filter, since, until)`, `events(tbl, key, depth, since, until, max_neighbors)` | A value over time, a query at each step, a sum or count from the feed, a row's and its neighbours' changes. |
| `neighbors(tbl, key, depth, direction, max_rows, links)`, `link(name, from_tbl, from_cols, to_tbl, to_cols, filter)`, `impact(branch, max_context)` | Rows related by foreign keys and declared links, through the session's branch and time; a branch's diff as a graph. |
| `metrics(per_branch, max_branches)`, `metrics_text(per_branch)` | Gauges and counters from catalogs; the Prometheus text `/metrics` serves. |
| `history_checkpoint(tbl, at)`, `drop_history_checkpoint(tbl, id)`, `set_checkpoint_policy(tbl, every, keep)`, `run_checkpoint_policies()` | Full images that make past scans cheap (with `checkpoints = on`). |
| `truncate(tbl)` | On main too: a checkpoint, a marker, then the truncate. |
| `thaw_needed(at)`, `request_thaw(at)`, `thaw_status()`, `refreeze_expired()` | Archived partitions a moment needs, and their thawing (the daemon calls `thaw_take`/`thaw_finish`). |
| `CALL thaw(at, wait => '5 minutes')` | Request the thaw a moment needs, commit, and wait until the daemon has restored it (outside a transaction block). With the setting `thaw_wait` (or the session's `gnomon.thaw_wait`), `use()` and `begin()` also wait, for requests made before their transaction. |
| `archive_partition(..., keep => true, format => 1\|2)` | Used by `gnomon archive`: `keep` thins the partition locally instead of dropping it; format 2 is typed Parquet with row groups and Bloom filters on key columns (format 1: text columns). |
| `attach_archive(tbl, part, engine, location)`, `detach_archive(tbl, part)` | Read an archived partition in place: a foreign table over the archive file attached as the history partition, made from an engine's template in `gnomon.archive_engine` (`file_fdw` over the archive's CSV copy, `duckdb_fdw`, `pg_lake`). `gnomon archive --engine` calls it; `restore_partition` detaches first. |
| `set_subject(tbl, subject_col, columns)`, `archive_crypto(tbl)`, `subject_keys(tbl, subjects, create_missing)`, `erase_subject(tbl, subject, reason)` | Crypto-shredding: the archiver encrypts `columns` with a key per data subject (AES-256-GCM); `erase_subject` deletes the key (every archive forgets the subject's values, object-locked stores included), erases the columns in the database, and records it in `gnomon.subject_erased`. Admin only. |
| `dbt_snapshot(tbl, target, consumer)` | Keeps `target` in dbt's snapshot shape (`dbt_scd_id`, `dbt_valid_from`, `dbt_valid_to`, `dbt_updated_at`) from the feed: the first run loads the current rows, later runs apply only what changed; the `gnomon_dbt` package's `gnomon_history` materialization calls it. |

## Sinks and masks

| Function | |
|---|---|
| `sink_add(name, 'webhook'\|'file'\|'nats'\|'kafka'\|'parquet', config, tables, format => 'gnomon'\|'debezium'\|'cloudevents', since)`, `sink_status(name, 'active'\|'paused')`, `sink_replay(name, since)`, `sink_drop(name)` | Deliveries of the feed, run by the daemon (`sink_batch`, `sink_report`). Kafka: `config.brokers` (`host:port`, comma separated), `config.topic` (default `gnomon.changes`; create it first); an idempotent producer, a row's key as the message key. Parquet: `config.to`, a directory or store URL (`s3://`, `gs://`), one file per batch, named by the batch so a retry overwrites its own file. |
| `sink_state(name, state)` | The daemon saves a sink's delivery state (the Kafka producer id, epoch and sequences) in the delivery's transaction. |
| `mask_hash(value, salt)`, `mask_int(value, salt)`, `mask_email(value, salt)` | Deterministic masks for key and foreign-key columns (doctor warns about others there). |
| `save_graph_view(name, tbl, key, depth, branch, at, note)`, `graph_views()`, `drop_graph_view(name)` | Saved views of the review app's graph page; listed for roles that may read the table, changed or dropped by whoever saved them (or gnomon_admin). |
| `verify_ledger()` | As above, and records each run in `gnomon.ledger_verification` for the metrics (`gnomon_ledger_verification_ok`). |
| `_gnomon.c_counters()` | With the C module: its counters summed over every session (shared memory). |

## Schema changes on a branch

| Function | |
|---|---|
| `ddl(statement, up => null, down => null)` | On a branch: runs the statement against the branch's schema version (made on its first DDL) and records it; the session then reads the new shape. On main: plain DDL. Takes `ADD COLUMN` (nullable or a constant default; NOT NULL needs a default), `CREATE TABLE` (with a primary key), `CREATE INDEX` (unique ones become unique constraints of the version), comments; constraints: `SET`/`DROP NOT NULL`, `CHECK`, `UNIQUE`, foreign keys, `DROP CONSTRAINT` of a branch's own, each checked against the branch's rows when added and enforced on its writes; `SET`/`DROP DEFAULT`; `RENAME COLUMN`, `DROP COLUMN`, `ALTER COLUMN ... TYPE` (`up`: main's value in the new type, an expression over the column; `down`: a branch value in main's type, for writes through main's columns; both default to casts), `DROP TABLE`. Refused by name: key columns renamed, dropped or retyped, primary keys and exclusion constraints, volatile defaults, expressions outside `pg_catalog`, statements that reach main. Name tables without a schema. |
| `schema_changes(branch)` | The changes a branch's version carries. |
| `schema_diff(branch)` | Values the branch set in its added columns. |

A branch on a version is merged into main (or a child into its parent on the same version): the
merge replays the DDL on main first (constraints `NOT VALID`, then validated; a type change
converts main's history with `up`). What main has since done in another way is a conflict of
kind `schema`: a table or column the branch changes that main dropped or renamed, a column both
added with different types, a rename onto a name main took, a table both created, a constraint of
the same name with another definition, a foreign key to a table main dropped. The same change
made on both sides is adopted.
