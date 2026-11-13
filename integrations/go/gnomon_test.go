package gnomon_test

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	gnomon "github.com/bitsinfra/gnomon/integrations/go"
	"github.com/bitsinfra/gnomon/integrations/go/gnomontest"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// The dev cluster (tools/devcluster.sh start) unless GNOMON_TEST_SERVER names another server.
func server() string {
	if s := os.Getenv("GNOMON_TEST_SERVER"); s != "" {
		return s
	}
	root, _ := filepath.Abs("../../build")
	return fmt.Sprintf("host=%s port=54329 user=postgres", root)
}

var dsn string

func TestMain(m *testing.M) {
	ctx := context.Background()
	admin, err := pgx.Connect(ctx, server()+" dbname=postgres")
	if err != nil {
		fmt.Println("skip: no test server:", err)
		os.Exit(0)
	}
	_, _ = admin.Exec(ctx, "drop database if exists go_gnomon_test with (force)")
	if _, err := admin.Exec(ctx, "create database go_gnomon_test"); err != nil {
		panic(err)
	}
	admin.Close(ctx)
	dsn = server() + " dbname=go_gnomon_test"
	c, err := pgx.Connect(ctx, dsn)
	if err != nil {
		panic(err)
	}
	for _, s := range []string{"set client_min_messages = warning", "create extension gnomon",
		"create table account (id int primary key, name text not null)",
		"insert into account select g, 'acct ' || g from generate_series(1, 5) g",
		"select gnomon.track('account')", "create table notes (id int primary key, body text)"} {
		if _, err := c.Exec(ctx, s); err != nil {
			panic(err)
		}
	}
	c.Close(ctx)
	code := m.Run()
	admin, _ = pgx.Connect(ctx, server()+" dbname=postgres")
	_, _ = admin.Exec(ctx, "drop database if exists go_gnomon_test with (force)")
	admin.Close(ctx)
	os.Exit(code)
}

func name(t *testing.T, c gnomon.Querier, id int) string {
	t.Helper()
	var s string
	if err := c.QueryRow(context.Background(), "select name from account where id = $1", id).Scan(&s); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestBranchOptions(t *testing.T) {
	if got := gnomon.BranchOptions("f", gnomon.Options{}); got != "-c gnomon.branch=f -c search_path=gnomon_r_public,public" {
		t.Fatal(got)
	}
	if got := gnomon.BranchOptions("f", gnomon.Options{CModule: true}); got != "-c gnomon.branch=f" {
		t.Fatal(got)
	}
	if got := gnomon.BranchOptions("s", gnomon.Options{Scratch: true, Schemas: []string{"app"}}); !strings.Contains(got, "gnomon_r_app__s,app") {
		t.Fatal(got)
	}
}

func TestPoolOnABranch(t *testing.T) {
	ctx := context.Background()
	main, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer main.Close(ctx)
	if err := gnomon.CreateBranch(ctx, main, "go-pool", "", ""); err != nil {
		t.Fatal(err)
	}
	cfg, _ := pgxpool.ParseConfig(dsn)
	cfg.AfterConnect = gnomon.AfterConnect("go-pool")
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, "update account set name = 'pool' where id = 1"); err != nil {
		t.Fatal(err)
	}
	if name(t, pool, 1) != "pool" || name(t, main, 1) != "acct 1" {
		t.Fatal("the pool's writes should be on the branch only")
	}
	pool.Close()
	// one transaction on a branch through a plain pool (what a transaction pooler allows)
	plain, _ := pgxpool.New(ctx, dsn)
	defer plain.Close()
	if err := gnomon.WithBranch(ctx, plain, "go-pool", func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, "update account set name = 'tx' where id = 2")
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if name(t, plain, 2) != "acct 2" {
		t.Fatal("the next transaction is on main again")
	}
	id, st, err := gnomon.Merge(ctx, main, "go-pool", "")
	if err != nil || st != "applied" || id == 0 {
		t.Fatalf("merge: %v %s", err, st)
	}
	if name(t, main, 1) != "pool" || name(t, main, 2) != "tx" {
		t.Fatal("merged")
	}
	opts, err := gnomon.ConnectionOptions(ctx, main, "go-pool", false)
	if err != nil || !strings.Contains(opts, "gnomon.branch=go-pool") {
		t.Fatalf("options: %v %s", err, opts)
	}
	_ = gnomon.DropBranch(ctx, main, "go-pool")
}

func TestDatabaseSQL(t *testing.T) {
	ctx := context.Background()
	main, _ := pgx.Connect(ctx, dsn)
	defer main.Close(ctx)
	if err := gnomon.CreateBranch(ctx, main, "go-sql", "", ""); err != nil {
		t.Fatal(err)
	}
	db, err := gnomon.OpenDB(dsn, "go-sql")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.ExecContext(ctx, "update account set name = 'sql' where id = 3"); err != nil {
		t.Fatal(err)
	}
	var s string
	if err := db.QueryRowContext(ctx, "select name from account where id = 3").Scan(&s); err != nil || s != "sql" {
		t.Fatalf("database/sql on the branch: %v %s", err, s)
	}
	if name(t, main, 3) != "acct 3" {
		t.Fatal("main changed")
	}
	// an untracked table refuses branch writes by name, and the code and explanation come back
	_, err = db.ExecContext(ctx, "insert into notes values (1, 'x')")
	var pe *pgconn.PgError
	if !errors.As(err, &pe) || gnomon.Code(pe) != "not_tracked" {
		t.Fatalf("expected not_tracked, got %v", err)
	}
	_ = gnomon.DropBranch(ctx, main, "go-sql")
}

func TestScratchBranchPerTest(t *testing.T) {
	var seen string
	t.Run("writes", func(t *testing.T) {
		c := gnomontest.Branch(t, dsn)
		seen = gnomontest.Name(t, c)
		if _, err := c.Exec(context.Background(), "update account set name = 'test' where id = 4"); err != nil {
			t.Fatal(err)
		}
		if name(t, c, 4) != "test" {
			t.Fatal("the test reads its own write")
		}
	})
	t.Run("starts from the seed", func(t *testing.T) {
		c := gnomontest.Branch(t, dsn)
		if name(t, c, 4) != "acct 4" {
			t.Fatal("a test saw another's write")
		}
	})
	main, _ := pgx.Connect(context.Background(), dsn)
	defer main.Close(context.Background())
	var n int
	_ = main.QueryRow(context.Background(), "select count(*) from gnomon.branch where name = $1", seen).Scan(&n)
	if n != 0 || name(t, main, 4) != "acct 4" {
		t.Fatal("the branch is dropped and main untouched")
	}
}
