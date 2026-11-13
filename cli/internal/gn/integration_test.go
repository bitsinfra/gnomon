package gn_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/bitsinfra/gnomon/cli/internal/archive"
	"github.com/bitsinfra/gnomon/cli/internal/gn"
	"github.com/bitsinfra/gnomon/cli/internal/testdb"
)

func run(t *testing.T, dsn string, args ...string) string {
	t.Helper()
	out, err := runErr(dsn, args...)
	if err != nil {
		t.Fatalf("gnomon %s: %s", strings.Join(args, " "), gn.PgError(err))
	}
	return out
}

func runErr(dsn string, args ...string) (string, error) {
	var buf bytes.Buffer
	o := &gn.Options{DSN: dsn, Out: &buf}
	for len(args) > 0 && strings.HasPrefix(args[0], "--") {
		switch args[0] {
		case "--json":
			o.JSON = true
			args = args[1:]
		case "--branch":
			o.Branch = args[1]
			args = args[2:]
		}
	}
	err := gn.Commands[args[0]].Run(context.Background(), o, args[1:])
	return buf.String(), err
}

func TestCLIFlow(t *testing.T) {
	dsn := testdb.New(t, t.Name())
	testdb.Exec(t, dsn,
		"create table item (id int primary key, name text not null, qty int not null default 0)",
		"insert into item select g, 'item ' || g, 1 from generate_series(1, 5) g")
	run(t, dsn, "track", "item")
	run(t, dsn, "branch", "create", "feature")
	if out := run(t, dsn, "branch", "list"); !strings.Contains(out, "feature") {
		t.Fatalf("branch list: %s", out)
	}
	if out := run(t, dsn, "branch", "url", "feature"); !strings.Contains(out, "gnomon.branch=feature") {
		t.Fatalf("branch url: %s", out)
	}
	run(t, dsn, "--branch", "feature", "sql", "update item set name = 'renamed' where id = 1")
	run(t, dsn, "--branch", "feature", "sql", "insert into item values (6, 'six', 6)")
	if out := run(t, dsn, "--branch", "feature", "sql", "select name from item where id = 1"); !strings.Contains(out, "renamed") {
		t.Fatalf("branch read: %s", out)
	}
	var diff []map[string]any
	if err := json.Unmarshal([]byte(run(t, dsn, "--json", "diff", "feature")), &diff); err != nil || len(diff) != 2 {
		t.Fatalf("diff: %v %v", diff, err)
	}
	if out := run(t, dsn, "diff", "feature", "--summary"); !strings.Contains(out, "item") {
		t.Fatalf("diff summary: %s", out)
	}
	if out := run(t, dsn, "merge", "feature", "--preview"); !strings.Contains(out, "insert") || !strings.Contains(out, "update") {
		t.Fatalf("preview: %s", out)
	}
	out := run(t, dsn, "--json", "merge", "feature")
	var m []map[string]any
	if err := json.Unmarshal([]byte(out), &m); err != nil || m[0]["status"] != "applied" {
		t.Fatalf("merge: %s", out)
	}
	if got := testdb.Scalar(t, dsn, "select name from item where id = 1"); got != "renamed" {
		t.Fatalf("main after merge: %s", got)
	}
	if out := run(t, dsn, "log"); !strings.Contains(out, "merge") {
		t.Fatalf("log: %s", out)
	}
	if out := run(t, dsn, "history", "item", `{"id": 1}`); !strings.Contains(out, "renamed") {
		t.Fatalf("history: %s", out)
	}
	if out := run(t, dsn, "blame", "item", `{"id": 1}`); !strings.Contains(out, "name") {
		t.Fatalf("blame: %s", out)
	}
	run(t, dsn, "undo", "--merge", fmt.Sprint(m[0]["id"]))
	if got := testdb.Scalar(t, dsn, "select name from item where id = 1"); got != "item 1" {
		t.Fatalf("after undo merge: %s", got)
	}
	run(t, dsn, "tag", "release-1")
	if out := run(t, dsn, "tag", "--list"); !strings.Contains(out, "release-1") {
		t.Fatalf("tags: %s", out)
	}
	run(t, dsn, "sql", "update item set qty = 99 where id = 2")
	if out := run(t, dsn, "sql", "select qty from item where id = 2", "--as-of", "tag:release-1"); !strings.Contains(out, "1") || strings.Contains(out, "99") {
		t.Fatalf("as-of tag: %s", out)
	}
	run(t, dsn, "ledger", "seal")
	run(t, dsn, "ledger", "verify")
	run(t, dsn, "doctor")
	// conflicts, resolve, resume
	run(t, dsn, "branch", "create", "c1")
	run(t, dsn, "--branch", "c1", "sql", "update item set name = 'theirs' where id = 3")
	run(t, dsn, "sql", "update item set name = 'ours' where id = 3")
	out = run(t, dsn, "--json", "merge", "c1")
	if err := json.Unmarshal([]byte(out), &m); err != nil || m[0]["status"] != "conflicts" {
		t.Fatalf("expected conflicts: %s", out)
	}
	id := fmt.Sprint(m[0]["id"])
	var cs []map[string]any
	_ = json.Unmarshal([]byte(run(t, dsn, "--json", "conflicts", id)), &cs)
	if len(cs) != 1 {
		t.Fatalf("conflicts: %v", cs)
	}
	run(t, dsn, "resolve", fmt.Sprint(cs[0]["id"]), "value", `"settled"`)
	run(t, dsn, "merge", "c1", "--resume", id)
	if got := testdb.Scalar(t, dsn, "select name from item where id = 3"); got != "settled" {
		t.Fatalf("resolved value: %s", got)
	}
	// feed
	run(t, dsn, "feed", "--consumer", "c", "--since", "now")
	run(t, dsn, "sql", "insert into item values (7, 'seven', 7)")
	if out := run(t, dsn, "feed", "--consumer", "c"); !strings.Contains(out, "seven") {
		t.Fatalf("feed: %s", out)
	}
	run(t, dsn, "branch", "drop", "c1")
}

// Subcommands missing their argument report a usage error instead of failing at run time.
func TestMissingArguments(t *testing.T) {
	for _, args := range [][]string{{"branch", "close"}, {"branch", "reopen"}, {"branch", "drop"}, {"branch", "url"}} {
		if _, err := runErr("host=/nonexistent", args...); !errors.Is(err, gn.ErrUsage) {
			t.Errorf("gnomon %s: got %v, want a usage error", strings.Join(args, " "), err)
		}
	}
}

// A malformed object-store URL is an error, not a crash.
func TestBadArchiveURL(t *testing.T) {
	t.Setenv("AWS_ACCESS_KEY_ID", "x")
	t.Setenv("AWS_SECRET_ACCESS_KEY", "y")
	if _, err := archive.OpenStore("s3://bad host/%zz"); err == nil {
		t.Fatal("expected an error for a malformed URL")
	}
}

// gnomon migrate: DDL through gnomon.ddl, the rest on the branch, one transaction.
func TestMigrate(t *testing.T) {
	dsn := testdb.New(t, t.Name())
	testdb.Exec(t, dsn,
		"create table acct (id int primary key, owner text not null)",
		"insert into acct select g, 'o' || g from generate_series(1, 5) g",
		"select gnomon.track('acct')",
		"select gnomon.create_branch('m1')")
	dir := t.TempDir()
	f := filepath.Join(dir, "001_tier.sql")
	if err := os.WriteFile(f, []byte(`begin;
-- a column with a default, a table, and data
alter table acct add column tier text not null default 'basic';
create table note (id int primary key, acct_id int references acct(id), body text);
update acct set tier = 'gold' where id = 1;
insert into note values (1, 1, 'first');
commit;
`), 0o644); err != nil {
		t.Fatal(err)
	}
	dry := run(t, dsn, "migrate", "m1", "--dry-run", f)
	if !strings.Contains(dry, "ddl  alter table acct") || !strings.Contains(dry, "sql  update acct") {
		t.Fatalf("dry run: %s", dry)
	}
	out := run(t, dsn, "migrate", "m1", f)
	if !strings.Contains(out, "add_column acct.tier") || !strings.Contains(out, "create_table note") || !strings.Contains(out, "migrated branch m1: 4") {
		t.Fatalf("migrate: %s", out)
	}
	if v := run(t, dsn, "--branch", "m1", "sql", "select tier from acct where id = 1"); !strings.Contains(v, "gold") {
		t.Fatalf("branch value: %s", v)
	}
	if v := testdb.Scalar(t, dsn, "select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'acct' and column_name = 'tier'"); v != "0" {
		t.Fatalf("main changed: %s", v)
	}
	if s := run(t, dsn, "schema", "m1"); !strings.Contains(s, "add_column") || !strings.Contains(s, "create_table") {
		t.Fatalf("schema: %s", s)
	}
	// the merge brings the schema change; an index on a large table is built concurrently after it
	testdb.Exec(t, dsn, "select gnomon.set('ddl_concurrent_rows', '0')")
	if _, err := runErr(dsn, "--branch", "m1", "sql", "select gnomon.ddl('create index acct_tier on acct (tier)')"); err != nil {
		t.Fatal(err)
	}
	if out := run(t, dsn, "merge", "m1"); !strings.Contains(out, "building CREATE INDEX CONCURRENTLY IF NOT EXISTS acct_tier") {
		t.Fatalf("merge: %s", out)
	}
	if v := testdb.Scalar(t, dsn, "select count(*) from pg_indexes where indexname = 'acct_tier' and schemaname = 'public'"); v != "1" {
		t.Fatalf("index not built: %s", v)
	}
	if v := testdb.Scalar(t, dsn, "select tier from acct where id = 1"); v != "gold" {
		t.Fatalf("main after the merge: %s", v)
	}
	testdb.Exec(t, dsn, "select gnomon.create_branch('m2')")
	// a failing statement rolls the whole migration back
	bad := filepath.Join(dir, "002_bad.sql")
	_ = os.WriteFile(bad, []byte("alter table acct add column x int;\nalter table acct drop column owner;\n"), 0o644)
	if _, err := runErr(dsn, "migrate", "m2", bad); err == nil {
		t.Fatal("a refused statement passed")
	}
	if n := testdb.Scalar(t, dsn, "select count(*) from gnomon.schema_changes('m2')"); n != "0" {
		t.Fatalf("the failed migration left changes: %s", n)
	}
}
