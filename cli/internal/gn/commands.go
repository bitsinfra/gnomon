package gn

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
)

// Command is one CLI subcommand.
type Command struct {
	Name    string
	Usage   string
	Summary string
	Run     func(ctx context.Context, o *Options, args []string) error
}

// Commands lists every subcommand except the ones registered by other packages.
var Commands = map[string]*Command{}

func register(c *Command) { Commands[c.Name] = c }

// ErrUsage signals a usage error.
var ErrUsage = errors.New("usage")

func withConn(ctx context.Context, o *Options, fn func(c *pgx.Conn) error) error {
	c, err := Connect(ctx, o.DSN)
	if err != nil {
		return err
	}
	defer c.Close(context.Background())
	if o.Branch != "" {
		if err := UseBranch(ctx, c, o.Branch, ""); err != nil {
			return err
		}
	}
	return fn(c)
}

func show(ctx context.Context, o *Options, sql string, args ...any) error {
	return withConn(ctx, o, func(c *pgx.Conn) error {
		res, err := Query(ctx, c, sql, args...)
		if err != nil {
			return err
		}
		return Print(o.Out, res, o.JSON)
	})
}

func flags(name string) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	return fs
}

// parse lets flags appear before or after positional arguments.
func parse(fs *flag.FlagSet, args []string) ([]string, error) {
	var pos []string
	for {
		if err := fs.Parse(args); err != nil {
			return nil, err
		}
		args = fs.Args()
		if len(args) == 0 {
			return pos, nil
		}
		pos = append(pos, args[0])
		args = args[1:]
	}
}

func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func init() {
	register(&Command{Name: "branch", Usage: "branch create|list|drop|close|reopen|url ...", Summary: "manage branches", Run: branchCmd})
	register(&Command{Name: "diff", Usage: "diff <a> [b] [--table t]", Summary: "changes between two refs (branch, main, coordinate, tag:x, timestamp, branch@ref)", Run: diffCmd})
	register(&Command{Name: "merge", Usage: "merge <branch> [--into target] [--strict] [--preview] [--resume id] [--incremental] [--close] [--schedule time]", Summary: "three-way merge a branch into its parent or any branch", Run: mergeCmd})
	register(&Command{Name: "conflicts", Usage: "conflicts <merge-id> | --branch b", Summary: "list conflicts of a merge or a rebase", Run: conflictsCmd})
	register(&Command{Name: "resolve", Usage: "resolve <conflict-id> ours|theirs|base|value [json] | resolve --merge id ours|theirs", Summary: "record a conflict resolution", Run: resolveCmd})
	register(&Command{Name: "rebase", Usage: "rebase <branch> [--dry-run]", Summary: "carry a branch onto its parent's current state", Run: rebaseCmd})
	register(&Command{Name: "log", Usage: "log [--limit n] [--branch b]", Summary: "commit log and merges", Run: logCmd})
	register(&Command{Name: "history", Usage: "history <table> <key> (on --branch)", Summary: "every version of one row, on main or a branch", Run: historyCmd})
	register(&Command{Name: "blame", Usage: "blame <table> <key> (on --branch)", Summary: "who last changed each field of a row", Run: blameCmd})
	register(&Command{Name: "undo", Usage: "undo <xid> | --merge id | --role r --since ts [--until ts] [--branch b]", Summary: "revert transactions through the merge engine", Run: undoCmd})
	register(&Command{Name: "doctor", Usage: "doctor", Summary: "consistency and configuration checks", Run: doctorCmd})
	register(&Command{Name: "track", Usage: "track <table> [--bitemporal] [--statement] [--protected] | track --schema s", Summary: "start versioning a table", Run: trackCmd})
	register(&Command{Name: "untrack", Usage: "untrack <table> [--keep-history]", Summary: "stop versioning a table", Run: untrackCmd})
	register(&Command{Name: "sync", Usage: "sync [table]", Summary: "re-sync gnomon objects after DDL", Run: syncCmd})
	register(&Command{Name: "tag", Usage: "tag <name> [--at ref] | tag --list", Summary: "name a coordinate (pins retention)", Run: tagCmd})
	register(&Command{Name: "cr", Usage: "cr open <branch> <title> | review <id> approve|reject|comment [body] | list | checks <branch>", Summary: "change requests and checks", Run: crCmd})
	register(&Command{Name: "feed", Usage: "feed --consumer c [--since ref] [--follow] [--limit n]", Summary: "tail the exact change feed", Run: feedCmd})
	register(&Command{Name: "daemon", Usage: "daemon [--interval 1s] [--no-heartbeat]", Summary: "run gnomon.heartbeat() and the job loop periodically (ticks, schedules, warnings, ledger; thaws, scheduled merges, notifications, sinks)", Run: daemonCmd})
	register(&Command{Name: "coord", Usage: "coord", Summary: "print the current coordinate", Run: coordCmd})
	register(&Command{Name: "sql", Usage: "sql <statement> [--as-of ref]", Summary: "run a statement on --branch (or main)", Run: sqlCmd})
	register(&Command{Name: "ledger", Usage: "ledger seal|verify|digest", Summary: "tamper-evident history", Run: ledgerCmd})
}

func branchCmd(ctx context.Context, o *Options, args []string) error {
	if len(args) == 0 {
		return ErrUsage
	}
	fs := flags("branch")
	parent := fs.String("parent", "main", "parent branch")
	scratch := fs.Bool("scratch", false, "unlogged scratch branch")
	at := fs.String("at", "", "fork at a past ref instead of now")
	cascade := fs.Bool("cascade", false, "drop child branches too")
	cmod := fs.Bool("c-module", false, "print the C-module connection recipe")
	note := fs.String("note", "", "note")
	pos, err := parse(fs, args[1:])
	if err != nil {
		return err
	}
	switch args[0] {
	case "create":
		if len(pos) != 1 {
			return ErrUsage
		}
		kind := "logged"
		if *scratch {
			kind = "scratch"
		}
		return show(ctx, o, "select gnomon.create_branch($1, $2, $3, $4, null, $5) as id", pos[0], *parent, kind, nullable(*at), nullable(*note))
	case "list", "ls":
		return show(ctx, o, "select name, parent, kind, status, created_by, created_at, base, rebases from gnomon.branches order by created_at")
	case "drop", "rm":
		if len(pos) != 1 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.drop_branch($1, $2)", pos[0], *cascade)
	case "close":
		if len(pos) != 1 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.close_branch($1)", pos[0])
	case "reopen":
		if len(pos) != 1 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.reopen_branch($1)", pos[0])
	case "assign":
		if len(pos) != 2 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.assign($1, $2) as search_path", pos[0], pos[1])
	case "unassign":
		if len(pos) != 1 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.unassign($1)", pos[0])
	case "ttl":
		if len(pos) != 2 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.set_branch_ttl($1, $2::interval)", pos[0], pos[1])
	case "auto-rebase":
		if len(pos) != 2 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.set_auto_rebase($1, $2)", pos[0], pos[1])
	case "usage":
		if len(pos) != 1 {
			return ErrUsage
		}
		return show(ctx, o, "select tbl::text as table, rows from gnomon.branch_usage($1)", pos[0])
	case "url":
		if len(pos) != 1 {
			return ErrUsage
		}
		return withConn(ctx, o, func(c *pgx.Conn) error {
			var opts string
			if err := c.QueryRow(ctx, "select gnomon.connection_options($1, $2)", pos[0], *cmod).Scan(&opts); err != nil {
				return err
			}
			cfg := c.Config()
			host := cfg.Host
			fmt.Fprintf(o.Out, "options=%s\n", opts)
			if strings.HasPrefix(host, "/") {
				// a socket directory has no URL form libpq accepts unencoded: the key-value form
				fmt.Fprintf(o.Out, "host=%s port=%d dbname=%s user=%s options='%s'\n", host, cfg.Port, cfg.Database, cfg.User,
					strings.ReplaceAll(opts, "'", `\'`))
			} else {
				fmt.Fprintf(o.Out, "postgresql://%s@%s:%d/%s?options=%s\n", cfg.User, host, cfg.Port, cfg.Database,
					strings.ReplaceAll(strings.ReplaceAll(opts, " ", "%20"), "=", "%3D"))
			}
			fmt.Fprintln(o.Out, "# behind a transaction pooler use per transaction: select gnomon.begin('"+pos[0]+"');")
			return nil
		})
	}
	return ErrUsage
}

func diffCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("diff")
	table := fs.String("table", "", "only this table")
	summary := fs.Bool("summary", false, "counts per table")
	pos, err := parse(fs, args)
	if err != nil {
		return err
	}
	if len(pos) < 1 || len(pos) > 2 {
		return ErrUsage
	}
	var b any
	if len(pos) == 2 {
		b = pos[1]
	}
	if *summary {
		return show(ctx, o, "select tbl::text as table, inserts, updates, deletes from gnomon.diff_summary($1, $2)", pos[0], b)
	}
	var tables any
	if *table != "" {
		tables = []string{*table}
	}
	return show(ctx, o, "select tbl::text as table, key, kind, col, old, new from gnomon.diff($1, $2, $3::regclass[])", pos[0], b, tables)
}

func mergeCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("merge")
	into := fs.String("into", "", "target branch (default: the parent)")
	preview := fs.Bool("preview", false, "show the merge without changing anything")
	resume := fs.Int64("resume", 0, "resume a merge after resolving conflicts")
	incremental := fs.Bool("incremental", false, "commit per batch (readers can see a partly applied merge)")
	closeB := fs.Bool("close", false, "mark the branch merged afterwards")
	strict := fs.Bool("strict", false, "refuse a source that would carry its parent's changes (sibling merges)")
	schedule := fs.String("schedule", "", "merge at this time instead (gnomon daemon runs it)")
	pos, err := parse(fs, args)
	if err != nil {
		return err
	}
	if len(pos) != 1 {
		return ErrUsage
	}
	if *schedule != "" {
		return show(ctx, o, "select gnomon.schedule_merge($1, $2::timestamptz, $3) as scheduled", pos[0], *schedule, *closeB)
	}
	if *preview {
		return show(ctx, o, "select tbl::text as table, key, action, conflicts, ours, theirs, result from gnomon.merge_preview($1, $2)", pos[0], nullable(*into))
	}
	return withConn(ctx, o, func(c *pgx.Conn) error {
		if *incremental {
			if _, err := c.Exec(ctx, "call gnomon.merge_incremental($1, $2)", pos[0], *into); err != nil {
				return err
			}
			res, err := Query(ctx, c, "select id, status, stats from gnomon.merge where source = (select id from gnomon.branch where name = $1) order by id desc limit 1", pos[0])
			if err != nil {
				return err
			}
			return Print(o.Out, res, o.JSON)
		}
		var resumeArg any
		if *resume > 0 {
			resumeArg = *resume
		}
		var id int64
		if err := c.QueryRow(ctx, "select gnomon.merge($1, $2, 'atomic', null, null, $3, $4, $5)", pos[0], nullable(*into), resumeArg, *closeB, *strict).Scan(&id); err != nil {
			return err
		}
		res, err := Query(ctx, c, "select id, status, stats, gnomon.coord_text(result) as result from gnomon.merge where id = $1", id)
		if err != nil {
			return err
		}
		if err := Print(o.Out, res, o.JSON); err != nil {
			return err
		}
		if len(res.Rows) == 1 && res.Maps[0]["status"] == "conflicts" && !o.JSON {
			fmt.Fprintf(o.Out, "merge %d has conflicts: gnomon conflicts %d, then gnomon resolve <id> ours|theirs|base|value, then gnomon merge %s --resume %d\n", id, id, pos[0], id)
		}
		// indexes the merge left for CREATE INDEX CONCURRENTLY (a schema change on a large table)
		var defs []string
		if err := c.QueryRow(ctx, "select coalesce(array(select jsonb_array_elements_text(stats -> 'indexes_to_build')), '{}') from gnomon.merge where id = $1", id).Scan(&defs); err != nil {
			return err
		}
		for _, d := range defs {
			if !o.JSON {
				fmt.Fprintf(o.Out, "building %s\n", d)
			}
			if _, err := c.Exec(ctx, d); err != nil {
				return fmt.Errorf("merge %d applied; building an index failed (run it again by hand): %s: %w", id, d, err)
			}
		}
		return nil
	})
}

func conflictsCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("conflicts")
	branch := fs.String("branch", "", "rebase conflicts of a branch")
	pos, err := parse(fs, args)
	if err != nil {
		return err
	}
	if *branch != "" {
		return show(ctx, o, "select id, tbl::text as table, key, col, kind, base, ours, theirs, resolution from gnomon.conflict where branch = (select id from gnomon.branch where name = $1) order by id", *branch)
	}
	if len(pos) != 1 {
		return ErrUsage
	}
	return show(ctx, o, "select id, tbl::text as table, key, col, kind, base, ours, theirs, resolution, value from gnomon.conflict where merge_id = $1 order by id", pos[0])
}

func resolveCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("resolve")
	mergeID := fs.Int64("merge", 0, "resolve every open conflict of a merge the same way")
	pos, err := parse(fs, args)
	if err != nil {
		return err
	}
	if *mergeID > 0 {
		if len(pos) != 1 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.resolve_all($1, $2) as resolved", *mergeID, pos[0])
	}
	if len(pos) < 2 {
		return ErrUsage
	}
	var value any
	if pos[1] == "value" {
		if len(pos) != 3 {
			return fmt.Errorf("resolve <id> value <json>")
		}
		if !json.Valid([]byte(pos[2])) {
			return fmt.Errorf("value must be JSON, e.g. '\"text\"' or 42")
		}
		value = pos[2]
	}
	return show(ctx, o, "select gnomon.resolve($1, $2, $3::jsonb)", pos[0], pos[1], value)
}

func rebaseCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("rebase")
	dry := fs.Bool("dry-run", false, "show what it would merge and the conflicts, change nothing")
	pos, err := parse(fs, args)
	if err != nil || len(pos) != 1 {
		return ErrUsage
	}
	return show(ctx, o, "select gnomon.rebase($1, null, $2) as result", pos[0], *dry)
}

func logCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("log")
	limit := fs.Int("limit", 50, "rows")
	if _, err := parse(fs, args); err != nil {
		return err
	}
	// one row per merge; --branch narrows it to one branch
	br := o.Branch
	o2 := *o
	o2.Branch = ""
	return show(ctx, &o2, "select at, kind, on_branch as branch, who, actor, reason, detail from gnomon.log($1, $2)", nullable(br), *limit)
}

func historyCmd(ctx context.Context, o *Options, args []string) error {
	if len(args) != 2 {
		return ErrUsage
	}
	br := o.Branch
	if br == "" {
		br = "main"
	}
	return withConn(ctx, o, func(c *pgx.Conn) error {
		res, err := Query(ctx, c, "select vkey, xid::text, role, op, at, at_tick, actor, reason, on_branch as branch, row_image from gnomon.history($1, $2::jsonb, $3)", args[0], args[1], br)
		if err != nil {
			return err
		}
		if !o.JSON {
			for _, m := range res.Maps {
				if m["at_tick"] == nil {
					m["at_tick"] = "after the last tick"
				}
			}
			for i, r := range res.Rows {
				if r[5] == nil {
					res.Rows[i][5] = "after the last tick"
				}
			}
		}
		return Print(o.Out, res, o.JSON)
	})
}

func blameCmd(ctx context.Context, o *Options, args []string) error {
	if len(args) != 2 {
		return ErrUsage
	}
	br := o.Branch
	if br == "" {
		br = "main"
	}
	return show(ctx, o, "select col, value, xid::text, role, actor, reason, at, on_branch as branch from gnomon.blame($1, $2::jsonb, $3)", args[0], args[1], br)
}

func undoCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("undo")
	mergeID := fs.Int64("merge", 0, "undo a merge")
	role := fs.String("role", "", "undo every transaction of a role in a window")
	since := fs.String("since", "", "window start (with --role)")
	until := fs.String("until", "", "window end (with --role)")
	branch := fs.String("on", "main", "branch the transactions ran on")
	pos, err := parse(fs, args)
	if err != nil {
		return err
	}
	switch {
	case *mergeID > 0:
		return show(ctx, o, "select gnomon.undo_merge($1) as result", *mergeID)
	case *role != "":
		if *since == "" {
			return fmt.Errorf("--role needs --since")
		}
		u := any(nil)
		if *until != "" {
			u = *until
		}
		return show(ctx, o, "select gnomon.undo_role($1, $2::timestamptz, coalesce($3::timestamptz, now()), $4) as result", *role, *since, u, *branch)
	case len(pos) >= 1:
		return show(ctx, o, "select gnomon.undo_xids($1::xid8[], $2, 'cli') as result", pos, *branch)
	}
	return ErrUsage
}

func doctorCmd(ctx context.Context, o *Options, args []string) error {
	return withConn(ctx, o, func(c *pgx.Conn) error {
		res, err := Query(ctx, c, "select check_name, status, detail from gnomon.doctor()")
		if err != nil {
			return err
		}
		if err := Print(o.Out, res, o.JSON); err != nil {
			return err
		}
		for _, m := range res.Maps {
			if m["status"] == "error" {
				return fmt.Errorf("doctor found errors")
			}
		}
		return nil
	})
}

func trackCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("track")
	bt := fs.Bool("bitemporal", false, "valid time as well as known time")
	stmt := fs.Bool("statement", false, "statement-level trigger (bulk loads)")
	prot := fs.Bool("protected", false, "changes only through merges")
	schema := fs.String("schema", "", "track every table with a primary key in a schema")
	pos, err := parse(fs, args)
	if err != nil {
		return err
	}
	mode, wm := "known", "row"
	if *bt {
		mode = "bitemporal"
	}
	if *stmt {
		wm = "statement"
	}
	if *schema != "" {
		return show(ctx, o, "select gnomon.track_schema($1, $2, $3) as tables", *schema, mode, wm)
	}
	if len(pos) != 1 {
		return ErrUsage
	}
	return show(ctx, o, "select gnomon.track($1, mode => $2, write_mode => $3, protected => $4) as id", pos[0], mode, wm, *prot)
}

func untrackCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("untrack")
	keep := fs.Bool("keep-history", false, "keep the version tables")
	pos, err := parse(fs, args)
	if err != nil || len(pos) != 1 {
		return ErrUsage
	}
	return show(ctx, o, "select gnomon.untrack($1, $2)", pos[0], *keep)
}

func syncCmd(ctx context.Context, o *Options, args []string) error {
	var t any
	if len(args) == 1 {
		t = args[0]
	}
	return show(ctx, o, "select gnomon.sync($1::regclass) as synced", t)
}

func tagCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("tag")
	at := fs.String("at", "now", "ref to tag")
	list := fs.Bool("list", false, "list tags")
	note := fs.String("note", "", "note")
	pos, err := parse(fs, args)
	if err != nil {
		return err
	}
	if *list || len(pos) == 0 {
		return show(ctx, o, "select name, gnomon.coord_text(coord) as coord, created_by, created_at, note from gnomon.tag order by created_at")
	}
	return show(ctx, o, "select $1::text as name, gnomon.coord_text(gnomon.create_tag($1, $2, $3)) as coord", pos[0], *at, nullable(*note))
}

func crCmd(ctx context.Context, o *Options, args []string) error {
	if len(args) == 0 {
		return ErrUsage
	}
	fs := flags("cr")
	body := fs.String("body", "", "description")
	approvals := fs.Int("approvals", 1, "approvals required")
	pos, err := parse(fs, args[1:])
	if err != nil {
		return err
	}
	switch args[0] {
	case "open":
		if len(pos) != 2 {
			return ErrUsage
		}
		return show(ctx, o, "select gnomon.open_change_request($1, $2, $3, 'main', $4) as id", pos[0], pos[1], nullable(*body), *approvals)
	case "review":
		if len(pos) < 2 {
			return ErrUsage
		}
		var b any
		if len(pos) > 2 {
			b = strings.Join(pos[2:], " ")
		}
		return show(ctx, o, "select gnomon.review($1, $2, $3)", pos[0], pos[1], b)
	case "list", "ls":
		return show(ctx, o, `select cr.id, b.name as branch, cr.title, cr.status, cr.opened_by, cr.required_approvals,
		  (select count(*) from gnomon.review r where r.cr = cr.id and r.verdict = 'approve') as approvals
		  from gnomon.change_request cr join gnomon.branch b on b.id = cr.branch order by cr.id`)
	case "checks":
		if len(pos) != 1 {
			return ErrUsage
		}
		return show(ctx, o, "select check_name, passed, detail from gnomon.run_checks($1)", pos[0])
	}
	return ErrUsage
}

func feedCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("feed")
	consumer := fs.String("consumer", "", "consumer name (remembers its position)")
	since := fs.String("since", "now", "where a new consumer starts")
	follow := fs.Bool("follow", false, "keep polling")
	limit := fs.Int("limit", 1000, "batch size")
	interval := fs.Duration("interval", time.Second, "poll interval with --follow")
	if _, err := parse(fs, args); err != nil {
		return err
	}
	if *consumer == "" {
		return fmt.Errorf("--consumer is required")
	}
	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()
	return withConn(ctx, o, func(c *pgx.Conn) error {
		var exists bool
		if err := c.QueryRow(ctx, "select exists (select 1 from gnomon.consumer where name = $1)", *consumer).Scan(&exists); err != nil {
			return err
		}
		if !exists {
			if _, err := c.Exec(ctx, "select gnomon.feed_create($1, $2)", *consumer, *since); err != nil {
				return err
			}
		}
		enc := json.NewEncoder(o.Out)
		for {
			res, err := Query(ctx, c, "select vkey, tbl::text as table, key, op, xid::text, role, new, old from gnomon.feed_poll($1, $2)", *consumer, *limit)
			if err != nil {
				return err
			}
			for _, m := range res.Maps {
				if err := enc.Encode(m); err != nil {
					return err
				}
			}
			if !*follow {
				return nil
			}
			if len(res.Rows) < *limit {
				select {
				case <-ctx.Done():
					return nil
				case <-time.After(*interval):
				}
			}
		}
	})
}

// Daemon runs gnomon.heartbeat() every interval until the context ends.
func Daemon(ctx context.Context, dsn string, interval time.Duration, log func(string)) error {
	return DaemonOpts(ctx, dsn, interval, true, log)
}

// DaemonOpts: heartbeat false runs the job loop alone (the C worker beats the heart).
func DaemonOpts(ctx context.Context, dsn string, interval time.Duration, heartbeat bool, log func(string)) error {
	var c *pgx.Conn
	defer func() {
		if c != nil {
			c.Close(context.Background())
		}
	}()
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		if c == nil || c.IsClosed() {
			var err error
			if c, err = Connect(ctx, dsn); err != nil {
				log("connect: " + err.Error())
			}
		}
		if c != nil && !c.IsClosed() {
			var out string
			q := "select gnomon.heartbeat()::text"
			if !heartbeat {
				q = "select ''"
			}
			if err := c.QueryRow(ctx, q).Scan(&out); err != nil {
				if ctx.Err() != nil {
					return nil
				}
				log("heartbeat: " + PgError(err))
				c.Close(context.Background())
				c = nil
			} else {
				// the job loop: thaws, scheduled merges, notifications, sinks
				Jobs(ctx, c, log)
			}
		}
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
		}
	}
}

func daemonCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("daemon")
	interval := fs.Duration("interval", time.Second, "heartbeat interval")
	noHB := fs.Bool("no-heartbeat", false, "run the job loop only (thaws, scheduled merges, notifications, sinks): the C worker or pg_cron beats the heart")
	if _, err := parse(fs, args); err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()
	if *noHB {
		fmt.Fprintf(os.Stderr, "gnomon daemon: jobs every %s (no heartbeat)\n", *interval)
	} else {
		fmt.Fprintf(os.Stderr, "gnomon daemon: heartbeat and jobs every %s\n", *interval)
	}
	return DaemonOpts(ctx, o.DSN, *interval, !*noHB, func(s string) { fmt.Fprintln(os.Stderr, time.Now().Format(time.RFC3339), s) })
}

func coordCmd(ctx context.Context, o *Options, args []string) error {
	return show(ctx, o, "select gnomon.coordinate_text() as coordinate, now() as at")
}

func sqlCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("sql")
	asOf := fs.String("as-of", "", "read at a past ref")
	pos, err := parse(fs, args)
	if err != nil || len(pos) == 0 {
		return ErrUsage
	}
	return withConn(ctx, o, func(c *pgx.Conn) error {
		if *asOf != "" {
			if err := UseBranch(ctx, c, o.Branch, *asOf); err != nil {
				return err
			}
		}
		res, err := Query(ctx, c, strings.Join(pos, " "))
		if err != nil {
			return err
		}
		return Print(o.Out, res, o.JSON)
	})
}

func ledgerCmd(ctx context.Context, o *Options, args []string) error {
	if len(args) != 1 {
		return ErrUsage
	}
	switch args[0] {
	case "seal":
		return show(ctx, o, "select gnomon.seal_ledger() as block")
	case "verify":
		return withConn(ctx, o, func(c *pgx.Conn) error {
			res, err := Query(ctx, c, "select block, ok, detail from gnomon.verify_ledger()")
			if err != nil {
				return err
			}
			if err := Print(o.Out, res, o.JSON); err != nil {
				return err
			}
			for _, m := range res.Maps {
				if m["ok"] == false {
					return fmt.Errorf("ledger verification failed")
				}
			}
			return nil
		})
	case "digest":
		return show(ctx, o, "select block, to_coord, n_changes, root, hash from gnomon.ledger_digest()")
	}
	return ErrUsage
}

// Names returns the command names, sorted.
func Names() []string {
	out := make([]string, 0, len(Commands))
	for n := range Commands {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// Atoi is strconv.Atoi with a friendlier error.
func Atoi(s string) (int64, error) {
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("not a number: %q", s)
	}
	return n, nil
}
