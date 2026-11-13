# Security

## Roles

| Role | Purpose |
|---|---|
| `gnomon_reader` | Owns the routing views and the history arm. SELECT only. The branch-filter policies apply to it. Never grant it to application roles: its restrictive policy would then filter their reads of main. |
| `gnomon_reader_s` | Owns the scratch-branch routing views (`gnomon_r_<schema>__s`). A member of `gnomon_reader`, plus SELECT on the unlogged branch tables; one more restrictive policy (unlogged touched keys) applies to it. The same rule: never grant it to application roles. |
| `gnomon_writer` | Owns the versioning triggers and branch-write functions (`SECURITY DEFINER`, `search_path` pinned). Holds the only DML on branch storage and version tables. |
| `gnomon_merger` | Membership is needed to merge into main, undo on main, or (through merges) change protected tables. Has `BYPASSRLS` so merges apply regardless of user policies. |
| `gnomon_admin` | Tracking the tables it owns (track, untrack, sync, retention, merge strategies, protection, outboxes), the heartbeat, dropping and archiving history, erasure, checks. Has `BYPASSRLS`. Also: assigning roles to branches, quotas, agents, merge policies, sinks, notification targets, the daemon's thaw and sink jobs. |
| `gnomon_runner` | May start and end SDK runs (`run_start`, `run_end`): an application login that hands branches to the shared runs login (`runs_role`). |
| `gnomon_search` | Owns the search views (`gnomon_q_<schema>`). Has only the permissive policy on tracked tables, so the views' branch filter is an ordinary `WHERE` that indexes can serve. Never grant it to anyone. |

Application roles get no grants on schema `_gnomon` tables. Grants on a tracked table are mirrored
onto its routing view (and re-mirrored on every GRANT/REVOKE by the event trigger).

## Confinement

`gnomon.confine(role, branches)` revokes the role's DML on base tables, removes it from
`gnomon_merger`, and records which branches it may write (`gnomon.acl`; branches it creates are
added). Branch writes check the acl inside the definer path, so a confined role sending arbitrary
SQL still cannot write main or another branch, merge, or undo on main. `cli/internal/mcp`'s agent
test sends exactly such SQL through the MCP `execute` tool and checks each refusal. A mask profile
additionally removes SELECT on base tables and routing views; the role reads through masked views.

**Read isolation.** A confined role reads only the branches in its access list and
their ancestors; the check runs once per statement in `_ctx_compute` and raises 42501. The shared
runs login (`runs_role`) is in every run's access list, so each of its transactions is bound to one
run when it calls `gnomon.begin(run)`, and it reads only that run's branch.

**A role is a branch.** `gnomon.assign(role, branch)` sets the role's defaults for
`gnomon.branch` and `search_path`. Only gnomon_admin assigns, and only a superuser assigns a role
that is a superuser, has `BYPASSRLS` or is a gnomon_admin member. The defaults are a convenience,
not the boundary: a confined role that resets them still writes only its branches, and with no
grant on the base tables a qualified name fails instead of reading main.

**Agents and tokens.** `gnomon.agent_create` makes a login role confined to its own
branch with no grant on base tables, and a token for the MCP HTTP transport. Tokens are stored as
SHA-256 hashes; `agent_auth(token)` (gnomon_admin and gnomon_runner only) maps one to its role,
which the server then `SET ROLE`s to in the request's transaction. `agent_stop` disables the token,
sets the role `NOLOGIN`, ends its sessions where the caller may, closes its branches and change
requests, and can undo the merges of branches the agent created. The run record
(`gnomon.agent_call`) is written through an insert-only definer function and hash-chained per run;
agents cannot read it, gnomon_admin and gnomon_merger can, and `verify_run` checks the chain.

**HTTP.** `gnomon serve` and `gnomon mcp --http` log in as one role that is a member of every
role they act as and issue `SET ROLE` per request inside a transaction, so every check in the
database applies to the person or agent. The review app takes a database login or a trusted proxy's
header (with a role map), sets a CSRF token for writes, and binds to 127.0.0.1 by default.

**Schema changes on a branch.** `gnomon.ddl` runs the statement as the caller against a
shadow schema the caller owns, so it can do nothing the caller could not do by hand; a statement
that touches real tables is detected and rolled back. What the merge later runs on main with
gnomon's rights is derived from the catalogs, never the statement's text: column definitions with
constant defaults, moving the hidden table, index definitions whose expressions call `pg_catalog`
functions only, and comments. A merger should still read `gnomon schema <branch>` before merging.

## Row-level security

On tables without user policies gnomon enables RLS with a permissive `true` policy for everyone
(no effect on query plans) plus the restrictive arm-1 policy for `gnomon_reader` only.
Tables that already use RLS keep their policies; gnomon adds no `true` policy and compiles the
user's SELECT policies into `gnomon_reader` policies evaluated for the caller (`current_user`
inside a policy reached through a view is the caller), on main's table, the branch heads, and the
history arm. Superusers, `BYPASSRLS` roles and the table owner (unless RLS is forced) bypass, as on
main. Branch writes are checked against the table's INSERT, UPDATE and DELETE policies as the
caller, in the routing view's (invoker) INSTEAD OF trigger, before the definer write path: what
main would refuse, the branch refuses, so a merge cannot publish rows their writer could not have
written. Whether the table's own RLS is in force is re-evaluated on every DDL to it: RLS enabled
without policies stays deny-all, and policies created after tracking replace gnomon's permissive
policy instead of being OR'ed with it. Tested in `06_ops` (two roles on a branch; a deny-all
table; policies added after tracking; write policies; RLS turned off again; untrack).

## Writes to main from a branch session

A session on a branch (or reading the past) that names a tracked table with its schema
(`public.t`) would write main in SQL-only mode; the versioning triggers refuse it (25006). gnomon's
own writes to main (merges, undo) carry a merge token, which lets them through. Writes to main
through a routing view (PostgREST profiles do this) that would overwrite a row changed since the
statement read it raise 40001 instead.

## Every SECURITY DEFINER path

All pin `search_path = pg_catalog, pg_temp`. Generated SQL qualifies every name and uses
`OPERATOR(schema.=)` for comparisons, so a caller's objects cannot capture them. Functions owned
by the extension owner run with its rights and check the caller (`_gnomon.who()`: the `SET ROLE`
target, else the session user) where noted.

| Function | Owner | Callable by | Check inside |
|---|---|---|---|
| `_gnomon.<t>__trg`, `__strg` | gnomon_writer | trigger only | none needed (fires on the user's own write) |
| `_gnomon.<t>__bw` | gnomon_writer | public | caller's privilege on the routing view, branch status, `as_of` unset, confinement acl, fingerprint when event triggers are off |
| `_gnomon.<t>__bwi`, `__bwi_u` | gnomon_writer | gnomon's definer code only | (internal) |
| `_gnomon.<t>__vrow` | gnomon_reader | public | returns nothing unless the caller may SELECT the table |
| `_gnomon.<t>__rid` | gnomon_writer | revoked from public | (internal) |
| `_gnomon.blob_get` / `blob_put` | owner | get: public (values are only reachable by hash from version rows the caller can read); put: gnomon_writer | |
| `_gnomon.candidate_keys`, `touched_since` | owner | public | caller may SELECT the table |
| `_gnomon.masked_write` | owner | public | `_write_check` (privilege on the masked view, branch status, no as-of, confinement acl), main refused |
| `_gnomon.merge_token`, `is_apply`, `bt_write_point`, `bt_sync_current` | owner | revoked | (internal) |
| `_gnomon.protect_check` | owner | trigger only | merge token of the current transaction |
| `gnomon.merge`, `undo_xids` | owner | public | gnomon_merger for main; acl for branch targets |
| `gnomon.rebase`, `truncate` | owner | public | may write the branch (acl for confined roles) |
| `gnomon.create_branch` | owner | public | confined roles: `allow_create`, and the acl for the parent |
| `gnomon.drop_branch`, `close_branch`, `reopen_branch` | owner | public | creator, gnomon_admin or gnomon_merger member, or acl |
| `gnomon.review`, `open_change_request` | owner | public | authors cannot approve their own request; confined roles cannot approve |
| `gnomon.add_check` | owner | public | gnomon_admin (checks run inside merges with gnomon's rights) |
| `gnomon.correct` | owner | public | UPDATE privilege on the table |
| `gnomon.history`, `changes`, `_gnomon.changes_page` | owner | public | caller may SELECT the table (unreadable tables are skipped) |
| `gnomon.feed_create`, `feed_poll`, `feed_drop` | owner | public | a consumer belongs to its creator (or gnomon_admin) |
| `gnomon.track`, `untrack`, `sync`, `set_write_mode`, `protect`, `outbox`, `set_retention`, `_gnomon.store_merge_strategy`, `gnomon.use_c_trigger` | owner | public | `_gnomon.require_manage`: superuser, gnomon's installer, or a gnomon_admin member that owns the table |
| `gnomon._minc_start`, `_minc_resume`, `_minc_keys`, `_minc_step`, `_minc_next`, `_minc_finish`, `_minc_failed` | owner | public | as `gnomon.merge` (target check, approval gate, stale reads), and the merge record's state: a batch is applied once |
| `gnomon.create_tag`, `drop_tag` | owner | public | dropping: the tag's creator or gnomon_admin |
| `gnomon.track_reads` | owner | public | may manage the branch |
| `gnomon.history_pins`, `_gnomon.has_cleared`, `_tick_due` | owner | public | read-only |
| `gnomon.erase`, `archive_partition`, `restore_partition` | owner | public | gnomon_admin |
| `gnomon.heartbeat`, `apply_retention`, `apply_scheduled`, `drop_history_before`, `seal_ledger`, `restore_done` | owner | gnomon_admin | gnomon_admin (where callable directly) |
| `gnomon.watch`, `sweep_scratch`, `verify_ledger`, `doctor` | owner | public | read-only or policy-driven; reveal counts and status only |
| `gnomon.note` | owner | public | records attribution for the caller's own transaction only |
| `gnomon._log_xact`, `_do_tick`, `tick`, `_purge_branch_rows` | owner | revoked (gnomon roles only) | (internal; `tick` for gnomon_admin) |
| `gnomon._lock_row`, `_note_read` | owner | public | UPDATE privilege for locks; read sets only record the session's own branch |
| `gnomon._write_check`, `_ctx_clear`, `_touch`, `_bump`, `current_epoch` | owner | public | harmless: checks, cache, last-used time, epoch registration |

Agents, runs, policies and workflows:

| Function | Owner | Callable by | Check inside |
|---|---|---|---|
| `gnomon.assign`, `unassign`, `set_quota`, `agent_create`, `agent_rotate`, `agent_stop`, `set_agent_budget`, `create_merge_policy`, `drop_merge_policy`, `add_notify_target`, `sink_*`, `thaw_take`, `thaw_finish` | owner | public (sink and thaw jobs: gnomon_admin) | gnomon_admin (`_gnomon.require_admin`); assigning a privileged role needs a superuser |
| `gnomon.agent_next` | owner | public | gnomon_admin, or the role that created the agent |
| `gnomon.agent_auth`, `record_call` | owner | public | gnomon_admin or gnomon_runner (the HTTP server's login); `record_call` only appends |
| `gnomon.verify_run` | owner | gnomon_admin, gnomon_merger | read-only |
| `gnomon.run_start`, `run_end` | owner | public | gnomon_runner member; `run_end` also the branch's manager |
| `gnomon.set_branch_ttl`, `set_auto_rebase` | owner | public | may manage the branch |
| `gnomon.allow`, `run_checks`, `undo_merge` | owner | public | may manage the branch; may write the branch; gnomon_merger for main |
| `gnomon.schedule_merge`, `cancel_scheduled_merge` | owner | public | gnomon_merger; the daemon re-checks the scheduler's rights and the approval when it runs the merge |
| `gnomon.cherry_pick` | owner | public | may read the source; the target check of `gnomon.merge` |
| `gnomon.done`, `comment`, `resolve_comment` | owner | public | may write (done) or read (comment) the change request's branch |
| `gnomon.history_checkpoint`, `drop_history_checkpoint`, `set_checkpoint_policy`, `scd2` | owner | public | `_gnomon.require_manage` (the table's manager) |
| `gnomon.request_thaw` | owner | public | none: it only queues partitions a read at that moment needs, bounded by `thaw_max_rows` |
| `gnomon.review_stale`, `_gnomon.branch_head` | owner | public | read-only |
| `gnomon._ctx_ck`, `_may_read_branch`, `_run_bound` | owner | public | read-only context functions used by the views and checks |
| `_gnomon.ddl_prepare`, `_gnomon.ddl_record` | owner | public (through `gnomon.ddl`) | may write the branch, not confined, logged branch; record only what this backend prepared, as the same role |
| `_gnomon.set_branch_column`, `branch_column_value` | owner | public (the version views) | `_write_check` on the table's routing view; reads at the session's lineage |
| `_gnomon.merge_schema`, `merge_schema_gate`, `merge_branch_columns`, `drop_branch_version`, `gen_version`, `build_shadow` | owner | revoked | (internal to the merge, `gnomon.ddl` and `drop_branch`) |
| `_gnomon.expr_safe`, `index_safe`, `require_safe`, `require_safe_rel` (inside `gnomon.ddl`) | owner | revoked | every expression `gnomon.ddl` records that gnomon later evaluates with its own rights may call `pg_catalog` functions and operators only: `up` and `down` (compiled into a throwaway view, its `pg_depend` rows checked), index expressions and predicates, and new check constraints, column defaults and the checks of domain-typed columns (their `pg_depend` rows in the shadow). Otherwise a function the caller wrote would run as gnomon when `ddl_record` checks the branch's rows against a new constraint, and as the merger when the merge validates it on main or inserts rows. Pre-existing defaults and checks of main's tables are not re-checked: main's owner put them there |
| `gnomon.run_login` | owner | public | the run's creator, or a gnomon_runner member that is not confined. Creates a login role (`gnomon_run_<hash>`: the extension owner needs `CREATEROLE`), a member of the runs role, confined to the run's branch, with its sessions starting there; a second call rotates the password. `run_end` ends its sessions and drops it |
| `gnomon.attach_archive`, `detach_archive` | owner | public | gnomon_admin. The engine's template comes from `gnomon.archive_engine` (writable by the installer only); the location is quoted as a literal |
| `gnomon.set_subject` | owner | public | `_gnomon.require_manage` (the table's manager) |
| `gnomon.archive_crypto`, `subject_keys` | owner | gnomon_admin | gnomon_admin: the keys are the archives' only protection |
| `gnomon.erase_subject` | owner | public | gnomon_admin |
| `gnomon.sink_state` | owner | public | gnomon_admin (the daemon's job) |
| `gnomon.save_graph_view`, `graph_views`, `drop_graph_view` | owner | public | saving needs SELECT on the view's table (its key is a value of the table); the list shows views on tables the caller may read; changing or dropping one needs its creator or gnomon_admin |
| `_gnomon.c_feed` (C module) | gnomon_c's installer | revoked (called by `gnomon.changes`, a definer, after its own `can_read` checks) | runs the arm query it is given |
| `_gnomon.search_grants` | owner | (internal, on GRANT and REVOKE) | search views are granted only to roles holding SELECT on the table, never to confined ones |

`test/sql/09_security.sql` runs an ordinary role and a confined role against these and expects a
refusal for each operation it must not perform.

## Known limits

- User triggers mirrored onto branches run as `gnomon_writer`; a table owner can therefore run code
  with `gnomon_writer`'s rights by adding a trigger to their own tracked table. Treat table ownership
  as trusted, or keep tracked tables owned by a role you trust.
- Checks (`gnomon.add_check`) are arbitrary SQL run inside merges; only gnomon_admin can add them.
- `gnomon_merger` is a member of `gnomon_writer` and so has DML on branch storage tables: grant it
  only to roles trusted with main.
- Custom merge strategies run inside `gnomon.merge` with gnomon's rights; only the roles that may
  manage a table (a superuser, gnomon's owner, or a gnomon_admin member that owns it) can set one.
- Erasure cannot reach WAL, base backups or replicas until they expire. Crypto-shredding reaches
  archives at once, but the subject keys are rows of `_gnomon.subject_key` and so are in WAL,
  backups and `pg_dump` output until those expire: an erased subject's archived values stay
  recoverable by whoever holds such a backup and the archive.
- A run's login (`run_login`) is a real role with a password; anyone holding its connection string
  can work on that run's branch until `run_end`. It is confined, so it never reaches main or other
  branches.
- The Kafka sink speaks plaintext only (no TLS or SASL): keep it on a private network, or use a
  webhook into a REST proxy.
- With the C module, a branch session's DDL on tracked tables runs as `gnomon.ddl(statement)`, so
  the same checks apply as when it is called directly (the statement runs as the caller against
  the shadow; recorded expressions may use `pg_catalog` only).
- Search views evaluate the branch filter as an ordinary `WHERE`, so a function in a query can see
  a main row the branch hides. That is why only roles that may read the table itself get them.
- `gnomon._in_ddl` and `gnomon._ddl_internal` are ordinary custom settings any session can set; they
  turn off gnomon's DDL event triggers (and the refusal of plain DDL from a branch session) for that
  session. They guard against accidents, not against a role that may run DDL anyway.
- Notification and sink webhooks carry change data to the URLs gnomon_admin configures; secrets in
  their configuration are readable by gnomon_admin members.
- With the C module, `gnomon.c_module` and the hooks are global to the server; routing is skipped
  inside gnomon's own code (detected by its pinned search path) and while `gnomon._in_ddl` is set.
