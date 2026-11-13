# Upgrade scripts

`tools/build_upgrade.sh <git ref of the old release> <old version>` writes
`sql/gnomon--<old>--<new>.sql` (and the plain-SQL form under `build/dist/`). Each upgrade is

1. `_prologue.sql`: with the old code still installed, refuse if a user object calls a gnomon
   function (a view, a default, a policy), then take down everything gnomon generates from code
   (event triggers, per-table triggers, routing views, policies, write functions) and drop every
   gnomon function. Data stays: catalog rows, versions, branch tables.
2. Every `NNN_*.sql` migration here, in order. They change tables, types and sequences, and are
   idempotent, so one upgrade script can start from any older version.
3. All of the new version's code: functions, procedures, views, casts, grants, comments, default
   settings, roles and event triggers, taken from the new full script by `tools/build_upgrade.py`.
4. `_epilogue.sql`: hand over to gnomon's `ddl_command_end` trigger, which regenerates every tracked
   table's objects, pass-through views, mask profiles and held outboxes from the new code once
   `ALTER EXTENSION` is done (outside the script, so they stay ordinary objects that pg_dump dumps;
   the update refuses without the trigger). The plain-SQL form runs `_epilogue_plain.sql` instead.

The whole update runs in one transaction (`ALTER EXTENSION gnomon UPDATE`): it either finishes
or leaves the old version in place. It takes ACCESS EXCLUSIVE locks on tracked tables while their
triggers and policies are rebuilt; plan it like other DDL.
