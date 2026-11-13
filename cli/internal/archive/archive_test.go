package archive_test

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/parquet-go/parquet-go"

	"github.com/jackc/pgx/v5"

	"github.com/bitsinfra/gnomon/cli/internal/archive"
	"github.com/bitsinfra/gnomon/cli/internal/gn"
	"github.com/bitsinfra/gnomon/cli/internal/testdb"
)

// Archive old version partitions to Parquet, check that past reads into them fail naming the
// archive, restore them, and check reads and the ledger again.
func TestArchiveRoundTrip(t *testing.T) {
	dir := t.TempDir()
	roundTrip(t, dir, func() []string {
		files, _ := filepath.Glob(filepath.Join(dir, "*.parquet"))
		return files
	}, archive.ReadParquet)
	_ = os.Remove(dir)
}

// roundTrip archives to dest; list returns the archive files there and read decodes one.
func roundTrip(t *testing.T, dest string, list func() []string, read func(string) (*archive.File, error)) {
	ctx := context.Background()
	dsn := testdb.New(t, t.Name())
	testdb.Exec(t, dsn,
		"create table ev (id int primary key, n int not null, note text)",
		"insert into ev select g, 0, 'note ' || g from generate_series(1, 20) g",
		"select gnomon.track('ev', part_span => greatest(20, pg_current_xact_id()::text::int8 / 500000 + 1))")
	c, err := gn.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close(ctx)
	var oldCoord, want string
	for i := 0; i < 60; i++ { // one transaction each: burns xids across several partitions
		if _, err := c.Exec(ctx, "update ev set n = n + 1 where id = $1", 1+i%20); err != nil {
			t.Fatal(err)
		}
		if i%10 == 0 {
			if _, err := c.Exec(ctx, "select gnomon.heartbeat()"); err != nil {
				t.Fatal(err)
			}
		}
		if i == 15 { // a coordinate whose state lives only in the partitions archived below
			if err := c.QueryRow(ctx, "select gnomon.coordinate_text()").Scan(&oldCoord); err != nil {
				t.Fatal(err)
			}
			if err := c.QueryRow(ctx, "select string_agg(id || ':' || n, ',' order by id) from ev").Scan(&want); err != nil {
				t.Fatal(err)
			}
		}
	}
	for i := 0; i < 60; i++ {
		if _, err := c.Exec(ctx, "select 1 from pg_current_xact_id()"); err != nil { // burn xids past the old partitions
			t.Fatal(err)
		}
	}
	if _, err := c.Exec(ctx, "select gnomon.heartbeat()"); err != nil {
		t.Fatal(err)
	}
	cut := archivableCut(t, ctx, c, "ev")
	if _, err := c.Exec(ctx, "update ev set n = 1000 where id = 1"); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Exec(ctx, "select gnomon._do_tick(true); select gnomon.heartbeat()"); err != nil {
		t.Fatal(err)
	}

	parts, err := archive.Archive(ctx, c, "ev", cut, dest, func(s string) { t.Log(s) })
	if err != nil {
		t.Fatal(err)
	}
	if len(parts) == 0 {
		t.Fatal("expected partitions to archive")
	}
	files := list()
	if len(files) != len(parts) {
		t.Fatalf("files %v for %d partitions", files, len(parts))
	}
	af, err := read(files[0])
	if err != nil || len(af.Rows) == 0 || af.Meta["gnomon.table"] == "" {
		t.Fatalf("parquet: %v %v", af, err)
	}

	// past reads into the archived range ask for a thaw and say so until it is done
	if _, err := c.Exec(ctx, "select gnomon.use('main', $1)", oldCoord); err != nil {
		t.Fatal(err)
	}
	var got string
	err = c.QueryRow(ctx, "select string_agg(id || ':' || n, ',' order by id) from ev").Scan(&got)
	if err == nil || !strings.Contains(err.Error(), "being thawed") {
		t.Fatalf("expected a being-thawed error, got %v (%s)", err, got)
	}
	if _, err := c.Exec(ctx, "select gnomon.use('main')"); err != nil {
		t.Fatal(err)
	}
	var pending int
	if err := c.QueryRow(ctx, "select count(*) from gnomon.thaw_request where status = 'pending'").Scan(&pending); err != nil || pending == 0 || pending > len(parts) {
		t.Fatalf("thaw requests: %d of %d (%v)", pending, len(parts), err)
	}
	requested := pending
	// the job loop restores them; the past reads again
	gn.ThawPartition = archive.Restore
	gn.Jobs(ctx, c, func(s string) { t.Log(s) })
	if _, err := c.Exec(ctx, "select gnomon.use('main', $1)", oldCoord); err != nil {
		t.Fatal(err)
	}
	if err := c.QueryRow(ctx, "select string_agg(id || ':' || n, ',' order by id) from ev").Scan(&got); err != nil || got != want {
		t.Fatalf("past read after the thaw\n got %s\nwant %s (%v)", got, want, err)
	}
	if _, err := c.Exec(ctx, "select gnomon.use('main')"); err != nil {
		t.Fatal(err)
	}
	// waiting for a thaw: CALL gnomon.thaw requests, commits and waits for the daemon; with
	// gnomon.thaw_wait set, gnomon.use waits for a request made earlier
	if _, err := c.Exec(ctx, "update gnomon.thaw_request set expires_at = now() - interval '1 second' where status = 'thawed'"); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Exec(ctx, "select gnomon.refreeze_expired()"); err != nil {
		t.Fatal(err)
	}
	waiter, err := gn.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer waiter.Close(ctx)
	runJobsAfter := func(d time.Duration) {
		time.Sleep(d)
		gn.Jobs(ctx, c, func(s string) { t.Log(s) })
	}
	done := make(chan error, 1)
	start := time.Now()
	go func() {
		_, err := waiter.Exec(ctx, "call gnomon.thaw($1, interval '30 seconds')", oldCoord)
		done <- err
	}()
	runJobsAfter(500 * time.Millisecond)
	if err := <-done; err != nil || time.Since(start) < 500*time.Millisecond {
		t.Fatalf("call gnomon.thaw: %v after %v", err, time.Since(start))
	}
	if err := waiter.QueryRow(ctx, "select gnomon.use('main', $1)", oldCoord).Scan(new(string)); err != nil {
		t.Fatal(err)
	}
	if err := waiter.QueryRow(ctx, "select string_agg(id || ':' || n, ',' order by id) from ev").Scan(&got); err != nil || got != want {
		t.Fatalf("past read after call gnomon.thaw\n got %s\nwant %s (%v)", got, want, err)
	}
	if _, err := waiter.Exec(ctx, "select gnomon.use('main')"); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Exec(ctx, "update gnomon.thaw_request set expires_at = now() - interval '1 second' where status = 'thawed'"); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Exec(ctx, "select gnomon.refreeze_expired()"); err != nil {
		t.Fatal(err)
	}
	if _, err := waiter.Exec(ctx, "select gnomon.use('main', $1)", oldCoord); err != nil { // requests (no wait: its own request)
		t.Fatal(err)
	}
	if _, err := waiter.Exec(ctx, "set gnomon.thaw_wait = '30 seconds'"); err != nil {
		t.Fatal(err)
	}
	start = time.Now()
	go func() { _, err := waiter.Exec(ctx, "select gnomon.use('main', $1)", oldCoord); done <- err }()
	runJobsAfter(500 * time.Millisecond)
	if err := <-done; err != nil || time.Since(start) < 500*time.Millisecond {
		t.Fatalf("gnomon.use with thaw_wait: %v after %v", err, time.Since(start))
	}
	if err := waiter.QueryRow(ctx, "select string_agg(id || ':' || n, ',' order by id) from ev").Scan(&got); err != nil || got != want {
		t.Fatalf("past read after waiting\n got %s\nwant %s (%v)", got, want, err)
	}
	if _, err := waiter.Exec(ctx, "select gnomon.use('main')"); err != nil {
		t.Fatal(err)
	}

	// idle thawed partitions are dropped again (the files stay), and read as archived
	if _, err := c.Exec(ctx, "update gnomon.thaw_request set expires_at = now() - interval '1 second' where status = 'thawed'"); err != nil {
		t.Fatal(err)
	}
	var refrozen int
	if err := c.QueryRow(ctx, "select gnomon.refreeze_expired()").Scan(&refrozen); err != nil || refrozen != requested {
		t.Fatalf("refreeze: %d (%v)", refrozen, err)
	}
	err = c.QueryRow(ctx, "select count(*) from gnomon.thaw_needed($1)", oldCoord).Scan(&pending)
	if err != nil || pending != requested {
		t.Fatalf("archived again: %d (%v)", pending, err)
	}
	var ledgerOK bool
	if err := c.QueryRow(ctx, "select bool_and(ok) from gnomon.verify_ledger()").Scan(&ledgerOK); err != nil || !ledgerOK {
		t.Fatalf("ledger after archive: %v %v", ledgerOK, err)
	}

	// restore every partition and read the past again
	for _, p := range parts {
		if err := archive.Restore(ctx, c, "ev", p.Part); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := c.Exec(ctx, "select gnomon.use('main', $1)", oldCoord); err != nil {
		t.Fatal(err)
	}
	if err := c.QueryRow(ctx, "select string_agg(id || ':' || n, ',' order by id) from ev").Scan(&got); err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("restored past read\n got %s\nwant %s", got, want)
	}
	if _, err := c.Exec(ctx, "select gnomon.use('main')"); err != nil {
		t.Fatal(err)
	}
	if err := c.QueryRow(ctx, "select bool_and(ok) from gnomon.verify_ledger()").Scan(&ledgerOK); err != nil || !ledgerOK {
		t.Fatalf("ledger after restore: %v %v", ledgerOK, err)
	}

	// erasure reaches archived files too
	parts, err = archive.Archive(ctx, c, "ev", cut, dest, func(s string) { t.Log(s) })
	if err != nil || len(parts) == 0 {
		t.Fatalf("re-archive: %v", err)
	}
	if _, err := c.Exec(ctx, `select gnomon.erase('ev', '{"id": 3}', array['note'], 'test')`); err != nil {
		t.Fatal(err)
	}
	n, err := archive.EraseArchives(ctx, c, func(s string) { t.Log(s) })
	if err != nil {
		t.Fatal(err)
	}
	if n == 0 {
		t.Fatal("expected erase-archives to rewrite a file")
	}
	for _, f := range files {
		af, err := read(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, r := range af.Rows {
			if r["id"] != nil && *r["id"] == "3" {
				for k, v := range r {
					if strings.HasPrefix(k, "gn_c") && v != nil && strings.HasPrefix(*v, "note") {
						t.Fatalf("erased value still archived in %s: %s=%s", f, k, *v)
					}
				}
			}
		}
	}
}

// archivableCut returns a time before which the table has partitions to archive. A partition can
// be archived once the cut's coordinate has every xid it covers behind its xmin, and xmin is the
// whole cluster's: a transaction open in another database (go test runs the packages in parallel
// against one server) holds it back. It ticks until the old partitions are past it.
func archivableCut(t *testing.T, ctx context.Context, c *pgx.Conn, tables ...string) string {
	t.Helper()
	// An early partition can be eligible while a later one still holds the
	// coordinate the test will read. Wait for the last fixture write, not
	// merely the first eligible partition, before taking the cut.
	var fence string
	if err := c.QueryRow(ctx, "select pg_current_xact_id()::text").Scan(&fence); err != nil {
		t.Fatal(err)
	}
	for start := time.Now(); ; {
		var passed bool
		if err := c.QueryRow(ctx, "select pg_snapshot_xmin(pg_current_snapshot()) > $1::text::xid8", fence).Scan(&passed); err != nil {
			t.Fatal(err)
		}
		if !passed {
			if time.Since(start) > 60*time.Second {
				t.Fatal("cluster xmin did not pass the archive fixture writes in 60 s")
			}
			time.Sleep(100 * time.Millisecond)
			continue
		}
		if _, err := c.Exec(ctx, "select gnomon._do_tick(true)"); err != nil {
			t.Fatal(err)
		}
		time.Sleep(20 * time.Millisecond)
		cut := time.Now().Format(time.RFC3339Nano)
		ready := true
		for _, tbl := range tables {
			cands, err := archive.Candidates(ctx, c, tbl, cut)
			if err != nil {
				t.Fatal(err)
			}
			ready = ready && len(cands) > 0
		}
		if ready {
			return cut
		}
		if time.Since(start) > 60*time.Second {
			t.Fatal("no partition became archivable in 60 s (a long transaction elsewhere in the cluster?)")
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// Erasure reaches archived files whatever the key: an integer key whose JSON form is not its text
// form (1000000), and a wide key, archived by its row id.
func TestEraseArchivedKeys(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	dsn := testdb.New(t, t.Name())
	testdb.Exec(t, dsn,
		"create table big (id bigint primary key, note text)",
		"insert into big values (1000000, 'secret big'), (1000001, 'keep big')",
		"select gnomon.track('big', part_span => greatest(20, pg_current_xact_id()::text::int8 / 500000 + 1))",
		"create table wide (a text, b text, c int, note text, primary key (a, b, c))",
		"insert into wide values ('aaaaaaaaaaaaaaaaaaaa', 'bbbbbbbbbbbbbbbbbbbb', 1, 'secret wide'), ('aaaaaaaaaaaaaaaaaaaa', 'bbbbbbbbbbbbbbbbbbbb', 2, 'keep wide')",
		"select gnomon.track('wide', part_span => greatest(20, pg_current_xact_id()::text::int8 / 500000 + 1))")
	c, err := gn.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close(ctx)
	for _, q := range []string{"select gnomon.heartbeat()", "update big set note = note || '!'", "update wide set note = note || '!'"} {
		if _, err := c.Exec(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 60; i++ { // burn xids past the partitions just written
		if _, err := c.Exec(ctx, "select 1 from pg_current_xact_id()"); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := c.Exec(ctx, "select gnomon.heartbeat()"); err != nil {
		t.Fatal(err)
	}
	cut := archivableCut(t, ctx, c, "big", "wide")
	for _, tbl := range []string{"big", "wide"} {
		if _, err := archive.Archive(ctx, c, tbl, cut, dir, func(s string) { t.Log(s) }); err != nil {
			t.Fatal(err)
		}
	}
	for _, q := range []string{
		`select gnomon.erase('big', '{"id": 1000000}', array['note'], 'test')`,
		`select gnomon.erase('wide', '{"a": "aaaaaaaaaaaaaaaaaaaa", "b": "bbbbbbbbbbbbbbbbbbbb", "c": 1}', array['note'], 'test')`,
	} {
		if _, err := c.Exec(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	n, err := archive.EraseArchives(ctx, c, func(s string) { t.Log(s) })
	if err != nil {
		t.Fatal(err)
	}
	if n < 2 {
		t.Fatalf("erase-archives rewrote %d file(s), want one per table at least", n)
	}
	files, _ := filepath.Glob(filepath.Join(dir, "*.parquet"))
	kept := 0
	for _, f := range files {
		af, err := archive.ReadParquet(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, r := range af.Rows {
			for k, v := range r {
				if strings.HasPrefix(k, "gn_c") && v != nil {
					if strings.HasPrefix(*v, "secret") {
						t.Fatalf("erased value still archived in %s: %s=%s", f, k, *v)
					}
					if strings.HasPrefix(*v, "keep") {
						kept++
					}
				}
			}
		}
	}
	if kept == 0 {
		t.Fatal("erase-archives removed values it should have kept")
	}
}

// Crypto-shredding: a table's declared columns are archived encrypted per data
// subject; erasing a subject deletes its key, and a restore of the unchanged file brings that
// subject's values back NULL while every other subject's come back intact.
func TestCryptoShredding(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	dsn := testdb.New(t, t.Name())
	testdb.Exec(t, dsn,
		"create table ev (id int primary key, customer text not null, email text, n int not null default 0)",
		"insert into ev select g, case when g % 2 = 0 then 'alice' else 'bob' end, case when g % 2 = 0 then 'alice@x.io' else 'bob@x.io' end from generate_series(1, 10) g",
		"select gnomon.track('ev', part_span => greatest(20, pg_current_xact_id()::text::int8 / 500000 + 1))",
		"select gnomon.set_subject('ev', 'customer', array['email'])")
	c, err := gn.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close(ctx)
	for i := 0; i < 20; i++ {
		if _, err := c.Exec(ctx, "update ev set n = n + 1, email = email where id = $1", 1+i%10); err != nil {
			t.Fatal(err)
		}
	}
	var oldCoord string
	if err := c.QueryRow(ctx, "select gnomon.coordinate_text()").Scan(&oldCoord); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 60; i++ {
		if _, err := c.Exec(ctx, "select 1 from pg_current_xact_id()"); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := c.Exec(ctx, "select gnomon.heartbeat()"); err != nil {
		t.Fatal(err)
	}
	cut := archivableCut(t, ctx, c, "ev")
	if _, err := c.Exec(ctx, "update ev set n = 100"); err != nil {
		t.Fatal(err)
	}
	parts, err := archive.Archive(ctx, c, "ev", cut, dir, func(s string) { t.Log(s) })
	if err != nil {
		t.Fatal(err)
	}
	files, _ := filepath.Glob(filepath.Join(dir, "*.parquet"))
	if len(files) == 0 || len(parts) == 0 {
		t.Fatal("nothing archived")
	}
	sums := map[string]string{}
	for _, f := range files {
		b, _ := os.ReadFile(f)
		if strings.Contains(string(b), "@x.io") {
			t.Fatalf("%s holds an email in the clear", f)
		}
		af, err := archive.ReadParquet(f)
		if err != nil {
			t.Fatal(err)
		}
		subjects := 0
		for _, r := range af.Rows {
			if r["gn_subject"] != nil && (*r["gn_subject"] == "alice" || *r["gn_subject"] == "bob") {
				subjects++
			}
		}
		if subjects != len(af.Rows) {
			t.Fatalf("%d of %d archived versions carry their subject", subjects, len(af.Rows))
		}
		sums[f], _ = archive.Checksum(f)
	}
	var res string
	if err := c.QueryRow(ctx, "select gnomon.erase_subject('ev', 'bob', 'request 42')::text").Scan(&res); err != nil || !strings.Contains(res, `"key_deleted": true`) {
		t.Fatalf("erase_subject: %s %v", res, err)
	}
	for _, p := range parts {
		if err := archive.Restore(ctx, c, "ev", p.Part); err != nil {
			t.Fatal(err)
		}
	}
	for _, f := range files {
		if s, _ := archive.Checksum(f); s != sums[f] {
			t.Fatalf("%s was rewritten; shredding needs no rewrite", f)
		}
	}
	// the past, read through the restored partitions
	if _, err := c.Exec(ctx, "select gnomon.use('main', $1)", oldCoord); err != nil {
		t.Fatal(err)
	}
	var alice, bob, bobNull int
	if err := c.QueryRow(ctx, `select count(*) filter (where customer = 'alice' and email = 'alice@x.io'),
	                                  count(*) filter (where customer = 'bob' and email is not null),
	                                  count(*) filter (where customer = 'bob' and email is null) from ev`).Scan(&alice, &bob, &bobNull); err != nil {
		t.Fatal(err)
	}
	if alice != 5 || bob != 0 || bobNull != 5 {
		t.Fatalf("after shredding bob: alice %d intact, bob %d readable, %d erased", alice, bob, bobNull)
	}
	if _, err := c.Exec(ctx, "select gnomon.use('main')"); err != nil {
		t.Fatal(err)
	}
	// a subject once erased gets no new key: its later archives hold none of its values
	var keys int
	if err := c.QueryRow(ctx, "select count(*) from gnomon.subject_keys('ev', array['bob'], true)").Scan(&keys); err != nil || keys != 0 {
		t.Fatalf("an erased subject got a key again: %d %v", keys, err)
	}
}

// Archive format 2 and reads in place: typed columns, rows in row-key order,
// Bloom filters on the key; an engine (file_fdw here, the one PostgreSQL ships) attaches each
// archived partition as a foreign partition of the version table, and cold_scans decides whether
// past reads go through it (allow), ask for a thaw (thaw) or are refused (refuse).
func TestArchiveInPlace(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	dsn := testdb.New(t, t.Name())
	testdb.Exec(t, dsn,
		"create table ev (id int primary key, n int not null, ratio float8, flag bool, at timestamptz, note text, raw bytea)",
		"insert into ev select g, 0, g / 3.0, g % 2 = 0, '2026-01-01 10:00:00+00'::timestamptz + g * interval '1 minute', 'note ' || g, decode(md5(g::text), 'hex') from generate_series(1, 20) g",
		"select gnomon.track('ev', part_span => greatest(20, pg_current_xact_id()::text::int8 / 500000 + 1))")
	c, err := gn.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close(ctx)
	var oldCoord, want string
	for i := 0; i < 40; i++ {
		if _, err := c.Exec(ctx, "update ev set n = n + 1, ratio = ratio * 2, at = at + interval '1 second' where id = $1", 1+i%20); err != nil {
			t.Fatal(err)
		}
		if i == 25 {
			_ = c.QueryRow(ctx, "select gnomon.coordinate_text()").Scan(&oldCoord)
			_ = c.QueryRow(ctx, "select string_agg(id || ':' || n || ':' || ratio || ':' || flag || ':' || at || ':' || encode(raw, 'hex'), ',' order by id) from ev").Scan(&want)
		}
	}
	for i := 0; i < 60; i++ {
		if _, err := c.Exec(ctx, "select 1 from pg_current_xact_id()"); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := c.Exec(ctx, "select gnomon.heartbeat()"); err != nil {
		t.Fatal(err)
	}
	cut := archivableCut(t, ctx, c, "ev")
	if _, err := c.Exec(ctx, "update ev set n = 1000"); err != nil {
		t.Fatal(err)
	}
	parts, err := archive.ArchiveOpts(ctx, c, "ev", cut, dir, archive.Options{Engine: "file_fdw"}, func(s string) { t.Log(s) })
	if err != nil {
		t.Fatal(err)
	}
	// format 2: native types, Bloom filters on the key, rows in key order
	files, _ := filepath.Glob(filepath.Join(dir, "*.parquet"))
	for _, f := range files {
		fh, _ := os.Open(f)
		st, _ := fh.Stat()
		pf, err := parquet.OpenFile(fh, st.Size())
		if err != nil {
			t.Fatal(err)
		}
		types := map[string]string{}
		for _, col := range pf.Schema().Fields() {
			types[col.Name()] = col.Type().String()
		}
		if !strings.HasPrefix(types["id"], "INT(32") || !strings.HasPrefix(types["gn_key"], "INT(64") || types["gn_c1"] != "DOUBLE" || !strings.HasPrefix(types["gn_c3"], "TIMESTAMP") {
			t.Fatalf("format 2 types: %v", types)
		}
		bloom := false
		for _, rg := range pf.Metadata().RowGroups {
			for _, cc := range rg.Columns {
				if cc.MetaData.PathInSchema[0] == "id" && cc.MetaData.BloomFilterOffset > 0 {
					bloom = true
				}
			}
		}
		if !bloom {
			t.Fatal("no Bloom filter on the row key")
		}
		fh.Close()
		af, err := archive.ReadParquet(f)
		if err != nil {
			t.Fatal(err)
		}
		last := -1
		for _, r := range af.Rows {
			id, _ := strconv.Atoi(*r["id"])
			if id < last {
				t.Fatal("rows are not in row-key order")
			}
			last = id
		}
		if af.Meta["gnomon.format"] != "2" {
			t.Fatal("format not recorded")
		}
	}
	if n := testdb.Scalar(t, dsn, "select count(*) from gnomon.archive where foreign_rel is not null and engine = 'file_fdw' and format = 2"); n != strconv.Itoa(len(parts)) {
		t.Fatalf("%s of %d partitions attached in place", n, len(parts))
	}
	read := func() (string, error) {
		if _, err := c.Exec(ctx, "select gnomon.use('main', $1)", oldCoord); err != nil {
			return "", err
		}
		defer c.Exec(ctx, "select gnomon.use('main')")
		var got string
		err := c.QueryRow(ctx, "select string_agg(id || ':' || n || ':' || ratio || ':' || flag || ':' || at || ':' || encode(raw, 'hex'), ',' order by id) from ev").Scan(&got)
		return got, err
	}
	// cold_scans = thaw (the default): asks for a thaw, as for any archive
	if _, err := read(); err == nil || !strings.Contains(err.Error(), "thawed") {
		t.Fatalf("cold_scans thaw: %v", err)
	}
	testdb.Exec(t, dsn, "delete from gnomon.thaw_request")
	// allow: read in place, exactly
	testdb.Exec(t, dsn, "select gnomon.set('cold_scans', 'allow')")
	if got, err := read(); err != nil || got != want {
		t.Fatalf("read in place:\n got %s (%v)\nwant %s", got, err, want)
	}
	if n := testdb.Scalar(t, dsn, "select count(*) from gnomon.thaw_request"); n != "0" {
		t.Fatalf("a read in place asked for a thaw: %s", n)
	}
	// refuse
	testdb.Exec(t, dsn, "select gnomon.set('cold_scans', 'refuse')")
	if _, err := read(); err == nil || !strings.Contains(err.Error(), "cold_scans") {
		t.Fatalf("cold_scans refuse: %v", err)
	}
	// a restore replaces the foreign partition with a real one
	testdb.Exec(t, dsn, "select gnomon.set('cold_scans', 'thaw')")
	for _, p := range parts {
		if err := archive.Restore(ctx, c, "ev", p.Part); err != nil {
			t.Fatal(err)
		}
	}
	if got, err := read(); err != nil || got != want {
		t.Fatalf("after restore:\n got %s (%v)\nwant %s", got, err, want)
	}
	if n := testdb.Scalar(t, dsn, "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = '_gnomon' and c.relkind = 'f'"); n != "0" {
		t.Fatalf("%s foreign partitions left after restore", n)
	}
}
