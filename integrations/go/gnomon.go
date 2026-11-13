// Package gnomon puts Go applications on branches of a PostgreSQL database with the gnomon
// extension: connection options, a pgx AfterConnect hook, one transaction on a branch through a
// pool (behind transaction poolers), and a database/sql connector. gnomontest gives each test a
// scratch branch.
//
//	cfg, _ := pgxpool.ParseConfig(dsn)
//	cfg.AfterConnect = gnomon.AfterConnect("feature")       // every connection on the branch
//	pool, _ := pgxpool.NewWithConfig(ctx, cfg)
//
//	err := gnomon.WithBranch(ctx, pool, "feature", func(tx pgx.Tx) error { ... })   // one transaction
package gnomon

import (
	"context"
	"database/sql"

	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/stdlib"
)

// Querier is what the helpers need: a *pgx.Conn, a pgx.Tx or a *pgxpool.Pool.
type Querier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// RoutingSchema is the routing schema of a user schema; scratch branches have their own (__s).
func RoutingSchema(schema string, scratch bool) string {
	if scratch {
		return "gnomon_r_" + schema + "__s"
	}
	return "gnomon_r_" + schema
}

// Options are what BranchOptions builds a libpq options value from.
type Options struct {
	CModule bool     // the server loads gnomon_c: the branch setting alone routes
	Schemas []string // default public
	AsOf    string   // read the branch as of a moment (read-only)
	Scratch bool     // the branch is a scratch branch
}

// BranchOptions is the libpq "options" value that starts sessions on a branch. ConnectionOptions
// asks the database instead, which also knows mask profiles and schema versions.
func BranchOptions(branch string, o Options) string {
	parts := []string{"-c gnomon.branch=" + branch}
	if o.AsOf != "" {
		parts = append(parts, "-c gnomon.as_of="+o.AsOf)
	}
	if !o.CModule {
		schemas := o.Schemas
		if len(schemas) == 0 {
			schemas = []string{"public"}
		}
		var path []string
		for _, s := range schemas {
			path = append(path, RoutingSchema(s, o.Scratch), s)
		}
		parts = append(parts, "-c search_path="+strings.Join(path, ","))
	}
	return strings.Join(parts, " ")
}

// ConnectionOptions returns gnomon.connection_options(branch, cModule).
func ConnectionOptions(ctx context.Context, q Querier, branch string, cModule bool) (string, error) {
	var s string
	err := q.QueryRow(ctx, "select gnomon.connection_options($1, $2)", branch, cModule).Scan(&s)
	return s, err
}

// Use puts a session on a branch (gnomon.use); "main" leaves it. It returns the search_path.
func Use(ctx context.Context, q Querier, branch string) (string, error) {
	var p string
	err := q.QueryRow(ctx, "select gnomon.use($1)", branch).Scan(&p)
	return p, err
}

// AfterConnect is a pgx/pgxpool AfterConnect hook that puts every new connection on a branch.
// With a pooler in transaction mode, use WithBranch instead: session settings do not survive it.
func AfterConnect(branch string) func(context.Context, *pgx.Conn) error {
	return func(ctx context.Context, c *pgx.Conn) error {
		_, err := Use(ctx, c, branch)
		return err
	}
}

// Beginner is a *pgx.Conn or a *pgxpool.Pool.
type Beginner interface {
	Begin(ctx context.Context) (pgx.Tx, error)
}

// WithBranch runs fn in one transaction on a branch (gnomon.begin: it lasts exactly that
// transaction), committing when fn returns nil.
func WithBranch(ctx context.Context, b Beginner, branch string, fn func(pgx.Tx) error) error {
	tx, err := b.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.Background())
	var p string
	if err := tx.QueryRow(ctx, "select gnomon.begin($1)", branch).Scan(&p); err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// OpenDB opens a database/sql handle whose connections start on a branch (through pgx's stdlib
// driver and an AfterConnect hook).
func OpenDB(dsn, branch string) (*sql.DB, error) {
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	return stdlib.OpenDB(*cfg, stdlib.OptionAfterConnect(AfterConnect(branch))), nil
}

// CreateBranch creates a branch (gnomon.create_branch); kind is "logged" or "scratch".
func CreateBranch(ctx context.Context, q Querier, name, parent, kind string) error {
	if parent == "" {
		parent = "main"
	}
	if kind == "" {
		kind = "logged"
	}
	var id int
	return q.QueryRow(ctx, "select gnomon.create_branch($1, $2, $3)", name, parent, kind).Scan(&id)
}

// DropBranch drops a branch and its children.
func DropBranch(ctx context.Context, q Querier, name string) error {
	var s string
	return q.QueryRow(ctx, "select gnomon.drop_branch($1, true)::text", name).Scan(&s)
}

// Merge merges a branch into its parent (or target) and returns the merge's id and status.
func Merge(ctx context.Context, q Querier, source, target string) (int64, string, error) {
	var t any
	if target != "" {
		t = target
	}
	var id int64
	if err := q.QueryRow(ctx, "select gnomon.merge($1, $2)", source, t).Scan(&id); err != nil {
		return 0, "", err
	}
	var st string
	err := q.QueryRow(ctx, "select status from gnomon.merge where id = $1", id).Scan(&st)
	return id, st, err
}

// Explain returns gnomon.explain_error for a database error (what it means on a branch), or "".
func Explain(ctx context.Context, q Querier, err error) string {
	pe, ok := err.(*pgconn.PgError)
	if !ok {
		return ""
	}
	var s *string
	if q.QueryRow(ctx, "select gnomon.explain_error($1, $2)", pe.Code, pe.Message+" "+pe.Hint).Scan(&s) != nil || s == nil {
		return ""
	}
	return *s
}

// Code is the stable [gnomon:<slug>] of a gnomon error's hint, or "".
func Code(err error) string {
	pe, ok := err.(*pgconn.PgError)
	if !ok {
		return ""
	}
	i := strings.Index(pe.Hint, "[gnomon:")
	if i < 0 {
		return ""
	}
	j := strings.Index(pe.Hint[i:], "]")
	if j < 0 {
		return ""
	}
	return pe.Hint[i+len("[gnomon:") : i+j]
}

