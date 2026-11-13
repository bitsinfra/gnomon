# Errors

Every error gnomon raises ends its hint with a stable code, `[gnomon:<slug>]`. The CLI, the MCP
server and the SDKs also append what `gnomon.explain_error(sqlstate, message)` says about it. The
common ones first:

| Code | What happened, and what to do |
|---|---|
| `upsert_on_branch` | `INSERT ... ON CONFLICT` on a branch in the SQL core: a view has no unique index for PostgreSQL to match. Load the C module, or write it as an `UPDATE` then an `INSERT ... WHERE NOT EXISTS`. |
| `not_tracked` | A write on a branch to a table gnomon does not track: reads see main's rows, writes are refused. `gnomon.track('t')`, or write it on main. |
| `unknown_branch` | No such branch; the message lists open branches with a similar name. `gnomon branch list`. |
| `branch_closed` | The branch is closed or merged and takes no writes. `gnomon.reopen_branch(name)`, or a new branch. |
| `writes_refused_while_as_of` | `gnomon.as_of` is set: the past is read-only. `gnomon.use(branch)` without a time. |
| `confined`, `permission` | The role is confined (it reads and writes its branches only, never main) or lacks a grant. |
| `serialization` | 40001: another transaction changed the row since this statement read it. Retry the transaction (the SDKs do for single statements). |
| `undo_conflict`, `cherry_pick_conflict` | 40001: rows changed after the transactions being undone or picked; nothing was applied. Undo the later changes too, or resolve by hand. (A merge with conflicts is not an error: it returns with status `conflicts`; `gnomon conflicts <merge>`, `gnomon resolve`, then resume.) |
| `approval_stale` | The branch changed after it was approved: review it again (`stale_approvals = keep` restores counting old approvals). |
| `over_quota` | The branch passed a quota: merge or drop work on it, or raise the quota (`gnomon.set_quota`). |
| `ddl_on_branch` | Plain DDL from a branch session: use `gnomon.ddl(...)` for the branch, or `gnomon.use('main')` for main. |
| `volatile_default`, `key_column`, `branch_constraint`, `unique_index`, `unsafe_expression`, `rename_constrained`, `drop_table_referenced` | A schema change `gnomon.ddl` does not take on a branch (a volatile default, a key column renamed, dropped or retyped, a primary key or exclusion constraint, an expression outside `pg_catalog`, a rename of a column a branch constraint uses, a table others reference): do it on main, or another way. |
| `not_null_violated`, `check_violated`, `unique_violated`, `fk_violated` | A constraint added on a branch does not hold for the branch's rows (when added) or for a write. Fix the rows, then add it again. |
| `dropped_on_branch` | The branch's schema version dropped the table. |
| `retype_history` | A type change on main whose values do not cast: history keeps every past value. Change the type on a branch with `gnomon.ddl(..., up => ...)`. |
| `cold_scans` | History in an archive read in place, with `cold_scans = refuse`: set it to `allow` or `thaw`, or `gnomon restore`. |
| `thawing`, `archived` | The read needs archived history: the daemon is restoring it (`gnomon.thaw_status()`), or run `gnomon restore`. |
| `standby_behind` | The standby has not replayed to the coordinate: `gnomon.use(branch, coordinate)` waits for it. |
| `no_heartbeat` | No clock tick in the last minute: reads by timestamp land on an older moment. Run `gnomon daemon`, the C worker or pg_cron. |
| `sql_only_dml` | `SELECT ... FOR UPDATE` takes no row lock on a branch in the SQL core. |
| `run_bound` | The runs login's transaction is bound to another run: one run per transaction. |

All codes, with the SQLSTATE and message they come with (generated from `src/sql`; "…" stands for
a value filled in at run time):

| Code | SQLSTATE | Message |
|---|---|---|
| `access_list_branches_main` | P0001 | the access list is for branches; main is governed by table grants |
| `adding_checks_requires_gnomon_admin` | 42501 | adding checks requires gnomon_admin |
| `admin_required` | 42501 | … requires gnomon_admin |
| `agent_exists` | 42710 | agent "…" exists |
| `agent_stopped` | 55000 | agent "…" is stopped |
| `agg_must_count_sum` | P0001 | agg must be count or sum |
| `approval_stale` | 42501 | change request … was approved, but its branch changed after the approval |
| `archive_engine` | 42704 | no archive engine … |
| `archived` | 55000 | history of … at this coordinate is archived in … |
| `archiving_requires_gnomon_admin` | 42501 | archiving requires gnomon_admin |
| `as_of_future` | P0001 | gnomon.as_of … is in the future |
| `author_change_request_cannot` | 42501 | the author of change request … cannot approve it |
| `bad_expression` | 42804 | the expression … does not work for a … column …: … |
| `bad_key` | 22023 | a row key of … is a JSON object of its key columns (…) |
| `batch_must_least` | P0001 | batch must be at least 1 |
| `between_attempts` | P0001 | between 1 and 100 attempts |
| `branch_can_merged_into` | P0001 | branch "…" can be merged into its parent "…" only |
| `branch_cannot_merged_into` | P0001 | a branch cannot be merged into itself |
| `branch_child_branch` | P0001 | branch "…" has child branch "…" |
| `branch_closed` | 25006 | branch "…" is …; it no longer accepts writes |
| `branch_constraint` | 0A000 | exclusion and primary key constraints cannot be added on a branch |
| `branch_did_not_exist` | P0001 | branch "…" did not exist at … |
| `branch_kind_must_logged` | P0001 | branch kind must be logged or scratch |
| `branch_lineage_too_deep` | P0001 | branch lineage too deep |
| `branch_not_manageable` | 42501 | role … may not manage branch "…" |
| `branch_not_readable` | 42501 | role … may not read branch "…" |
| `branch_not_run` | P0001 | branch "…" is not a run |
| `branch_not_writable` | 42501 | role … may not write branch "…" |
| `branches_share_no_ancestor` | P0001 | branches "…" and "…" share no ancestor |
| `cannot_merge_main_into` | P0001 | cannot merge main into another branch; rebase the branch instead |
| `cannot_resolve_coordinate` | P0001 | cannot resolve "…" to a coordinate |
| `cannot_track_schema` | P0001 | cannot track … in schema … |
| `change_request_required` | 42501 | merges into main require an approved change request |
| `check_fails_good_reference` | P0001 | the check fails at the good reference already |
| `check_passes_bad_reference` | P0001 | the check passes at the bad reference |
| `check_violated` | 23514 | check constraint "…" of relation "…" is violated by some row on the branch |
| `checkpoint_belongs_another_branch` | P0001 | checkpoint "…" belongs to another branch |
| `checks_fail_branch` | 23514 | checks fail on the branch |
| `cherry_pick_conflict` | 40001 | cherry-pick would overwrite changes to … row(s) on "…"; nothing was applied |
| `cherry_pick_onto_branch` | P0001 | cherry-pick onto the branch it came from |
| `choice_must_ours_theirs` | P0001 | choice must be ours, theirs, base or value |
| `cold_scans` | 55000 | history of … at this coordinate is in archives read in place, and cold_scans is refuse |
| `column_does_not_exist` | P0001 | column … of … does not exist |
| `column_uses_prefix_gn` | P0001 | column "…" of … uses the prefix gn_, which gnomon reserves for its storage columns |
| `confined` | (explain_error) | a confined role named a tracked table by its qualified name: it reads and writes through its branch only |
| `confined_role_cannot_approve` | 42501 | confined role … cannot approve change requests |
| `could_not_lock_within` | P0001 | could not lock … within … after … attempts |
| `create_table_exists` | 42P07 | relation ….… exists on main |
| `create_table_key` | 0A000 | a table created on a branch needs a primary key (tracking does): … |
| `ddl_main` | 0A000 | gnomon.ddl prepares branch changes only |
| `ddl_not_prepared` | 55000 | no gnomon.ddl in progress in this session |
| `ddl_nothing` | 0A000 | the statement changed nothing gnomon.ddl understands |
| `ddl_on_branch` | 0A000 | … on a branch session changes main for every branch |
| `ddl_outside_branch` | 42501 | the statement changed real tables, not the branch: name tables without a schema in gnomon.ddl |
| `diff_needs_second_reference` | P0001 | diff(main) needs a second reference |
| `direction_both_out` | P0001 | direction is both, in or out |
| `drop_not_null_column` | 0A000 | dropping ….…: main's NOT NULL column without a default could not be filled by inserts on the branch |
| `drop_table_parent_version` | 0A000 | table … was created by the version this branch stands on: drop it there |
| `drop_table_referenced` | 2BP01 | table … is referenced by another table's foreign key: drop that first |
| `dropped_on_branch` | 42P01 | relation "…" does not exist on this branch (its schema version dropped it) |
| `erasure_requires_gnomon_admin` | 42501 | erasure requires gnomon_admin |
| `feed_consumer_belongs_role` | 42501 | feed consumer "…" belongs to role … |
| `feed_poll_needs_limit_least` | P0001 | feed_poll needs a limit of at least 1 |
| `fk_outside` | 0A000 | a foreign key on a branch references a table of the schema, by its name without a schema |
| `fk_violated` | 23503 | foreign key "…" is violated by some row on the branch |
| `graph_view_missing` | 42704 | no graph view "…" |
| `graph_view_owner` | 42501 | graph view "…" belongs to … |
| `graph_view_table` | 42501 | role … may not read … |
| `history_before_retention_horizon` | 22023 | history of … before the retention horizon has been dropped |
| `history_checkpoints_known_time` | 0A000 | history checkpoints are for known-time tables |
| `images_must_none_new` | 22023 | images must be none, new or both, not … |
| `index_function` | 0A000 | an index on a branch may call pg_catalog functions only |
| `invalid_coordinate` | P0001 | invalid gnomon coordinate "…" |
| `key_column` | 0A000 | a key column cannot be dropped on a branch: ….… |
| `key_columns_cannot_erased` | P0001 | key columns cannot be erased; delete the row and erase its other columns |
| `logged_branch_cannot_created` | P0001 | a logged branch cannot be created from scratch branch "…" |
| `main_cannot_closed` | P0001 | main cannot be closed |
| `main_cannot_dropped` | P0001 | main cannot be dropped |
| `main_constraint` | 0A000 | main's NOT NULL on ….… stays on the branch's writes: drop it on main |
| `main_does_not_expire` | P0001 | main does not expire |
| `main_no_base` | P0001 | main has no base |
| `managing_needs_gnomon_admin_ownership` | 42501 | managing … needs gnomon_admin and ownership of the table |
| `masked_roles_write_branches` | 42501 | masked roles write branches only |
| `merge` | P0001 | merge … is … |
| `merge_carries` | P0001 | branch "…" forked later than "…" and would carry its parent's changes in between |
| `merge_not_applied` | P0001 | merge … is not applied |
| `merge_not_fully_applied` | P0001 | merge … is not fully applied |
| `merge_not_incremental_merge` | P0001 | merge … is not an incremental merge |
| `merge_not_merge_branch` | P0001 | merge … is not a merge of branch "…" |
| `merge_rolled_back_checks` | 23514 | merge … rolled back: checks failed on the merged state: … |
| `merge_window` | 55000 | merges into main run between … and … only |
| `merge_window_must_look_like` | P0001 | merge_window must look like 09:00-17:00, not … |
| `merger_required` | 42501 | undo on main requires membership in gnomon_merger |
| `merging_into_main_requires` | 42501 | merging into main requires membership in gnomon_merger |
| `mode_must_atomic_incremental` | P0001 | mode must be atomic or incremental |
| `mode_must_known_bitemporal` | P0001 | mode must be known or bitemporal |
| `mode_off_clean_always` | P0001 | mode is off, clean or always |
| `mode_routing_search` | P0001 | mode is routing or search |
| `must_tracked_act_held` | P0001 | … must be tracked to act as a held outbox |
| `no_agent` | 42704 | no agent "…" |
| `no_change_request` | P0001 | no change request … |
| `no_checkpoint` | 42704 | no checkpoint "…" |
| `no_column` | 42703 | column … does not exist in … |
| `no_comment` | 42704 | no comment … |
| `no_conflict` | P0001 | no conflict … |
| `no_heartbeat` | (status) | no tick in the last minute: reads by timestamp resolve to an older moment |
| `no_history_before_tracked` | 22023 | gnomon has no history of … before it was tracked at … |
| `no_merge` | P0001 | no merge … |
| `no_partition` | P0001 | no partition … of … |
| `no_pending_scheduled_merge` | P0001 | no pending scheduled merge … of yours |
| `no_runs_role` | 55000 | no runs login: set gnomon.set('runs_role', <role>) first |
| `no_scenario` | 42704 | no scenario "…" |
| `no_sink` | 42704 | no sink "…" |
| `no_subject` | 22023 | … has no data subject (gnomon.set_subject) |
| `no_tick_before` | P0001 | no gnomon tick at or before … |
| `not_approved` | 42501 | change request … for this branch is not approved |
| `not_archived` | 55000 | partition … of … is not archived and dropped |
| `not_attempt` | P0001 | "…" is not an attempt of … |
| `not_bitemporal` | P0001 | … is not bitemporal |
| `not_null_violated` | 23502 | column "…" of relation "…" contains null values on the branch |
| `not_null_without_default` | 0A000 | a NOT NULL column needs a default on a branch: ….… |
| `not_on_branch` | P0001 | gnomon.done() is called on a branch |
| `not_routed` | 55000 | session is on branch "…" but its search_path does not route there |
| `not_run_login` | 42501 | not a run of this login |
| `not_table` | P0001 | … is not a table |
| `not_tracked` | 42501 | ….… is not tracked, so a branch cannot write it (reads on a branch see main's rows) |
| `open_change_requests_branch` | P0001 | open change requests from a branch |
| `other_tables_reference_truncate` | 0A000 | other tables reference …; truncate them with it or delete |
| `over_quota` | 53400 | branch "…" is over its quota: … |
| `partition_empty` | P0001 | partition … of … is empty |
| `permission` | (explain_error) | the role lacks a grant, or is confined |
| `permission_denied_table` | 42501 | permission denied for table … |
| `policy_refused` | 42501 | merge of "…" refused by policy …: … |
| `protected_table_changes_through` | 42501 | protected table … changes only through merges |
| `read_only` | (explain_error) | `gnomon.as_of` is set, or the branch is closed or merged |
| `reads_tracked_branches` | P0001 | reads are tracked on branches |
| `rename_constrained` | 0A000 | column ….… is named by a constraint this branch added: drop the constraint first |
| `requires_gnomon_admin` | 42501 | this requires gnomon_admin |
| `restoring_requires_gnomon_admin` | 42501 | restoring requires gnomon_admin |
| `retype_history` | (the cause's) | gnomon cannot convert the history of a column to …: … |
| `revert_needs_moment_go` | P0001 | revert needs a moment to go back to |
| `revert_works_known_time` | 0A000 | revert works on known-time tables; bitemporal tables are corrected with gnomon.correct |
| `rewind_branches_main_reverted` | P0001 | rewind is for branches; main is reverted with gnomon.revert |
| `role_confined_may_not` | 42501 | role … is confined and may not write branch "…" |
| `role_does_not_exist` | P0001 | role … does not exist |
| `role_exists_already` | 42710 | role … exists already |
| `role_may_not_branch` | 42501 | role … may not branch from "…" |
| `role_may_not_change` | 42501 | role … may not change branch "…" |
| `role_may_not_close` | 42501 | role … may not close branch "…" |
| `role_may_not_drop` | 42501 | role … may not drop branch "…" |
| `role_may_not_end` | 42501 | role … may not hand out run "…" |
| `role_may_not_manage` | 42501 | role … may not manage branch "…" |
| `role_may_not_move` | 42501 | role … may not move agent "…" |
| `role_may_not_read` | 42501 | role … may not read branch "…" |
| `role_may_not_rebase` | 42501 | role … may not rebase branch "…" |
| `role_may_not_record` | 42501 | role … may not record agent calls |
| `role_may_not_reopen` | 42501 | role … may not reopen branch "…" |
| `role_may_not_write` | 42501 | role … may not write branch "…" |
| `role_privileged_superuser_assigns` | 42501 | role … is privileged; only a superuser assigns it |
| `role_who_scheduled_no` | 42501 | role … who scheduled it is no longer a merger |
| `row_changed_concurrently` | 40001 | row changed concurrently |
| `row_key_required` | P0001 | a row key is required |
| `run_bound` | 42501 | this transaction is bound to another run |
| `run_ended` | 55000 | run "…" has ended |
| `run_summary_branch` | P0001 | run_summary is for a branch |
| `runner_required` | 42501 | starting a run requires gnomon_runner |
| `runs_role_unconfined` | 55000 | the runs login … must be confined (gnomon.confine) |
| `sample_fraction` | P0001 | sample is a fraction from 0 to 1 |
| `scd2_views_known_time` | 0A000 | scd2 views are for known-time tables; bitemporal tables already have both axes |
| `schedule_merge_branch` | P0001 | schedule the merge of a branch |
| `schema_not_allowed` | 42501 | role … may not change the schema of branch "…" |
| `schema_one_schema` | 0A000 | schema changes on a branch need the tracked tables in one schema |
| `schema_scratch` | 0A000 | schema changes are for logged branches |
| `schema_version_main` | 25006 | branch-only columns are written on their branch |
| `schema_version_owner` | 0A000 | branch "…" stands on schema changes made on "…": merge that branch first |
| `schema_version_routing` | 0A000 | (C module) branch "…" is on schema version …, which SET gnomon.branch alone does not route |
| `schema_version_target` | 0A000 | branch "…" is on schema version … and "…" is not: merge it into main |
| `scope_must_default_role` | P0001 | scope must be default, role or branch |
| `scratch_branch_lost_server` | 55000 | scratch branch "…" was lost in a server restart |
| `scratch_branch_not_replicated` | 0A000 | scratch branch "…" is not replicated: its tables are unlogged |
| `scratch_branch_read_through` | 55000 | scratch branch "…" is read through the gnomon_r_<schema>__s routing schemas |
| `search_checkpoint` | 0A000 | search views do not read through history checkpoints |
| `search_confined` | 42501 | search views are for logged branches and for roles that may read the tables themselves |
| `sequence_grant` | (explain_error) | the role cannot draw from a sequence behind a column default |
| `serialization` | (explain_error) | another transaction changed the row since the statement read it |
| `session_branch_write_names` | 25006 | this session is on branch "…": a write to … names main's table and would change main |
| `sink_config` | 22023 | a kafka sink needs config.brokers (host:port, comma separated) and config.topic |
| `sql_only_dml` | (status, MCP) | upserts and `FOR UPDATE` on a branch in the SQL core |
| `standby_behind` | 55000 | this standby may not have replayed coordinate … yet |
| `standby_not_replayed_within` | 55000 | standby has not replayed to … within … |
| `status_active_paused` | P0001 | status is active or paused |
| `subject_columns` | 22023 | encrypted columns must exist and be neither key columns nor the subject column |
| `sum_needs_column` | P0001 | a sum needs a column |
| `system_column_on_branch` | 0A000 | (C module) system column "…" of … is not available on a branch |
| `table_named_gnomon_run_bind_does` | 42501 | a table named gnomon_run_bind that gnomon does not own is in the way |
| `table_no_primary_key` | P0001 | table … has no primary key |
| `table_protected_changes_reach` | 42501 | table ….… is protected: changes reach it only through gnomon.merge |
| `tag_belongs_role` | 42501 | tag "…" belongs to role … |
| `target_branch` | P0001 | target branch "…" is … |
| `thaw_failed` | 55000 | thawing partition … of … failed: … |
| `thaw_too_large` | 54000 | a read at … needs … archived row(s) thawed, more than thaw_max_rows (…) |
| `thawing` | 55000 | history of … at this coordinate is being thawed from the archive: … partition(s), … row(s); retry shortly |
| `thawing_requires_gnomon_admin` | 42501 | thawing requires gnomon_admin |
| `there_no_history` | P0001 | there is no history of … at … |
| `token_lookups_s_server` | 42501 | token lookups are for gnomon's server |
| `too_many_points` | 54000 | more than … points from … to … by … |
| `tracking_key_columns_must` | P0001 | tracking key columns of … must exist and be NOT NULL |
| `tracking_key_not_covered` | P0001 | tracking key (…) of … is not covered by a unique index |
| `truncate_bitemporal_table_delete` | 0A000 | TRUNCATE of a bitemporal table: delete its rows |
| `truncate_refused_tracked_table` | 0A000 | TRUNCATE is refused on gnomon-tracked table … |
| `undo_conflict` | 40001 | undo would overwrite later changes to … row(s); nothing was undone |
| `unexpanded_template_token` | P0001 | unexpanded template token … |
| `unique_index` | 0A000 | a unique index on a branch takes plain columns |
| `unique_violated` | 23505 | could not add unique constraint "…": the branch has duplicate values |
| `unknown_branch` | 42704 | unknown gnomon branch "…" |
| `unknown_branch_coordinate` | P0001 | unknown branch or coordinate "…" |
| `unknown_feed_consumer` | P0001 | unknown feed consumer "…" |
| `unknown_mask_profile` | P0001 | unknown mask profile "…" |
| `unknown_merge_strategy` | P0001 | unknown merge strategy "…" |
| `unknown_tag` | P0001 | unknown gnomon tag "…" |
| `unsafe_expression` | 42501 | … on a branch may use pg_catalog functions and operators only, not … |
| `upsert_on_branch` | (explain_error) | `INSERT ... ON CONFLICT` on a branch in the SQL core |
| `valid_to_must_after_valid_from` | P0001 | valid_to must be after valid_from |
| `volatile_default` | 0A000 | column ….… has a default that cannot be copied to every row: … |
| `writes_refused_while_as_of` | 25006 | writes are refused while gnomon.as_of is set (reading the past is read-only): … would change main now |
