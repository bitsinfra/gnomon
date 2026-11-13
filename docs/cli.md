# CLI reference

One static binary carries the command line, the MCP server, the review app and the job loop.

```bash
gnomon [--dsn DSN] [--branch b] [--json] <command> [args]
```

The connection comes from `--dsn`, `GNOMON_DSN`, or the libpq environment (`PGHOST`, `PGPORT`,
`PGUSER`, `PGDATABASE`). `--branch` runs one command on a branch without changing your session, and
`--json` prints machine-readable output for every command. `gnomon <command> --help` prints the
usage of one.

## Getting set up

| | |
|---|---|
| `init [--schema public] [--no-heartbeat]` | From an empty database to a tracked schema with a heartbeat running. |
| `track <table> [--bitemporal] [--statement] [--protected]`, `track --schema s` | Start versioning. |
| `untrack <table> [--keep-history]`, `sync [table]` | Stop; re-generate Gnomon's objects after DDL. |
| `doctor` | Consistency and configuration checks. |
| `status` | Where this session is: branch, routing, changes, warnings, change request, quota. |

## Branches

| | |
|---|---|
| `branch create\|list\|drop\|close\|reopen\|url ...` | Manage branches; `url` prints a connection string. |
| `diff <a> [b] [--table t]` | Changes between two references (branch, main, coordinate, `tag:x`, timestamp). |
| `merge <branch> [--into target] [--preview] [--incremental] [--resume id] [--close]` | Three-way merge. |
| `conflicts <merge-id>`, `resolve <conflict-id> ours\|theirs\|base\|value [json]` | Settle a merge. |
| `rebase <branch> [--dry-run]` | Carry a branch onto its parent's current state. |
| `cherry-pick <xid>... --from <branch> [--onto main]` | Apply some transactions elsewhere. |
| `migrate <branch> [--dry-run] -- <file.sql>...` | Migration files on a branch, in one transaction. |
| `schema <branch>` | The schema changes a branch carries. |
| `dry-run [-f file.sql] [statement ...]` | Run statements on a throwaway branch and show the diff. |
| `checkpoint <name>`, `rewind <branch> <checkpoint> [--dry-run]` | Savepoints for a branch. |
| `export --branch b [--mask profile] [--as-of ref] --to <dsn\|dir>` | A branch as a database of its own. |

## History

| | |
|---|---|
| `log [--limit n] [--branch b]` | Commit log and merges. |
| `history <table> <key>`, `blame <table> <key>` | Every version of a row; who last changed each field. |
| `bisect <check\|sql> --good <ref> [--bad now]` | The transaction where a check started failing. |
| `undo <xid>`, `undo --merge id`, `undo --role r --since ts` | Revert through the merge engine. |
| `revert <table> --at <ref> [--key json] [--where sql] [--dry-run]` | Rows back to a past moment. |
| `tag <name> [--at ref]`, `tag --list` | Name a coordinate; it pins retention. |
| `checkpoints create <table> [--at ref] \| list \| drop \| policy <table> --every 1d` | Cheap past scans. |
| `graph <table> <key> [--depth 1]`, `graph impact <branch>` | Related rows; what a branch touches. |

## Review

| | |
|---|---|
| `cr open <branch> <title>`, `cr review <id> approve\|reject\|comment [body]`, `cr list`, `cr checks <branch>` | Change requests. |
| `serve [--addr 127.0.0.1:8090] [--mcp]` | The review app, its JSON API and `/metrics`; with `--mcp`, the MCP HTTP transport at `/mcp`. |
| `schedule <branch> --at <time> [--close]`, `schedule list\|cancel <id>` | Merge later. |

## Agents

| | |
|---|---|
| `agent create\|list\|show\|next\|rotate\|budget\|stop\|replay ...` | Confined roles on branches, with tokens. |
| `policy create <name> --agents a,b --rules json`, `policy eval <branch>` | Auto-merge rules. |
| `quota set default\|role\|branch [name] [--branches n] [--rows n]`, `quota show` | Limits on branches. |
| `attempts create <n> <prefix>`, `attempts compare <branch>...`, `attempts pick <prefix> <winner>` | Parallel tries. |
| `scenario create\|apply\|compare\|promote\|metric ...` | What-if branches compared by metrics. |
| `mcp [--http host:port]` | The MCP server, over stdio, or over HTTP on that address. |
| `describe [schema]` | The database as an agent sees it, as JSON. |
| `types --lang ts\|py [--schema s]` | A type per tracked table, for the SDKs. |

## Running it

| | |
|---|---|
| `daemon [--interval 1s] [--no-heartbeat]` | The heartbeat and the job loop: ticks, schedules, warnings, the ledger, thaws, scheduled merges, notifications and sinks. |
| `feed --consumer c [--since ref] [--follow] [--limit n]` | Tail the exact change feed. |
| `sink add\|list\|pause\|resume\|drop\|replay\|dead ...` | Deliver the feed to webhooks, files, NATS, Kafka or Parquet. |
| `archive`, `restore`, `thaw status\|request <ref>` | Old history to object storage, and back when a read needs it. |
| `subject set\|erase\|list ...` | Data subjects: archive columns encrypted per subject, erased by dropping the key. |
| `ledger` | Seal and verify the tamper-evident ledger. |
| `metrics [--per-branch]` | The Prometheus text `gnomon serve` exposes. |
| `worktree init\|prune` | A branch per git worktree. |

[SQL reference →](sql-reference.md) · [Operations →](operations.md)
