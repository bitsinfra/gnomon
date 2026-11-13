// gnomon-histcheck: a history checker in the style of Elle/Jepsen checkers.
//
// N sessions do random reads and writes on main and on branches at a chosen isolation level,
// logging every coordinate a read returned. Meanwhile a consumer polls the change feed. Then:
//
//  1. replay at every returned coordinate gives the same rows;
//  2. the union of change-feed batches is exactly the set of committed versions (no gaps, no duplicates);
//  3. a branch never shows main's changes after its cutoff;
//  4. the arms never both produce (or both omit) a live key: no read ever sees a key twice, and
//     every key the branch did not touch reads as main did at the cutoff.
//
// With --kill the postmaster is killed with SIGKILL mid-run and restarted; reads logged before
// the crash must still replay afterwards. With --failover the primary is killed mid-run and its
// synchronous standby promoted; every session moves there, and reads logged on the old primary
// must replay on the new one. With --replica, logged reads are also replayed on a standby
// (gnomon.use waits for it to replay past each coordinate).
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type read struct {
	Branch string
	Coord  string
	Hash   string
	Rows   map[int]string
}

type checker struct {
	dsnMu    sync.RWMutex
	dsnV     string
	sessions int
	keys     int
	branches []string
	iso      string
	mu       sync.Mutex
	reads    []read
	feed     map[string]int
	writes   atomic.Int64
	aborts   atomic.Int64
	errs     atomic.Int64
	points   atomic.Int64 // point reads compared with their scan
	inDoubt  atomic.Int64
}

func (c *checker) dsn() string     { c.dsnMu.RLock(); defer c.dsnMu.RUnlock(); return c.dsnV }
func (c *checker) setDSN(d string) { c.dsnMu.Lock(); c.dsnV = d; c.dsnMu.Unlock() }

func main() {
	server := flag.String("server", "", "server DSN without dbname (default: repo dev cluster)")
	db := flag.String("db", "gnomon_histcheck", "database to create")
	sessions := flag.Int("sessions", 8, "concurrent sessions")
	keys := flag.Int("keys", 50, "key space")
	nbranch := flag.Int("branches", 3, "branches")
	dur := flag.Duration("duration", 10*time.Second, "run time")
	iso := flag.String("iso", "read committed", "isolation level: read committed | repeatable read | serializable")
	kill := flag.Bool("kill", false, "kill -9 the postmaster mid-run and restart it")
	pgdata := flag.String("pgdata", "", "data directory (for --kill and --failover: the primary's)")
	failover := flag.Bool("failover", false, "kill the primary mid-run, promote --standby-pgdata, move every session there")
	standbyData := flag.String("standby-pgdata", "", "the standby's data directory (for --failover)")
	standbyServer := flag.String("standby-server", "", "the standby's DSN without dbname (for --failover)")
	replica := flag.String("replica", "", "also replay logged reads on this standby (DSN without dbname)")
	cmod := flag.Bool("c-module", false, "install gnomon_c and version the table with the C trigger (watermarks, C read context)")
	verifyMax := flag.Int("verify-max", 1500, "verify at most this many logged reads (sampled evenly), 0 = all")
	flag.Parse()
	if *server == "" {
		exe, _ := os.Getwd()
		root := exe
		for i := 0; i < 4 && !fileExists(filepath.Join(root, "gnomon.control")); i++ {
			root = filepath.Dir(root)
		}
		*server = fmt.Sprintf("host=%s port=54329 user=postgres", filepath.Join(root, "build"))
	}
	ctx := context.Background()
	c := &checker{sessions: *sessions, keys: *keys, iso: *iso, feed: map[string]int{}}
	must(setup(ctx, *server, *db, *nbranch, c, *cmod))
	mode := ""
	if *kill {
		mode = ", kill -9 mid-run"
	}
	if *failover {
		mode = ", failover to a promoted standby mid-run"
	}
	if *replica != "" {
		mode += ", replayed on a standby too"
	}
	if *cmod {
		mode += ", C module (C trigger, watermarks, C read context)"
	}
	fmt.Printf("histcheck: %d sessions, %d keys, %d branches, %s, %s%s\n", *sessions, *keys, *nbranch, *iso, *dur, mode)

	runCtx, stop := context.WithTimeout(ctx, *dur)
	var wg sync.WaitGroup
	for i := 0; i < c.sessions; i++ {
		wg.Add(1)
		go func(i int) { defer wg.Done(); c.worker(runCtx, int64(i)) }(i)
	}
	wg.Add(1)
	go func() { defer wg.Done(); c.poller(runCtx) }()
	if *kill {
		go func() {
			time.Sleep(*dur / 2)
			if err := crash(*pgdata); err != nil {
				fmt.Println("kill failed:", err)
				os.Exit(2)
			}
		}()
	}
	if *failover {
		go func() {
			time.Sleep(*dur / 2)
			if err := promote(*pgdata, *standbyData); err != nil {
				fmt.Println("failover failed:", err)
				os.Exit(2)
			}
			c.setDSN(*standbyServer + " dbname=" + *db)
		}()
	}
	wg.Wait()
	stop()
	waitUp(ctx, c.dsn())
	c.poll(ctx, true) // drain the feed

	fmt.Printf("ran: %d writes committed, %d aborted (40001/40P01/crash), %d reads logged, %d feed polls in doubt (resolved)\n",
		c.writes.Load(), c.aborts.Load(), len(c.reads), c.inDoubt.Load())
	if *verifyMax > 0 && len(c.reads) > *verifyMax {
		step := float64(len(c.reads)) / float64(*verifyMax)
		sample := make([]read, 0, *verifyMax)
		for i := 0; i < *verifyMax; i++ {
			sample = append(sample, c.reads[int(float64(i)*step)])
		}
		fmt.Printf("verifying %d of %d logged reads (sampled evenly)\n", len(sample), len(c.reads))
		c.reads = sample
	}
	failures := c.verify(ctx, c.dsn(), "")
	if *replica != "" {
		failures += c.verify(ctx, *replica+" dbname="+*db, "on the standby: ")
	}
	if failures > 0 {
		fmt.Printf("FAILED: %d violation(s)\n", failures)
		os.Exit(1)
	}
	fmt.Println("ok: all properties hold")
}

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "histcheck:", err)
		os.Exit(2)
	}
}

func setup(ctx context.Context, server, db string, nbranch int, c *checker, cmod bool) error {
	admin, err := pgx.Connect(ctx, server+" dbname=postgres")
	if err != nil {
		return err
	}
	defer admin.Close(ctx)
	_, _ = admin.Exec(ctx, "drop database if exists "+db+" with (force)")
	if _, err := admin.Exec(ctx, "create database "+db); err != nil {
		return err
	}
	c.setDSN(server + " dbname=" + db)
	conn, err := pgx.Connect(ctx, c.dsn())
	if err != nil {
		return err
	}
	defer conn.Close(ctx)
	stmts := []string{
		"set client_min_messages = warning",
		"create extension gnomon",
		"create table kv (id int primary key, v int not null, w text)",
		fmt.Sprintf("insert into kv select g, 0, 'w' || g from generate_series(1, %d, 2) g", c.keys),
		"select gnomon.track('kv', part_span => 500)",
		"select gnomon.feed_create('histcheck', 'now')",
	}
	if cmod {
		stmts = append(stmts, "create extension gnomon_c", "select gnomon.use_c_trigger('kv')")
	}
	for _, s := range stmts {
		if _, err := conn.Exec(ctx, s); err != nil {
			return fmt.Errorf("%s: %w", s, err)
		}
	}
	for i := 0; i < nbranch; i++ {
		b := fmt.Sprintf("b%d", i)
		parent := "main"
		if i > 0 && i%2 == 0 {
			parent = fmt.Sprintf("b%d", i-1) // nested branches too
		}
		if _, err := conn.Exec(ctx, "select gnomon.create_branch($1, $2)", b, parent); err != nil {
			return err
		}
		c.branches = append(c.branches, b)
	}
	return nil
}

func retryable(err error) bool {
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		// macOS can fail a file open with EINTR, which PostgreSQL reports as XX000: the server's
		// environment, not a history property
		if pe.Code == "XX000" && strings.Contains(pe.Message, "Interrupted system call") {
			return true
		}
		return pe.Code == "40001" || pe.Code == "40P01" || pe.Code == "23505" || strings.HasPrefix(pe.Code, "57") || strings.HasPrefix(pe.Code, "08")
	}
	return true // connection errors during a crash
}

func (c *checker) worker(ctx context.Context, seed int64) {
	rng := rand.New(rand.NewSource(time.Now().UnixNano() + seed))
	var conn *pgx.Conn
	for ctx.Err() == nil {
		if conn == nil || conn.IsClosed() {
			var err error
			conn, err = pgx.Connect(ctx, c.dsn())
			if err != nil {
				time.Sleep(100 * time.Millisecond)
				continue
			}
		}
		branch := "main"
		if rng.Intn(3) > 0 && len(c.branches) > 0 {
			branch = c.branches[rng.Intn(len(c.branches))]
		}
		var err error
		if rng.Intn(3) == 0 {
			err = c.read(ctx, conn, branch)
		} else {
			err = c.write(ctx, conn, branch, rng)
		}
		if err != nil {
			if ctx.Err() != nil {
				break
			}
			if retryable(err) {
				c.aborts.Add(1)
			} else {
				c.errs.Add(1)
				fmt.Println("unexpected error:", err)
			}
			if conn.IsClosed() || strings.Contains(err.Error(), "conn") {
				conn.Close(context.Background())
				conn = nil
			}
		}
	}
	if conn != nil {
		conn.Close(context.Background())
	}
}

func (c *checker) write(ctx context.Context, conn *pgx.Conn, branch string, rng *rand.Rand) error {
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.TxIsoLevel(c.iso)})
	if err != nil {
		return err
	}
	defer tx.Rollback(context.Background())
	if branch != "main" {
		if _, err := tx.Exec(ctx, "select gnomon.begin($1)", branch); err != nil {
			return err
		}
	}
	k := 1 + rng.Intn(c.keys)
	for i, n := 0, 1+rng.Intn(3); i < n; i++ {
		var q string
		switch rng.Intn(5) {
		case 0:
			q = "insert into kv values ($1, $2, 'ins') on conflict do nothing"
			if branch != "main" {
				q = "insert into kv select $1, $2, 'ins' where not exists (select 1 from kv where id = $1)"
			}
		case 1:
			q = "delete from kv where id = $1 and $2 >= 0"
		case 2:
			q = "update kv set w = w || '.' where id = $1 and $2 >= 0"
		default:
			q = "update kv set v = v + $2 where id = $1"
		}
		if _, err := tx.Exec(ctx, q, k, rng.Intn(10)); err != nil {
			return err
		}
		k = 1 + (k+rng.Intn(7))%c.keys
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	c.writes.Add(1)
	return nil
}

const snapshotSQL = "select gnomon.coordinate_text(), coalesce(jsonb_agg(jsonb_build_array(id, v, w) order by id), '[]')::text from kv"

// The same rows without capturing a coordinate (coordinates are captured on the primary only).
const replaySQL = "select '', coalesce(jsonb_agg(jsonb_build_array(id, v, w) order by id), '[]')::text from kv"

func rowsOf(js string) (map[int]string, string, error) {
	var arr [][]any
	if err := json.Unmarshal([]byte(js), &arr); err != nil {
		return nil, "", err
	}
	m := map[int]string{}
	for _, r := range arr {
		id := int(r[0].(float64))
		if _, dup := m[id]; dup {
			return nil, "", fmt.Errorf("key %d appears twice in one read", id)
		}
		m[id] = fmt.Sprintf("%v|%v", r[1], r[2])
	}
	h := sha256.Sum256([]byte(js))
	return m, hex.EncodeToString(h[:8]), nil
}

// A read in its own read-only transaction; the coordinate comes from the same statement.
func (c *checker) read(ctx context.Context, conn *pgx.Conn, branch string) error {
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return err
	}
	defer tx.Rollback(context.Background())
	if branch != "main" {
		if _, err := tx.Exec(ctx, "select gnomon.begin($1)", branch); err != nil {
			return err
		}
	}
	var coord, js string
	if err := tx.QueryRow(ctx, snapshotSQL).Scan(&coord, &js); err != nil {
		return err
	}
	rows, h, err := rowsOf(js)
	if err != nil {
		fmt.Printf("VIOLATION (4) on %s at %s: %v\n", branch, coord, err)
		c.errs.Add(1)
		return nil
	}
	// point reads by key in the same snapshot must agree with the scan (with the C module they
	// take its point-read path, a custom scan, instead of the routing view)
	for i := 0; i < 3; i++ {
		k := 1 + rand.Intn(c.keys)
		var one string
		err := tx.QueryRow(ctx, pointSQL, k).Scan(&one)
		want, present := rows[k]
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			if present {
				fmt.Printf("VIOLATION (point read) on %s at %s: key %d missing, the scan has %s\n", branch, coord, k, want)
				c.errs.Add(1)
			}
		case err != nil:
			return err
		default:
			got, _, perr := rowsOf("[" + one + "]")
			if perr != nil || !present || got[k] != want {
				fmt.Printf("VIOLATION (point read) on %s at %s: key %d reads %s, the scan has %q\n", branch, coord, k, one, want)
				c.errs.Add(1)
			}
		}
	}
	c.mu.Lock()
	c.reads = append(c.reads, read{Branch: branch, Coord: coord, Hash: h, Rows: rows})
	c.points.Add(3)
	c.mu.Unlock()
	return nil
}

// One row by key, in the scan's JSON form.
const pointSQL = "select jsonb_build_array(id, v, w)::text from kv where id = $1"

func (c *checker) poller(ctx context.Context) {
	for ctx.Err() == nil {
		c.poll(ctx, false)
		time.Sleep(50 * time.Millisecond)
	}
}

func (c *checker) poll(ctx context.Context, drain bool) {
	for {
		conn, err := pgx.Connect(context.Background(), c.dsn())
		if err != nil {
			if !drain {
				return
			}
			time.Sleep(200 * time.Millisecond)
			continue
		}
		for {
			n, err := c.pollOnce(conn)
			if err != nil {
				conn.Close(context.Background())
				break
			}
			// a short batch ends the consumer's window (feed_poll), which may have been fixed
			// before the last writes committed: when draining, poll on until a window is empty
			if n < 500 && !(drain && n > 0) {
				conn.Close(context.Background())
				return
			}
		}
		if !drain {
			return
		}
	}
}

const consumerState = "select pos::text || '|' || coalesce(pending_to::text, '') || '|' || pending_off from gnomon.consumer where name = 'histcheck'"

// One feed_poll batch in a transaction that also reads the consumer's position before and after.
// When the commit's outcome is unknown (the server went away while committing), the position
// found after reconnecting says whether the batch was consumed: exactly-once accounting even
// across a crash or a failover.
func (c *checker) pollOnce(conn *pgx.Conn) (int, error) {
	bg := context.Background()
	tx, err := conn.Begin(bg)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(bg)
	var before, after string
	if err := tx.QueryRow(bg, consumerState).Scan(&before); err != nil {
		return 0, err
	}
	rows, err := tx.Query(bg, "select vkey::text || '/' || vlsn::text || '/' || key::text from gnomon.feed_poll('histcheck', 500)")
	if err != nil {
		return 0, err
	}
	var batch []string
	for rows.Next() {
		var k string
		_ = rows.Scan(&k)
		batch = append(batch, k)
	}
	rows.Close()
	if rows.Err() != nil {
		return 0, rows.Err()
	}
	if err := tx.QueryRow(bg, consumerState).Scan(&after); err != nil {
		return 0, err
	}
	if err := tx.Commit(bg); err != nil {
		var pe *pgconn.PgError
		if errors.As(err, &pe) {
			return 0, err // the server rolled it back
		}
		// unknown outcome: ask the server (perhaps a new primary) where the consumer is now
		c.inDoubt.Add(1)
		for i := 0; ; i++ {
			conn2, cerr := pgx.Connect(bg, c.dsn())
			if cerr == nil {
				var now string
				qerr := conn2.QueryRow(bg, consumerState).Scan(&now)
				conn2.Close(bg)
				if qerr == nil {
					switch now {
					case after:
						c.count(batch)
					case before:
					default:
						fmt.Printf("VIOLATION (2): consumer position %q after an in-doubt poll is neither %q nor %q\n", now, before, after)
						c.errs.Add(1)
					}
					return 0, err
				}
			}
			if i > 300 {
				return 0, err
			}
			time.Sleep(100 * time.Millisecond)
		}
	}
	c.count(batch)
	return len(batch), nil
}

func (c *checker) count(batch []string) {
	c.mu.Lock()
	for _, k := range batch {
		c.feed[k]++
	}
	c.mu.Unlock()
}

// promote kills the primary with SIGKILL and promotes the standby.
func promote(primary, standby string) error {
	b, err := os.ReadFile(filepath.Join(primary, "postmaster.pid"))
	if err != nil {
		return err
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(strings.SplitN(string(b), "\n", 2)[0]))
	fmt.Printf("kill -9 primary %d; promoting the standby\n", pid)
	if err := exec.Command("kill", "-9", strconv.Itoa(pid)).Run(); err != nil {
		return err
	}
	cmd := exec.Command("pg_ctl", "-D", standby, "-w", "promote")
	cmd.Env = append(os.Environ(), "LC_ALL=en_US.UTF-8")
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("promote: %v: %s", err, out)
	}
	fmt.Println("standby promoted")
	return nil
}

func crash(pgdata string) error {
	b, err := os.ReadFile(filepath.Join(pgdata, "postmaster.pid"))
	if err != nil {
		return err
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(strings.SplitN(string(b), "\n", 2)[0]))
	fmt.Printf("kill -9 postmaster %d\n", pid)
	if err := exec.Command("kill", "-9", strconv.Itoa(pid)).Run(); err != nil {
		return err
	}
	time.Sleep(500 * time.Millisecond)
	// orphaned backends exit when they notice the postmaster is gone
	for i := 0; i < 50; i++ {
		if out, _ := exec.Command("pgrep", "-f", "postgres.*"+filepath.Base(pgdata)).Output(); len(out) == 0 {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	_ = os.Remove(filepath.Join(pgdata, "postmaster.pid"))
	cmd := exec.Command("pg_ctl", "-D", pgdata, "-l", pgdata+".log", "-w", "start")
	cmd.Env = append(os.Environ(), "LC_ALL=en_US.UTF-8")
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("restart: %v: %s", err, out)
	}
	fmt.Println("restarted after crash recovery")
	return nil
}

func waitUp(ctx context.Context, dsn string) {
	for i := 0; i < 100; i++ {
		if c, err := pgx.Connect(ctx, dsn); err == nil {
			c.Close(ctx)
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func (c *checker) verify(ctx context.Context, dsn, where string) int {
	conn, err := pgx.Connect(ctx, dsn)
	must(err)
	defer conn.Close(ctx)
	failures := 0
	if where == "" {
		failures = int(c.errs.Load())
	}

	// 1. replay at every returned coordinate
	replayed := 0
	for _, r := range c.reads {
		if _, err := conn.Exec(ctx, "select gnomon.use($1, $2)", r.Branch, r.Coord); err != nil {
			fmt.Println(where+"VIOLATION (1) cannot replay:", err)
			failures++
			continue
		}
		var coord, js string
		if err := conn.QueryRow(ctx, replaySQL).Scan(&coord, &js); err != nil {
			fmt.Println(where+"VIOLATION (1) replay failed:", err)
			failures++
			continue
		}
		rows, _, err := rowsOf(js)
		if err != nil {
			fmt.Printf("VIOLATION (4) on replay of %s at %s: %v\n", r.Branch, r.Coord, err)
			failures++
			continue
		}
		if !sameRows(rows, r.Rows) {
			fmt.Printf("%sVIOLATION (1) replay of %s at %s differs:%s\n", where, r.Branch, r.Coord, rowDiff(r.Rows, rows))
			failures++
		}
		replayed++
	}
	_, _ = conn.Exec(ctx, "select gnomon.use('main')")
	fmt.Printf("%s(1) replayed %d reads; %d point reads matched their snapshot's scan\n", where, replayed, c.points.Load())
	if where != "" {
		return failures // a standby: replay only (the feed and branch checks read the primary's catalog)
	}

	// 2. feed = committed versions
	vrows, err := conn.Query(ctx, "select gn_key::text || '/' || gn_lsn::text || '/' || jsonb_build_object('id', id)::text from _gnomon.kv__v where gn_flags & 48 = 0")
	must(err)
	committed := map[string]bool{}
	for vrows.Next() {
		var k string
		_ = vrows.Scan(&k)
		committed[k] = true
	}
	vrows.Close()
	dups, missing, extra := 0, 0, 0
	for k, n := range c.feed {
		if n > 1 {
			dups++
			fmt.Println("duplicate in feed:", k, n)
		}
		if !committed[k] {
			extra++
		}
	}
	for k := range committed {
		if c.feed[k] == 0 {
			missing++
		}
	}
	fmt.Printf("(2) feed: %d versions, %d delivered, %d duplicates, %d missing, %d not committed\n", len(committed), len(c.feed), dups, missing, extra)
	failures += dups + missing + extra

	// 3 and 4. on branches, untouched keys read as main at the branch's cutoff
	checked := 0
	for _, r := range c.reads {
		if r.Branch == "main" {
			continue
		}
		var cutoff string
		if err := conn.QueryRow(ctx, `select gnomon.coord_text(bb.lin_c[cardinality(bb.lin_c)])
		    from gnomon.branch b, lateral (select (gnomon._base_at(b.id, gnomon.coord($2))).*) bb where b.name = $1`, r.Branch, r.Coord).Scan(&cutoff); err != nil {
			fmt.Println("cannot read cutoff:", err)
			failures++
			continue
		}
		touched := map[int]bool{}
		trows, err := conn.Query(ctx, `select k.id from _gnomon.kv__bk k
		     join unnest((gnomon._ctx_compute($1, $2, null)).lb) with ordinality l(br, ord) on k.gn_branch = l.br
		    where gnomon._vis(k.gn_fkey, k.gn_fxoff, ((gnomon._ctx_compute($1, $2, null)).lc)[l.ord])`, r.Branch, r.Coord)
		must(err)
		for trows.Next() {
			var id int
			_ = trows.Scan(&id)
			touched[id] = true
		}
		trows.Close()
		// main at the main cutoff of this branch's lineage
		if _, err := conn.Exec(ctx, "select gnomon.use('main', $1)", cutoff); err != nil {
			fmt.Println("cannot read main at cutoff:", err)
			failures++
			continue
		}
		var js, coord string
		must(conn.QueryRow(ctx, snapshotSQL).Scan(&coord, &js))
		mainAt, _, _ := rowsOf(js)
		_, _ = conn.Exec(ctx, "select gnomon.use('main')")
		for id := 1; id <= c.keys; id++ {
			if touched[id] {
				continue
			}
			if r.Rows[id] != mainAt[id] {
				fmt.Printf("VIOLATION (3) %s at %s: untouched key %d reads %q, main at cutoff has %q\n", r.Branch, r.Coord, id, r.Rows[id], mainAt[id])
				failures++
			}
		}
		checked++
	}
	fmt.Printf("(3,4) checked %d branch reads against main at their cutoffs\n", checked)

	// 5. along one row on one line, version keys never decrease. Writes of a
	// row are serialized, and each version records the WAL insert position at its write, so
	// ordering by (key, LSN) must agree with ordering by LSN alone. Copies (baselines and
	// carry-forward keyframes, flags 16 and 32) keep their original stamps and are skipped.
	var inv int
	must(conn.QueryRow(ctx, `select (select count(*) from (select gn_key, lag(gn_key) over (partition by id order by gn_lsn) pk
	                                   from _gnomon.kv__v where gn_flags & 48 = 0) x where gn_key < pk)
	                              + (select count(*) from (select gn_key, lag(gn_key) over (partition by gn_branch, id order by gn_lsn) pk
	                                   from _gnomon.kv__bv where gn_flags & 48 = 0) x where gn_key < pk)`).Scan(&inv))
	fmt.Printf("(5) version keys out of write order: %d\n", inv)
	failures += inv
	return failures
}

// rowDiff lists the keys whose rows differ: logged -> replayed.
func rowDiff(logged, replayed map[int]string) string {
	out := ""
	for id := 0; id <= 100000 && len(out) < 400; id++ {
		a, okA := logged[id]
		b, okB := replayed[id]
		if okA != okB || a != b {
			out += fmt.Sprintf(" key %d: %q -> %q;", id, a, b)
		}
	}
	return out
}

func sameRows(a, b map[int]string) bool {
	if len(a) != len(b) {
		return false
	}
	keys := make([]int, 0, len(a))
	for k := range a {
		keys = append(keys, k)
	}
	sort.Ints(keys)
	for _, k := range keys {
		if a[k] != b[k] {
			return false
		}
	}
	return true
}
