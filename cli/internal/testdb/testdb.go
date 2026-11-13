// Package testdb creates throwaway databases with gnomon installed for integration tests.
// Set GNOMON_TEST_DSN to a server where `make dev` (or `make install`) made gnomon available;
// by default the repository's dev cluster (build/, port 54329) is used.
package testdb

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Base returns the server DSN without a database name.
func Base() string {
	if d := os.Getenv("GNOMON_TEST_DSN"); d != "" {
		return d
	}
	_, file, _, _ := runtime.Caller(0)
	root := filepath.Join(filepath.Dir(file), "..", "..", "..")
	abs, _ := filepath.Abs(filepath.Join(root, "build"))
	return fmt.Sprintf("host=%s port=54329 user=postgres", abs)
}

// New creates database cli_<name> with gnomon and returns its DSN. It is dropped at cleanup.
func New(t *testing.T, name string) string {
	t.Helper()
	ctx := context.Background()
	db := "cli_" + strings.ToLower(strings.NewReplacer("/", "_", "-", "_").Replace(name))
	admin, err := pgx.Connect(ctx, Base()+" dbname=postgres")
	if err != nil {
		// CI sets GNOMON_TEST_REQUIRE: a missing server fails the tests instead of skipping them
		if os.Getenv("GNOMON_TEST_REQUIRE") != "" {
			t.Fatalf("no test server (%v); set GNOMON_TEST_DSN", err)
		}
		t.Skipf("no test server (%v); set GNOMON_TEST_DSN", err)
	}
	defer admin.Close(ctx)
	_, _ = admin.Exec(ctx, "drop database if exists "+db+" with (force)")
	if _, err := admin.Exec(ctx, "create database "+db); err != nil {
		t.Fatal(err)
	}
	dsn := Base() + " dbname=" + db
	c, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close(ctx)
	if _, err := c.Exec(ctx, "set client_min_messages = warning; create extension gnomon"); err != nil {
		t.Fatalf("create extension gnomon (run `make dev` first): %v", err)
	}
	t.Cleanup(func() {
		a, err := pgx.Connect(context.Background(), Base()+" dbname=postgres")
		if err == nil {
			_, _ = a.Exec(context.Background(), "drop database if exists "+db+" with (force)")
			a.Close(context.Background())
		}
	})
	return dsn
}

// Exec runs statements and fails the test on error.
func Exec(t *testing.T, dsn string, sqls ...string) {
	t.Helper()
	ctx := context.Background()
	c, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close(ctx)
	for _, s := range sqls {
		if _, err := c.Exec(ctx, s); err != nil {
			t.Fatalf("%s: %v", s, err)
		}
	}
}

// Scalar returns the first column of the first row as text.
func Scalar(t *testing.T, dsn string, sql string, args ...any) string {
	t.Helper()
	ctx := context.Background()
	c, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close(ctx)
	var v *string
	if err := c.QueryRow(ctx, "select ("+sql+")::text", args...).Scan(&v); err != nil {
		t.Fatalf("%s: %v", sql, err)
	}
	if v == nil {
		return ""
	}
	return *v
}

// WithUser rewrites a DSN to log in as another role.
func WithUser(dsn, user string) string {
	parts := strings.Fields(dsn)
	for i, p := range parts {
		if strings.HasPrefix(p, "user=") {
			parts[i] = "user=" + user
		}
	}
	return strings.Join(parts, " ")
}
