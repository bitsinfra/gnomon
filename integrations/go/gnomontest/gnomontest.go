// Package gnomontest gives each Go test its own scratch branch of one seeded database: tests see
// the seed, never each other's writes, and nothing reaches main.
//
//	func TestSignup(t *testing.T) {
//	    conn := gnomontest.Branch(t, os.Getenv("GNOMON_TEST_DSN"))
//	    conn.Exec(ctx, "insert into users ...")
//	}
package gnomontest

import (
	"context"
	"os"
	"testing"

	gnomon "github.com/bitsinfra/gnomon/integrations/go"
	"github.com/jackc/pgx/v5"
)

// Branch connects to dsn, creates a scratch branch of main, puts the connection on it, and drops
// both when the test ends (GNOMON_KEEP=1 keeps the branch for inspection).
func Branch(t testing.TB, dsn string) *pgx.Conn {
	t.Helper()
	ctx := context.Background()
	c, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatalf("gnomontest: connect: %v", err)
	}
	var name string
	if err := c.QueryRow(ctx, "select 'test/' || substr(md5(random()::text), 1, 10)").Scan(&name); err != nil {
		t.Fatal(err)
	}
	if err := gnomon.CreateBranch(ctx, c, name, "main", "scratch"); err != nil {
		c.Close(ctx)
		t.Fatalf("gnomontest: create branch: %v", err)
	}
	if _, err := gnomon.Use(ctx, c, name); err != nil {
		t.Fatalf("gnomontest: use: %v", err)
	}
	t.Cleanup(func() {
		ctx := context.Background()
		if os.Getenv("GNOMON_KEEP") != "1" {
			_, _ = gnomon.Use(ctx, c, "main")
			_ = gnomon.DropBranch(ctx, c, name)
		} else {
			t.Logf("gnomontest: kept branch %s", name)
		}
		c.Close(ctx)
	})
	return c
}

// Name is the branch a connection from Branch is on.
func Name(t testing.TB, c *pgx.Conn) string {
	t.Helper()
	var b string
	if err := c.QueryRow(context.Background(), "select gnomon.current_branch()").Scan(&b); err != nil {
		t.Fatal(err)
	}
	return b
}
