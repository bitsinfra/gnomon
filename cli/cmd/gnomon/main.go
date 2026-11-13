// gnomon: the CLI, MCP server, archiver, review app and job loop for the gnomon extension.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/bitsinfra/gnomon/cli/internal/archive"
	"github.com/bitsinfra/gnomon/cli/internal/gn"
	"github.com/bitsinfra/gnomon/cli/internal/mcp"
	_ "github.com/bitsinfra/gnomon/cli/internal/sink" // the job loop's sink delivery
	"github.com/bitsinfra/gnomon/cli/internal/web"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

var version = "1.0.1"

func init() {
	gn.Commands["mcp"] = &gn.Command{Name: "mcp", Usage: "mcp [--http addr] [--require-reason] [--statement-timeout 30s] [--max-rows 200] [--agent name]",
		Summary: "Model Context Protocol server: stdio (a confined role's DSN), or stateless HTTP with agent tokens",
		Run: func(ctx context.Context, o *gn.Options, args []string) error {
			fs := flag.NewFlagSet("mcp", flag.ContinueOnError)
			httpAddr := fs.String("http", "", "serve Streamable HTTP on this address instead of stdio (tokens from gnomon agent create)")
			reason := fs.Bool("require-reason", false, "refuse writes without a reason")
			st := fs.Duration("statement-timeout", 30*time.Second, "statement timeout per call")
			maxRows := fs.Int("max-rows", 200, "rows a query returns at most")
			agent := fs.String("agent", "", "name calls are attributed to (default: the role's agent)")
			if err := fs.Parse(args); err != nil {
				return err
			}
			if *httpAddr != "" {
				h, err := mcp.NewHTTP(ctx, o.DSN, version)
				if err != nil {
					return err
				}
				h.RequireReason = *reason
				h.Base = mcp.Server{StatementTimeout: *st, MaxRows: *maxRows}
				mux := http.NewServeMux()
				mux.Handle("/mcp", h)
				fmt.Fprintf(os.Stderr, "gnomon MCP (Streamable HTTP, stateless) on http://%s/mcp\n", *httpAddr)
				return http.ListenAndServe(*httpAddr, mux)
			}
			return (&mcp.Server{DSN: o.DSN, Version: version, RequireReason: *reason, StatementTimeout: *st, MaxRows: *maxRows, Agent: *agent}).
				Serve(ctx, os.Stdin, os.Stdout)
		}}
	gn.Commands["serve"] = &gn.Command{Name: "serve", Usage: "serve [--addr 127.0.0.1:8090] [--auth login|header:X-Forwarded-User] [--role-map file] [--mcp] [--base-url url]",
		Summary: "review app, JSON API, /metrics and (with --mcp) the MCP HTTP transport",
		Run: func(ctx context.Context, o *gn.Options, args []string) error {
			fs := flag.NewFlagSet("serve", flag.ContinueOnError)
			addr := fs.String("addr", "127.0.0.1:8090", "listen address (terminate TLS in a proxy)")
			auth := fs.String("auth", "login", "login: a database login form; header:<Name>: a trusted proxy's header names the user")
			roleMap := fs.String("role-map", "", "with header auth: a file of `user role` lines (default: the user is the role)")
			withMCP := fs.Bool("mcp", false, "also serve MCP over HTTP on /mcp")
			base := fs.String("base-url", "", "the app's public URL, for links in notifications")
			if err := fs.Parse(args); err != nil {
				return err
			}
			h, err := web.New(ctx, web.Config{DSN: o.DSN, Auth: *auth, RoleMap: *roleMap, Version: version, BaseURL: *base})
			if err != nil {
				return err
			}
			mux := http.NewServeMux()
			mux.Handle("/", h)
			if *withMCP {
				m, err := mcp.NewHTTP(ctx, o.DSN, version)
				if err != nil {
					return err
				}
				mux.Handle("/mcp", m)
			}
			fmt.Fprintf(os.Stderr, "gnomon serve on http://%s\n", *addr)
			return http.ListenAndServe(*addr, mux)
		}}
	gn.Commands["archive"] = &gn.Command{Name: "archive", Usage: "archive <table> --before <timestamp> --to <dir|file://...|s3://bucket/prefix|gs://bucket/prefix> [--keep '{\"keep_daily\": \"1 year\"}'] [--engine file_fdw]",
		Summary: "move old version partitions to Parquet (--keep: thin them locally instead of dropping)",
		Run: func(ctx context.Context, o *gn.Options, args []string) error {
			fs := flag.NewFlagSet("archive", flag.ContinueOnError)
			before := fs.String("before", "", "archive partitions entirely older than this time")
			to := fs.String("to", "", "destination: a directory, file://, s3:// (or S3-compatible, AWS_ENDPOINT_URL) or gs://")
			keep := fs.String("keep", "", "a retention policy (JSON): write the whole partition, keep it locally thinned to what the policy retains")
			engine := fs.String("engine", "", "read each archived partition in place through an engine of gnomon.archive_engine (pg_lake, duckdb_fdw, file_fdw)")
			var pos []string
			for len(args) > 0 {
				if err := fs.Parse(args); err != nil {
					return err
				}
				if fs.NArg() == 0 {
					break
				}
				pos = append(pos, fs.Arg(0))
				args = fs.Args()[1:]
			}
			if len(pos) != 1 || *before == "" || *to == "" {
				return gn.ErrUsage
			}
			return conn(ctx, o, func(c *pgx.Conn) error {
				parts, err := archive.ArchiveOpts(ctx, c, pos[0], *before, *to, archive.Options{Keep: *keep, Engine: *engine}, func(s string) { fmt.Fprintln(o.Out, s) })
				if err == nil && len(parts) == 0 {
					fmt.Fprintln(o.Out, "nothing to archive")
				}
				return err
			})
		}}
	gn.Commands["restore"] = &gn.Command{Name: "restore", Usage: "restore <table> <partition>", Summary: "load an archived partition back",
		Run: func(ctx context.Context, o *gn.Options, args []string) error {
			if len(args) != 2 {
				return gn.ErrUsage
			}
			n, err := gn.Atoi(args[1])
			if err != nil {
				return err
			}
			return conn(ctx, o, func(c *pgx.Conn) error {
				if err := archive.Restore(ctx, c, args[0], int(n)); err != nil {
					return err
				}
				fmt.Fprintf(o.Out, "restored %s partition %d\n", args[0], n)
				return nil
			})
		}}
	gn.Commands["erase-archives"] = &gn.Command{Name: "erase-archives", Usage: "erase-archives", Summary: "apply erasure markers to archived Parquet files",
		Run: func(ctx context.Context, o *gn.Options, args []string) error {
			return conn(ctx, o, func(c *pgx.Conn) error {
				n, err := archive.EraseArchives(ctx, c, func(s string) { fmt.Fprintln(o.Out, s) })
				fmt.Fprintf(o.Out, "%d file(s) rewritten\n", n)
				return err
			})
		}}
	gn.Commands["version"] = &gn.Command{Name: "version", Usage: "version", Summary: "print the version",
		Run: func(ctx context.Context, o *gn.Options, args []string) error {
			fmt.Fprintln(o.Out, "gnomon", version)
			return nil
		}}
	// the job loop restores thaw requests with the archiver
	gn.ThawPartition = func(ctx context.Context, c *pgx.Conn, table string, part int) error {
		return archive.Restore(ctx, c, table, part)
	}
}

func conn(ctx context.Context, o *gn.Options, fn func(*pgx.Conn) error) error {
	c, err := gn.Connect(ctx, o.DSN)
	if err != nil {
		return err
	}
	defer c.Close(context.Background())
	return fn(c)
}

func usage() {
	fmt.Fprintf(os.Stderr, "usage: gnomon [--dsn DSN] [--branch b] [--json] <command> [args]\n\ncommands:\n")
	for _, n := range gn.Names() {
		c := gn.Commands[n]
		fmt.Fprintf(os.Stderr, "  %-15s %s\n", n, c.Summary)
	}
	fmt.Fprintf(os.Stderr, "\nThe connection comes from --dsn, GNOMON_DSN, or the libpq environment (PGHOST, PGPORT, PGUSER, PGDATABASE).\n")
	fmt.Fprintf(os.Stderr, "Global flags go before or after the command. gnomon help <command> describes one.\n")
}

func commandHelp(cmd *gn.Command) {
	fmt.Fprintf(os.Stderr, "usage: gnomon %s\n\n%s\n", cmd.Usage, cmd.Summary)
	if h, ok := gn.Help[cmd.Name]; ok {
		fmt.Fprintf(os.Stderr, "\n%s\n", h)
	}
	fmt.Fprintf(os.Stderr, "\nglobal flags: --dsn DSN, --branch b (run on a branch), --json\n")
}

// globalFlags takes --dsn, --branch and --json wherever they appear, except the flags a command
// defines itself under the same name.
func globalFlags(o *gn.Options, args []string) []string {
	var rest []string
	cmd := ""
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			rest = append(rest, args[i:]...)
			break
		}
		name, val, hasVal := strings.Cut(strings.TrimLeft(a, "-"), "=")
		isFlag := strings.HasPrefix(a, "-") && len(a) > 1
		if isFlag && (name == "dsn" || name == "branch" || name == "json") && !gn.OwnsFlag(cmd, name) {
			switch name {
			case "json":
				o.JSON = !hasVal || val == "true"
			default:
				if !hasVal && i+1 < len(args) {
					i++
					val = args[i]
				}
				if name == "dsn" {
					o.DSN = val
				} else {
					o.Branch = val
				}
			}
			continue
		}
		if cmd == "" && !isFlag {
			cmd = a
		}
		rest = append(rest, a)
	}
	return rest
}

func main() {
	o := &gn.Options{Out: os.Stdout}
	args := globalFlags(o, os.Args[1:])
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" {
		usage()
		os.Exit(2)
	}
	if args[0] == "help" {
		if len(args) > 1 {
			if cmd, ok := gn.Commands[args[1]]; ok {
				commandHelp(cmd)
				os.Exit(0)
			}
		}
		usage()
		os.Exit(0)
	}
	cmd, ok := gn.Commands[args[0]]
	if !ok {
		fmt.Fprintf(os.Stderr, "gnomon: unknown command %q\n", args[0])
		usage()
		os.Exit(2)
	}
	for _, a := range args[1:] {
		if a == "-h" || a == "--help" {
			commandHelp(cmd)
			os.Exit(0)
		}
		if a == "--" {
			break
		}
	}
	ctx := context.Background()
	if err := cmd.Run(ctx, o, args[1:]); err != nil {
		if errors.Is(err, gn.ErrUsage) {
			fmt.Fprintf(os.Stderr, "usage: gnomon %s\n(gnomon help %s for more)\n", cmd.Usage, cmd.Name)
			os.Exit(2)
		}
		if errors.Is(err, flag.ErrHelp) {
			os.Exit(0)
		}
		msg := gn.PgError(err)
		fmt.Fprintln(os.Stderr, "gnomon:", strings.TrimSpace(msg))
		if e := explain(ctx, o, err); e != "" {
			fmt.Fprintln(os.Stderr, "  "+e)
		}
		os.Exit(1)
	}
}

// explain asks the database what an error means on a branch (gnomon.explain_error).
func explain(ctx context.Context, o *gn.Options, err error) string {
	var pe *pgconn.PgError
	if !errors.As(err, &pe) {
		return ""
	}
	c, cerr := gn.Connect(ctx, o.DSN)
	if cerr != nil {
		return ""
	}
	defer c.Close(context.Background())
	if o.Branch != "" {
		_ = gn.UseBranch(ctx, c, o.Branch, "")
	}
	var e *string
	if c.QueryRow(ctx, "select gnomon.explain_error($1, $2)", pe.Code, pe.Message+" "+pe.Hint).Scan(&e) != nil || e == nil {
		return ""
	}
	return *e
}
