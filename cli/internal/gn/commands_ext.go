package gn

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// ThawPartition restores one archived partition (the archiver sets it: the job loop thaws with it).
var ThawPartition func(ctx context.Context, c *pgx.Conn, table string, part int) error

// Help holds longer help for `gnomon help <command>`.
var Help = map[string]string{
	"agent": `An agent is a database role confined to its own branch, assigned to it (its sessions start there),
with a token for the MCP HTTP transport. "agent create" prints a connection string first: it is all
an agent needs. Subcommands:
  create <name> [--parent main] [--mask profile]   make the role, its branch, its token
  list | show <name>                               agents and what they use
  next <name>                                      a fresh branch for the next task
  rotate <name>                                    a new token
  budget <name> [--calls n] [--rows n] [--bytes n] calls per minute and result caps
  stop <name> [--undo-since ts]                    the kill switch: login and token off, branches
                                                   closed, merges of its branches undone
  replay <run>                                     run each recorded read again at its coordinate
                                                   and compare digests`,
	"branch": `Subcommands: create <name> [--parent p] [--scratch] [--at ref] | list | drop <name> [--cascade] |
close <name> | reopen <name> | url <name> [--c-module] | assign <role> <branch> | unassign <role> |
ttl <branch> <interval> | auto-rebase <branch> off|clean|always | usage <branch>`,
	"merge": `gnomon merge <branch> merges into its parent; --into <branch> merges into any open branch (a
sibling; the base is their common ancestor at the earlier fork). --strict refuses a source that forked
later than the target and would carry its parent's changes in between. --schedule <time> merges later.`,
	"revert": `Set rows of a table to their state at a past moment: gnomon revert <table> --at <ref>
[--key '{"id": 3}'] [--where "status = 'x'"] [--columns a,b] [--dry-run]. On --branch b it writes the
branch. The result is recorded as one change, so it is undoable.`,
	"init": `Checks the server and your rights, installs gnomon (the extension, or the plain-SQL script where
CREATE EXTENSION is not available), tracks a schema, sets up the heartbeat and runs doctor.`,
}

// OwnsFlag says a command defines a flag that has the name of a global one.
func OwnsFlag(cmd, name string) bool {
	switch cmd + "/" + name {
	case "conflicts/branch":
		return true
	}
	return false
}

func init() {
	register(&Command{Name: "status", Usage: "status", Summary: "where this session is: branch, routing, changes, warnings, change request, quota", Run: statusCmd})
	register(&Command{Name: "describe", Usage: "describe [schema]", Summary: "the database as an agent sees it (JSON)", Run: describeCmd})
	register(&Command{Name: "revert", Usage: "revert <table> --at <ref> [--key json] [--where sql] [--columns a,b] [--dry-run]", Summary: "set rows to their state at a past moment", Run: revertCmd})
	register(&Command{Name: "checkpoint", Usage: "checkpoint <name> (on --branch)", Summary: "name a branch's state now, to rewind to", Run: checkpointCmd})
	register(&Command{Name: "rewind", Usage: "rewind <branch> <checkpoint> [--dry-run]", Summary: "set a branch back to a checkpoint (undoable)", Run: rewindCmd})
	register(&Command{Name: "dry-run", Usage: "dry-run [-f file.sql] [statement ...] (on --branch)", Summary: "run statements on a throwaway branch and show the diff and checks", Run: dryRunCmd})
	register(&Command{Name: "cherry-pick", Usage: "cherry-pick <xid>... --from <branch> [--onto main]", Summary: "apply what some transactions of a branch did to another branch", Run: cherryPickCmd})
	register(&Command{Name: "bisect", Usage: "bisect <check name|sql> --good <ref> [--bad now] (on --branch)", Summary: "find the transaction where a check started failing", Run: bisectCmd})
	register(&Command{Name: "agent", Usage: "agent create|list|show|next|rotate|budget|stop|replay ...", Summary: "agents: confined roles on branches, with tokens", Run: agentCmd})
	register(&Command{Name: "checkpoints", Usage: "checkpoints create <table> [--at ref] | list | drop <table> <id> | policy <table> --every 1d [--keep 3]", Summary: "history checkpoints: full images that make past scans cheap", Run: checkpointsCmd})
	register(&Command{Name: "scenario", Usage: "scenario create <name> [--parent p] | apply <name> <sql> | compare <name>... --metric m... | promote <name> | metric <name> <sql>", Summary: "what-if branches compared by metrics", Run: scenarioCmd})
	register(&Command{Name: "attempts", Usage: "attempts create <n> <prefix> [--parent p] | compare <branch>... | pick <prefix> <winner>", Summary: "parallel attempts at one task", Run: attemptsCmd})
	register(&Command{Name: "policy", Usage: "policy create <name> --agents a,b --rules json | drop <name> | eval <branch>", Summary: "auto-merge policies", Run: policyCmd})
	register(&Command{Name: "quota", Usage: "quota set default|role|branch [name] [--branches n] [--rows n] [--age interval] [--children n] | show [--role r] [--branch b]", Summary: "limits on branches", Run: quotaCmd})
	register(&Command{Name: "thaw", Usage: "thaw status | request <ref>", Summary: "archived history being restored for reads", Run: thawCmd})
	register(&Command{Name: "scd2", Usage: "scd2 <table> [--view name]", Summary: "create <table>_history, a type-2 slowly changing dimension view", Run: scd2Cmd})
	register(&Command{Name: "metrics", Usage: "metrics [--per-branch]", Summary: "the Prometheus text gnomon serve exposes on /metrics", Run: metricsCmd})
	register(&Command{Name: "worktree", Usage: "worktree init | prune", Summary: "a branch per git worktree", Run: worktreeCmd})
	register(&Command{Name: "schedule", Usage: "schedule <branch> --at <time> [--close] | list | cancel <id>", Summary: "merge a branch later (run by gnomon daemon)", Run: scheduleCmd})
	register(&Command{Name: "sink", Usage: "sink add <name> webhook|file|nats|kafka|parquet --config json [--tables a,b] [--format gnomon|debezium|cloudevents] [--since ref] | list | pause|resume|drop <name> | replay <name> --since ref | dead", Summary: "deliver the change feed (run by gnomon daemon)", Run: sinkCmd})
	register(&Command{Name: "subject", Usage: "subject set <table> --column c --encrypt a,b | erase <table> <subject> --reason text | list", Summary: "data subjects: archive columns encrypted per subject, erased by deleting the key (crypto-shredding)", Run: subjectCmd})
	register(&Command{Name: "migrate", Usage: "migrate <branch> [--dry-run] -- <file.sql>...", Summary: "run migration files on a branch: DDL through gnomon.ddl, the rest as statements, one transaction", Run: migrateCmd})
	register(&Command{Name: "schema", Usage: "schema <branch>", Summary: "the schema changes a branch carries (gnomon.ddl)", Run: schemaCmd})
	register(&Command{Name: "graph", Usage: "graph <table> <key> [--depth 1] | impact <branch>", Summary: "rows related through foreign keys and links; a branch's impact", Run: graphCmd})
}

func pretty(ctx context.Context, o *Options, sql string, args ...any) error {
	return withConn(ctx, o, func(c *pgx.Conn) error {
		var s string
		if err := c.QueryRow(ctx, "select jsonb_pretty(("+sql+")::jsonb)", args...).Scan(&s); err != nil {
			return err
		}
		fmt.Fprintln(o.Out, s)
		return nil
	})
}

func statusCmd(ctx context.Context, o *Options, args []string) error {
	return pretty(ctx, o, "select gnomon.status()")
}

func describeCmd(ctx context.Context, o *Options, args []string) error {
	var s any
	if len(args) == 1 {
		s = args[0]
	}
	return pretty(ctx, o, "select gnomon.describe($1)", s)
}

func revertCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("revert")
	at := fs.String("at", "", "the moment to go back to")
	key := fs.String("key", "", "a key (JSON) or an array of keys")
	where := fs.String("where", "", "rows matching this condition now or then")
	cols := fs.String("columns", "", "only these columns")
	dry := fs.Bool("dry-run", false, "show what it would do")
	pos, err := parse(fs, args)
	if err != nil || len(pos) != 1 || *at == "" {
		return ErrUsage
	}
	var colsArg any
	if *cols != "" {
		colsArg = strings.Split(*cols, ",")
	}
	br := o.Branch
	if br == "" {
		br = "main"
	}
	return pretty(ctx, o, "select gnomon.revert($1, $2, $3::jsonb, $4, $5::text[], $6, $7)", pos[0], *at, nullable(*key), nullable(*where), colsArg, br, *dry)
}

func checkpointCmd(ctx context.Context, o *Options, args []string) error {
	if len(args) != 1 || o.Branch == "" {
		return fmt.Errorf("usage: gnomon --branch <branch> checkpoint <name>")
	}
	return show(ctx, o, "select gnomon.checkpoint($1, $2) as checkpoint", args[0], o.Branch)
}

func rewindCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("rewind")
	dry := fs.Bool("dry-run", false, "show what it would do")
	pos, err := parse(fs, args)
	if err != nil || len(pos) != 2 {
		return ErrUsage
	}
	return pretty(ctx, o, "select gnomon.rewind($1, $2, $3)", pos[0], pos[1], *dry)
}

func dryRunCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("dry-run")
	file := fs.String("f", "", "a file of statements")
	noChecks := fs.Bool("no-checks", false, "skip the checks")
	pos, err := parse(fs, args)
	if err != nil {
		return err
	}
	stmts := pos
	if *file != "" {
		b, err := os.ReadFile(*file)
		if err != nil {
			return err
		}
		stmts = append(stmts, SplitSQL(string(b))...)
	}
	if len(stmts) == 0 {
		return ErrUsage
	}
	br := o.Branch
	o2 := *o
	o2.Branch = "" // the dry run picks its parent itself
	return pretty(ctx, &o2, "select gnomon.dry_run($1::text[], $2, $3)", stmts, nullable(br), !*noChecks)
}

func cherryPickCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("cherry-pick")
	from := fs.String("from", "", "the branch the transactions ran on")
	onto := fs.String("onto", "main", "the target")
	pos, err := parse(fs, args)
	if err != nil || len(pos) == 0 || *from == "" {
		return ErrUsage
	}
	return pretty(ctx, o, "select gnomon.cherry_pick($1::xid8[], $2, $3)", pos, *from, *onto)
}

func bisectCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("bisect")
	good := fs.String("good", "", "a reference where the check passes")
	bad := fs.String("bad", "now", "a reference where it fails")
	pos, err := parse(fs, args)
	if err != nil || len(pos) != 1 || *good == "" {
		return ErrUsage
	}
	br := o.Branch
	if br == "" {
		br = "main"
	}
	o2 := *o
	o2.Branch = ""
	return withConn(ctx, &o2, func(c *pgx.Conn) error {
		res, err := Query(ctx, c, "select step, ref, passed, detail from gnomon.bisect($1, $2, $3, $4)", pos[0], *good, *bad, br)
		if err != nil {
			return err
		}
		if o.JSON {
			return Print(o.Out, res, true)
		}
		for _, m := range res.Maps {
			d, _ := m["detail"].(map[string]any)
			if d != nil && d["phase"] == "result" {
				fmt.Fprintf(o.Out, "\nfirst bad transaction: %v (role %v, actor %v, reason %v)\n", d["xid"], d["role"], d["actor"], d["reason"])
				b, _ := json.MarshalIndent(d["changes"], "", "  ")
				fmt.Fprintf(o.Out, "changes: %s\nnext: %v\n", b, d["next"])
				continue
			}
			fmt.Fprintf(o.Out, "step %v  %-40v %v\n", m["step"], m["ref"], map[bool]string{true: "passes", false: "fails"}[m["passed"] == true])
		}
		return nil
	})
}

// ---- agents

func agentCmd(ctx context.Context, o *Options, args []string) error {
	if len(args) == 0 {
		return ErrUsage
	}
	fs := flags("agent")
	parent := fs.String("parent", "main", "the branch the agent's branch forks from")
	mask := fs.String("mask", "", "a mask profile the agent reads through")
	undoSince := fs.String("undo-since", "", "with stop: undo merges of its branches since then")
	calls := fs.Int("calls", 0, "calls per minute")
	rows := fs.Int("rows", 0, "rows per result")
	bytes := fs.Int("bytes", 0, "bytes per result")
	httpURL := fs.String("mcp-url", "http://127.0.0.1:8090/mcp", "where gnomon serve --mcp (or gnomon mcp --http) listens")
	pos, err := parse(fs, args[1:])
	if err != nil {
		return err
	}
	switch args[0] {
	case "create":
		if len(pos) != 1 {
			return ErrUsage
		}
		return withConn(ctx, o, func(c *pgx.Conn) error {
			var out string
			if err := c.QueryRow(ctx, "select gnomon.agent_create($1, $2, null, $3)::text", pos[0], *parent, nullable(*mask)).Scan(&out); err != nil {
				return err
			}
			var r map[string]any
			_ = json.Unmarshal([]byte(out), &r)
			cfg := c.Config()
			fmt.Fprintf(o.Out, "connection string (the agent needs nothing else; its sessions start on branch %v):\n  %s\n\n",
				r["branch"], agentURL(cfg.Host, cfg.Port, cfg.Database, fmt.Sprint(r["role"]), fmt.Sprint(r["password"])))
			mcpCfg := map[string]any{"mcpServers": map[string]any{"gnomon": map[string]any{
				"command": "gnomon", "args": []string{"mcp"},
				"env": map[string]string{"GNOMON_DSN": agentURL(cfg.Host, cfg.Port, cfg.Database, fmt.Sprint(r["role"]), fmt.Sprint(r["password"]))}}}}
			b, _ := json.MarshalIndent(mcpCfg, "", "  ")
			fmt.Fprintf(o.Out, "MCP over stdio (optional):\n%s\n\n", b)
			httpCfg := map[string]any{"mcpServers": map[string]any{"gnomon": map[string]any{
				"type": "http", "url": *httpURL, "headers": map[string]string{"Authorization": "Bearer " + fmt.Sprint(r["token"])}}}}
			b, _ = json.MarshalIndent(httpCfg, "", "  ")
			fmt.Fprintf(o.Out, "MCP over HTTP (optional; the token is shown once):\n%s\n", b)
			fmt.Fprintf(o.Out, "\nthe server's login must be a member of gnomon_runner and of %v (grant %v to <login>)\n", r["role"], r["role"])
			return nil
		})
	case "list", "ls":
		return show(ctx, o, "select a.name, a.role, a.status, b.name as branch, a.created_by, a.created_at from gnomon.agent a left join gnomon.branch b on b.id = a.branch order by a.name")
	case "show":
		if len(pos) != 1 {
			return ErrUsage
		}
		return show(ctx, o, "select * from gnomon.agent_usage where agent = $1", pos[0])
	case "next":
		if len(pos) != 1 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.agent_next($1, $2) as branch", pos[0], *parent)
	case "rotate":
		if len(pos) != 1 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.agent_rotate($1) as token", pos[0])
	case "budget":
		if len(pos) != 1 {
			return ErrUsage
		}
		z := func(n int) any {
			if n <= 0 {
				return nil
			}
			return n
		}
		return show(ctx, o, "select gnomon.set_agent_budget($1, $2, $3, $4)", pos[0], z(*calls), z(*rows), z(*bytes))
	case "stop":
		if len(pos) != 1 {
			return ErrUsage
		}
		return pretty(ctx, o, "select gnomon.agent_stop($1, $2::timestamptz)", pos[0], nullable(*undoSince))
	case "replay":
		if len(pos) != 1 {
			return ErrUsage
		}
		return replayRun(ctx, o, pos[0])
	}
	return ErrUsage
}

func agentURL(host string, port uint16, db, user, password string) string {
	if strings.HasPrefix(host, "/") {
		return fmt.Sprintf("host=%s port=%d dbname=%s user=%s password=%s", host, port, db, user, password)
	}
	u := url.URL{Scheme: "postgresql", User: url.UserPassword(user, password), Host: fmt.Sprintf("%s:%d", host, port), Path: "/" + db}
	return u.String()
}

// replayRun runs each recorded read of a run again at its coordinate on its branch and compares
// the digest of its rows with the recorded one: what the agent saw, exactly.
func replayRun(ctx context.Context, o *Options, run string) error {
	return withConn(ctx, o, func(c *pgx.Conn) error {
		res, err := Query(ctx, c, "select seq, tool, args, branch, coord, digest, xid::text as xid, error from gnomon.agent_call where run = $1 order by seq", run)
		if err != nil {
			return err
		}
		if len(res.Maps) == 0 {
			return fmt.Errorf("no recorded calls for run %q", run)
		}
		var ok bool
		_ = c.QueryRow(ctx, "select coalesce(bool_and(ok), true) from gnomon.verify_run($1)", run).Scan(&ok)
		fmt.Fprintf(o.Out, "run %s: %d call(s); record chain %s\n", run, len(res.Maps), map[bool]string{true: "intact", false: "BROKEN"}[ok])
		mismatches := 0
		for _, m := range res.Maps {
			args, _ := m["args"].(map[string]any)
			if m["tool"] != "query" || m["coord"] == nil || m["error"] != nil {
				what := "write"
				if m["xid"] != nil {
					what = "write in transaction " + fmt.Sprint(m["xid"])
				} else if m["error"] != nil {
					what = "refused: " + strings.SplitN(fmt.Sprint(m["error"]), "\n", 2)[0]
				}
				fmt.Fprintf(o.Out, "  %3v %-14v %s\n", m["seq"], m["tool"], what)
				continue
			}
			got, err := replayRead(ctx, c, fmt.Sprint(m["branch"]), fmt.Sprint(m["coord"]), fmt.Sprint(args["sql"]), args)
			if err != nil {
				fmt.Fprintf(o.Out, "  %3v query          cannot replay: %v\n", m["seq"], PgError(err))
				mismatches++
				continue
			}
			same := got == m["digest"]
			if !same {
				mismatches++
			}
			fmt.Fprintf(o.Out, "  %3v query          at %v: %s\n", m["seq"], m["coord"], map[bool]string{true: "same rows", false: "DIFFERENT rows"}[same])
		}
		if mismatches > 0 || !ok {
			return fmt.Errorf("%d read(s) did not replay the same", mismatches)
		}
		return nil
	})
}

func replayRead(ctx context.Context, c *pgx.Conn, branch, coord, sql string, args map[string]any) (string, error) {
	tx, err := c.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return "", err
	}
	defer tx.Rollback(ctx)
	if branch == "" || branch == "<nil>" {
		branch = "main"
	}
	if _, err := tx.Exec(ctx, "select gnomon.begin($1, $2)", branch, coord); err != nil {
		return "", err
	}
	limit := 200
	if v, ok := args["limit"].(float64); ok && v > 0 {
		limit = int(v)
	}
	if _, err := tx.Exec(ctx, "declare gn_r no scroll cursor for "+strings.TrimRight(strings.TrimSpace(sql), ";")); err != nil {
		return "", err
	}
	res, err := Query(ctx, tx.Conn(), fmt.Sprintf("fetch forward %d from gn_r", limit))
	if err != nil {
		return "", err
	}
	return DigestRows(res.Maps), nil
}

// ---- other commands

func checkpointsCmd(ctx context.Context, o *Options, args []string) error {
	if len(args) == 0 {
		return ErrUsage
	}
	fs := flags("checkpoints")
	at := fs.String("at", "now", "the moment")
	every := fs.String("every", "", "a checkpoint every this long (interval)")
	keep := fs.Int("keep", 3, "keep the last n")
	pos, err := parse(fs, args[1:])
	if err != nil {
		return err
	}
	switch args[0] {
	case "create":
		if len(pos) != 1 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.history_checkpoint($1, $2) as id", pos[0], *at)
	case "list", "ls":
		return show(ctx, o, "select t.rel::text as table, h.id, gnomon.coord_text(h.coord) as coord, h.rows, pg_size_pretty(h.bytes) as size, h.created_at, h.cleared_key is not null as truncate from gnomon.history_checkpoint h join gnomon.tracked t on t.id = h.tbl order by 1, 2")
	case "drop":
		if len(pos) != 2 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.drop_history_checkpoint($1, $2::int)", pos[0], pos[1])
	case "policy":
		if len(pos) != 1 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.set_checkpoint_policy($1, $2::interval, $3)", pos[0], nullable(*every), *keep)
	}
	return ErrUsage
}

func scenarioCmd(ctx context.Context, o *Options, args []string) error {
	if len(args) == 0 {
		return ErrUsage
	}
	fs := flags("scenario")
	parent := fs.String("parent", "main", "parent branch or scenario")
	var metrics multi
	fs.Var(&metrics, "metric", "a metric (repeat)")
	baseline := fs.String("baseline", "base", "base (the parent at the scenario's start) or now")
	pos, err := parse(fs, args[1:])
	if err != nil {
		return err
	}
	switch args[0] {
	case "create":
		if len(pos) != 1 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.scenario_create($1, $2) as branch", pos[0], *parent)
	case "apply":
		if len(pos) < 2 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.scenario_apply($1, $2) as rows", pos[0], strings.Join(pos[1:], " "))
	case "metric":
		if len(pos) < 2 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.add_metric($1, $2)", pos[0], strings.Join(pos[1:], " "))
	case "compare":
		if len(pos) == 0 || len(metrics) == 0 {
			return ErrUsage
		}
		return show(ctx, o, "select * from gnomon.compare($1::text[], $2::text[], $3)", pos, []string(metrics), *baseline)
	case "promote":
		if len(pos) != 1 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.scenario_promote($1) as change_request", pos[0])
	}
	return ErrUsage
}

type multi []string

func (m *multi) String() string     { return strings.Join(*m, ",") }
func (m *multi) Set(s string) error { *m = append(*m, s); return nil }

func attemptsCmd(ctx context.Context, o *Options, args []string) error {
	if len(args) == 0 {
		return ErrUsage
	}
	fs := flags("attempts")
	parent := fs.String("parent", "main", "parent branch")
	pos, err := parse(fs, args[1:])
	if err != nil {
		return err
	}
	switch args[0] {
	case "create":
		if len(pos) != 2 {
			return ErrUsage
		}
		return show(ctx, o, "select unnest(gnomon.attempts_create($1::int, $2, $3)) as branch", pos[0], pos[1], *parent)
	case "compare":
		if len(pos) == 0 {
			return ErrUsage
		}
		return show(ctx, o, "select branch, rows, checks_passed, checks_failed, conflicts from gnomon.compare($1::text[])", pos)
	case "pick":
		if len(pos) != 2 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.attempts_pick($1, $2) as change_request", pos[0], pos[1])
	}
	return ErrUsage
}

func policyCmd(ctx context.Context, o *Options, args []string) error {
	if len(args) == 0 {
		return ErrUsage
	}
	fs := flags("policy")
	agents := fs.String("agents", "", "roles the policy covers, comma separated")
	rules := fs.String("rules", "{}", "rules (JSON): max_rows, max_rows_per_table, tables, columns, ops, window, max_base_lag, allow_protected, allow_outbox, no_stale_reads")
	pos, err := parse(fs, args[1:])
	if err != nil {
		return err
	}
	switch args[0] {
	case "create":
		if len(pos) != 1 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.create_merge_policy($1, $2::name[], $3::jsonb)", pos[0], strings.Split(*agents, ","), *rules)
	case "drop":
		if len(pos) != 1 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.drop_merge_policy($1)", pos[0])
	case "eval":
		if len(pos) != 1 {
			return ErrUsage
		}
		return pretty(ctx, o, "select gnomon.policy_eval($1)", pos[0])
	case "list", "ls":
		return show(ctx, o, "select name, agents, rules, enabled, created_by from gnomon.merge_policy order by name")
	}
	return ErrUsage
}

func quotaCmd(ctx context.Context, o *Options, args []string) error {
	if len(args) == 0 {
		return ErrUsage
	}
	fs := flags("quota")
	branches := fs.Int("branches", -1, "open branches per role")
	rows := fs.Int64("rows", -1, "rows touched per branch")
	age := fs.String("age", "", "branch lifetime")
	children := fs.Int("children", -1, "open children per branch")
	role := fs.String("role", "", "show for a role")
	pos, err := parse(fs, args[1:])
	if err != nil {
		return err
	}
	opt := func(n int64) any {
		if n < 0 {
			return nil
		}
		return n
	}
	switch args[0] {
	case "set":
		if len(pos) < 1 {
			return ErrUsage
		}
		name := ""
		if len(pos) > 1 {
			name = pos[1]
		}
		return show(ctx, o, "select gnomon.set_quota($1, $2, $3::int, $4::bigint, $5::interval, $6::int)", pos[0], name,
			opt(int64(*branches)), opt(*rows), nullable(*age), opt(int64(*children)))
	case "show":
		if *role == "" && o.Branch == "" {
			return show(ctx, o, "select scope, name, max_branches, max_rows, max_age, max_children from gnomon.quota order by 1, 2")
		}
		return show(ctx, o, "select * from gnomon.effective_quota($1::name, $2)", nullable(*role), nullable(o.Branch))
	}
	return ErrUsage
}

func thawCmd(ctx context.Context, o *Options, args []string) error {
	if len(args) == 0 || args[0] == "status" {
		return show(ctx, o, "select tbl::text as table, part, status, rows, requested_at, thawed_at, expires_at, error from gnomon.thaw_status()")
	}
	if args[0] == "request" && len(args) == 2 {
		return show(ctx, o, "select tbl::text as table, part, rows, status from gnomon.request_thaw($1)", args[1])
	}
	return ErrUsage
}

func scd2Cmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("scd2")
	view := fs.String("view", "", "view name (default <table>_history)")
	pos, err := parse(fs, args)
	if err != nil || len(pos) != 1 {
		return ErrUsage
	}
	return show(ctx, o, "select gnomon.scd2($1, $2)::text as view", pos[0], nullable(*view))
}

func metricsCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("metrics")
	per := fs.Bool("per-branch", false, "per-branch series too (capped)")
	if _, err := parse(fs, args); err != nil {
		return err
	}
	return withConn(ctx, o, func(c *pgx.Conn) error {
		var s string
		if err := c.QueryRow(ctx, "select gnomon.metrics_text($1)", *per).Scan(&s); err != nil {
			return err
		}
		fmt.Fprint(o.Out, s)
		return nil
	})
}

func scheduleCmd(ctx context.Context, o *Options, args []string) error {
	if len(args) == 0 {
		return ErrUsage
	}
	fs := flags("schedule")
	at := fs.String("at", "", "when")
	closeB := fs.Bool("close", false, "mark the branch merged")
	pos, err := parse(fs, args[1:])
	if err != nil {
		return err
	}
	switch args[0] {
	case "list", "ls":
		return show(ctx, o, "select s.id, b.name as branch, s.at, s.status, s.merge_id, s.error, s.created_by from gnomon.scheduled_merge s join gnomon.branch b on b.id = s.branch order by s.at")
	case "cancel":
		if len(pos) != 1 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.cancel_scheduled_merge($1::bigint)", pos[0])
	default:
		if *at == "" {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.schedule_merge($1, $2::timestamptz, $3) as id", args[0], *at, *closeB)
	}
}

func graphCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("graph")
	depth := fs.Int("depth", 1, "levels")
	max := fs.Int("max", 100, "rows")
	pos, err := parse(fs, args)
	if err != nil || len(pos) == 0 {
		return ErrUsage
	}
	if pos[0] == "impact" && len(pos) == 2 {
		return pretty(ctx, o, "select gnomon.impact($1)", pos[1])
	}
	if len(pos) != 2 {
		return ErrUsage
	}
	return show(ctx, o, "select level, rel::text as table, row_key as key, via, from_tbl::text as from_table, from_key from gnomon.neighbors($1, $2::jsonb, $3, 'both', $4)", pos[0], pos[1], *depth, *max)
}

// ---- a branch per git worktree

const postCheckout = `#!/bin/sh
# gnomon: a branch per git worktree (gnomon worktree init). git runs this after checkout and after
# "git worktree add"; a new worktree gets a logged branch named for it and a .env.gnomon file.
[ "$3" = "1" ] || exit 0
top=$(git rev-parse --show-toplevel)
[ -f "$top/.env.gnomon" ] && exit 0
name=$(basename "$top")
gnomon branch create "wt/$name" --note "worktree $top" >/dev/null 2>&1 || true
{ echo "# gnomon branch for this worktree"; gnomon branch url "wt/$name" | sed -n 's/^postgresql:/DATABASE_URL=postgresql:/p'; echo "GNOMON_BRANCH=wt/$name"; } > "$top/.env.gnomon"
echo "gnomon: worktree $name uses branch wt/$name (.env.gnomon)"
`

func worktreeCmd(ctx context.Context, o *Options, args []string) error {
	if len(args) != 1 {
		return ErrUsage
	}
	switch args[0] {
	case "init":
		gitDir, err := gitCommonDir()
		if err != nil {
			return err
		}
		hook := filepath.Join(gitDir, "hooks", "post-checkout")
		if b, err := os.ReadFile(hook); err == nil && !strings.Contains(string(b), "gnomon worktree init") {
			return fmt.Errorf("%s exists and is not gnomon's; add gnomon's lines to it by hand", hook)
		}
		if err := os.MkdirAll(filepath.Dir(hook), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(hook, []byte(postCheckout), 0o755); err != nil {
			return err
		}
		fmt.Fprintf(o.Out, "installed %s: git worktree add now makes a branch wt/<name>\n", hook)
		for _, d := range []string{"migrations", "db/migrate", "prisma/migrations", "alembic"} {
			if st, err := os.Stat(d); err == nil && st.IsDir() {
				fmt.Fprintf(o.Out, "note: %s/ holds schema migrations; worktrees that run them are not isolated from each other until schema changes on branches land\n", d)
			}
		}
		return nil
	case "prune":
		out, err := runGit("worktree", "list", "--porcelain")
		if err != nil {
			return err
		}
		live := map[string]bool{}
		for _, l := range strings.Split(out, "\n") {
			if p, ok := strings.CutPrefix(l, "worktree "); ok {
				live["wt/"+filepath.Base(p)] = true
			}
		}
		return withConn(ctx, o, func(c *pgx.Conn) error {
			res, err := Query(ctx, c, "select name from gnomon.branch where name like 'wt/%' and status = 'open'")
			if err != nil {
				return err
			}
			for _, m := range res.Maps {
				n := fmt.Sprint(m["name"])
				if live[n] {
					continue
				}
				if _, err := c.Exec(ctx, "select gnomon.close_branch($1)", n); err != nil {
					return err
				}
				fmt.Fprintf(o.Out, "closed %s (its worktree is gone; expiry drops it)\n", n)
			}
			return nil
		})
	}
	return ErrUsage
}

// ---- the job loop: what cannot run inside the database

// Jobs runs one pass of the job loop after a heartbeat: thaw requests, scheduled merges,
// notifications and sinks. Each kind is a table polled with FOR UPDATE SKIP LOCKED, so several
// daemons can share the work.
func Jobs(ctx context.Context, c *pgx.Conn, log func(string)) {
	thawJobs(ctx, c, log)
	if _, err := c.Exec(ctx, "select gnomon.run_scheduled_merges()"); err != nil && SQLState(err) != "42883" {
		log("scheduled merges: " + PgError(err))
	}
	notifyJobs(ctx, c, log)
	if SinkJobs != nil {
		SinkJobs(ctx, c, log)
	}
}

// SinkJobs delivers change feed sinks (the sink package sets it).
var SinkJobs func(ctx context.Context, c *pgx.Conn, log func(string))

func thawJobs(ctx context.Context, c *pgx.Conn, log func(string)) {
	if ThawPartition == nil {
		return
	}
	for i := 0; i < 16; i++ {
		var id int64
		var tbl string
		var part int
		err := c.QueryRow(ctx, "select id, tbl::text, part from gnomon.thaw_take()").Scan(&id, &tbl, &part)
		if err != nil {
			if err != pgx.ErrNoRows && SQLState(err) != "42883" {
				log("thaw: " + PgError(err))
			}
			return
		}
		var msg any
		if terr := ThawPartition(ctx, c, tbl, part); terr != nil {
			msg = PgError(terr)
			log(fmt.Sprintf("thaw %s partition %d: %s", tbl, part, PgError(terr)))
		} else {
			log(fmt.Sprintf("thawed %s partition %d", tbl, part))
		}
		if _, err := c.Exec(ctx, "select gnomon.thaw_finish($1, $2)", id, msg); err != nil {
			log("thaw: " + PgError(err))
			return
		}
	}
}

// notifyJobs posts queued notifications to their webhook targets.
func notifyJobs(ctx context.Context, c *pgx.Conn, log func(string)) {
	res, err := Query(ctx, c, `select n.id, n.payload, t.config from gnomon.notification n join gnomon.notify_target t on t.name = n.target
	                             where n.sent_at is null and n.attempts < 10 and t.kind = 'webhook' order by n.id limit 50`)
	if err != nil {
		if SQLState(err) != "42P01" && SQLState(err) != "42501" {
			log("notifications: " + PgError(err))
		}
		return
	}
	for _, m := range res.Maps {
		cfg, _ := m["config"].(map[string]any)
		u := fmt.Sprint(cfg["url"])
		body, _ := json.Marshal(m["payload"])
		var msg any
		if perr := PostJSON(ctx, u, body, fmt.Sprint(cfg["secret"]), fmt.Sprint(m["id"])); perr != nil {
			msg = perr.Error()
		}
		_, _ = c.Exec(ctx, "select gnomon.notification_report($1, $2)", m["id"], msg)
	}
}

// DigestRows is the run record's digest of a read's rows.
func DigestRows(rows []map[string]any) string {
	if rows == nil {
		rows = []map[string]any{}
	}
	b, _ := json.Marshal(rows)
	return sha256Hex(b)
}

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

var _ = time.Second

func sinkCmd(ctx context.Context, o *Options, args []string) error {
	if len(args) == 0 {
		return ErrUsage
	}
	fs := flags("sink")
	config := fs.String("config", "{}", "destination (JSON): webhook {url, secret}, file {path}, nats {url, subject}; batch, transactions")
	tables := fs.String("tables", "", "only these tables")
	format := fs.String("format", "gnomon", "gnomon, debezium or cloudevents")
	since := fs.String("since", "now", "where delivery starts")
	pos, err := parse(fs, args[1:])
	if err != nil {
		return err
	}
	switch args[0] {
	case "add":
		if len(pos) != 2 {
			return ErrUsage
		}
		var t any
		if *tables != "" {
			t = strings.Split(*tables, ",")
		}
		return show(ctx, o, "select gnomon.sink_add($1, $2, $3::jsonb, $4::text[], $5, $6)", pos[0], pos[1], *config, t, *format, *since)
	case "list", "ls", "status":
		return show(ctx, o, "select name, kind, format, status, delivered, failures, last_error, updated_at from gnomon.sink order by name")
	case "pause", "resume":
		if len(pos) != 1 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.sink_status($1, $2)", pos[0], map[string]string{"pause": "paused", "resume": "active"}[args[0]])
	case "replay":
		if len(pos) != 1 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.sink_replay($1, $2)", pos[0], *since)
	case "drop":
		if len(pos) != 1 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.sink_drop($1)", pos[0])
	case "dead":
		return show(ctx, o, "select id, sink, jsonb_array_length(batch) as changes, error, at from gnomon.sink_dead order by id")
	}
	return ErrUsage
}

// ddlHeads are the statements gnomon migrate sends through gnomon.ddl on a branch.
var ddlHeads = []string{"alter table ", "create table ", "create index ", "create unique index ", "comment on ",
	"drop table ", "drop index ", "alter index ", "create index concurrently "}

// IsDDL reports whether a statement is DDL gnomon.ddl takes.
func IsDDL(stmt string) bool {
	h := StatementHead(stmt)
	for _, p := range ddlHeads {
		if strings.HasPrefix(h, p) {
			return true
		}
	}
	return false
}

// migrateCmd: gnomon migrate <branch> -- <files>. Splits SQL files into statements, sends DDL
// through gnomon.ddl and runs the rest on the branch, all in one transaction.
func migrateCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("migrate")
	dry := fs.Bool("dry-run", false, "list the statements and how each would run, change nothing")
	pos, err := parse(fs, args)
	if err != nil {
		return err
	}
	br := o.Branch
	if br == "" && len(pos) > 0 {
		br, pos = pos[0], pos[1:]
	}
	if br == "" || len(pos) == 0 {
		return ErrUsage
	}
	var stmts []string
	for _, f := range pos {
		b, err := os.ReadFile(f)
		if err != nil {
			return err
		}
		for _, s := range SplitSQL(string(b)) {
			switch h := strings.TrimRight(StatementHead(s), "; "); {
			case h == "" || h == "begin" || h == "commit" || h == "start transaction" || h == "end":
				continue // one transaction for the whole migration
			}
			stmts = append(stmts, s)
		}
	}
	if *dry {
		for _, s := range stmts {
			kind := "sql"
			if IsDDL(s) {
				kind = "ddl"
			}
			fmt.Fprintf(o.Out, "%s  %s\n", kind, oneLine(s, 100))
		}
		return nil
	}
	c, err := Connect(ctx, o.DSN)
	if err != nil {
		return err
	}
	defer c.Close(context.Background())
	tx, err := c.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.Background())
	var path string
	if err := tx.QueryRow(ctx, "select gnomon.begin($1)", br).Scan(&path); err != nil {
		return err
	}
	for i, s := range stmts {
		if IsDDL(s) {
			var res string
			if err := tx.QueryRow(ctx, "select gnomon.ddl($1)::text", s).Scan(&res); err != nil {
				return fmt.Errorf("statement %d (%s): %w", i+1, oneLine(s, 60), err)
			}
			var r struct {
				Changes []map[string]any `json:"changes"`
			}
			_ = json.Unmarshal([]byte(res), &r)
			var ops []string
			for _, ch := range r.Changes {
				op := fmt.Sprint(ch["op"])
				if t, ok := ch["table"]; ok {
					op += " " + fmt.Sprint(t)
				}
				if col, ok := ch["column"]; ok && col != nil {
					op += "." + fmt.Sprint(col)
				}
				ops = append(ops, op)
			}
			fmt.Fprintf(o.Out, "ddl  %s  -> %s\n", oneLine(s, 70), strings.Join(ops, ", "))
			continue
		}
		tag, err := tx.Exec(ctx, s)
		if err != nil {
			return fmt.Errorf("statement %d (%s): %w", i+1, oneLine(s, 60), err)
		}
		fmt.Fprintf(o.Out, "sql  %s  -> %s\n", oneLine(s, 70), tag.String())
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	fmt.Fprintf(o.Out, "migrated branch %s: %d statement(s)\n", br, len(stmts))
	return nil
}

func oneLine(s string, n int) string {
	s = blockComment.ReplaceAllString(lineComment.ReplaceAllString(s, ""), "")
	s = strings.Join(strings.Fields(s), " ")
	if len(s) > n {
		return s[:n-3] + "..."
	}
	return s
}

// schemaCmd: the schema changes a branch carries (the PR comment's table).
func schemaCmd(ctx context.Context, o *Options, args []string) error {
	br := o.Branch
	if len(args) == 1 {
		br = args[0]
	}
	if br == "" || len(args) > 1 {
		return ErrUsage
	}
	o2 := *o
	o2.Branch = ""
	return show(ctx, &o2, "select op, tbl as table, coalesce(detail ->> 'column', detail ->> 'table', detail ->> 'definition', '') as object, coalesce(detail ->> 'type', '') as type, sql from gnomon.schema_changes($1) order by version, seq", br)
}

// subjectCmd: crypto-shredding of archives.
func subjectCmd(ctx context.Context, o *Options, args []string) error {
	if len(args) == 0 {
		return ErrUsage
	}
	fs := flags("subject")
	col := fs.String("column", "", "the column naming the data subject")
	enc := fs.String("encrypt", "", "the columns the archiver encrypts per subject, comma separated")
	reason := fs.String("reason", "", "why the subject is erased (recorded)")
	pos, err := parse(fs, args[1:])
	if err != nil {
		return err
	}
	switch args[0] {
	case "set":
		if len(pos) != 1 || *col == "" {
			return ErrUsage
		}
		var cols []string
		for _, c := range strings.Split(*enc, ",") {
			if c = strings.TrimSpace(c); c != "" {
				cols = append(cols, c)
			}
		}
		return show(ctx, o, "select gnomon.set_subject($1::regclass, $2, $3::name[]) is null as ok", pos[0], *col, cols)
	case "erase":
		if len(pos) != 2 || *reason == "" {
			return ErrUsage
		}
		return pretty(ctx, o, "select gnomon.erase_subject($1::regclass, $2, $3)", pos[0], pos[1], *reason)
	case "list":
		return show(ctx, o, "select x.rel::text as table, s.subject_col as subject, s.columns as encrypted, s.created_by, s.created_at from gnomon.subject s join gnomon.tracked x on x.id = s.tbl order by 1")
	}
	return ErrUsage
}
