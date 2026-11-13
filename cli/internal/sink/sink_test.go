package sink

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/bitsinfra/gnomon/cli/internal/testdb"
	"github.com/jackc/pgx/v5"
)

// At least once with exact accounting: across scheduled failures, the delivered ids, deduplicated,
// equal the committed changes; the job loop runs as a gnomon_admin member, not a superuser.
func TestSinks(t *testing.T) {
	dsn := testdb.New(t, t.Name())
	daemon := fmt.Sprintf("cli_sinkd_%d", os.Getpid())
	testdb.Exec(t, dsn,
		"create table ev (id int primary key, v int not null)",
		"select gnomon.track('ev')",
		"drop role if exists "+daemon, "create role "+daemon+" login", "grant gnomon_admin to "+daemon)
	t.Cleanup(func() {
		testdb.Exec(t, dsn, "drop owned by "+daemon)
		testdb.Exec(t, testdb.Base()+" dbname=postgres", "drop role if exists "+daemon)
	})

	var mu sync.Mutex
	calls := 0
	seen := map[string]int{}
	hook := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		calls++
		b, _ := io.ReadAll(r.Body)
		var msgs []map[string]any
		_ = json.Unmarshal(b, &msgs)
		if calls%3 == 2 { // every third call fails: the batch must come again
			http.Error(w, "scheduled failure", 503)
			return
		}
		if r.Header.Get("X-Gnomon-Signature") == "" || r.Header.Get("Idempotency-Key") == "" {
			http.Error(w, "unsigned", 400)
			return
		}
		for _, m := range msgs {
			if m["type"] == "change" {
				seen[fmt.Sprint(m["id"])]++
			}
		}
	}))
	defer hook.Close()

	nats, natsGot := fakeNATS(t)
	file := filepath.Join(t.TempDir(), "changes.jsonl")
	testdb.Exec(t, dsn,
		fmt.Sprintf(`select gnomon.sink_add('hook', 'webhook', '{"url": "%s", "secret": "s3cret", "batch": 7}')`, hook.URL),
		fmt.Sprintf(`select gnomon.sink_add('file', 'file', '{"path": "%s", "transactions": true}', format => 'debezium')`, file),
		fmt.Sprintf(`select gnomon.sink_add('nats', 'nats', '{"url": "nats://%s", "subject": "gn.test"}', format => 'cloudevents')`, nats))
	for i := 0; i < 10; i++ {
		testdb.Exec(t, dsn, fmt.Sprintf("insert into ev select g, %d from generate_series(%d, %d) g", i, i*5+1, i*5+5))
		testdb.Exec(t, dsn, fmt.Sprintf("update ev set v = v + 1 where id %% 3 = %d", i%3))
	}
	want := testdb.Scalar(t, dsn, "select count(*) from gnomon.changes((select gnomon.coord_text(track_coord) from gnomon.tracked where relname = 'ev'))")

	ctx := context.Background()
	c, err := pgx.Connect(ctx, testdb.WithUser(dsn, daemon))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close(ctx)
	MaxFailures = 100
	logs := []string{}
	for pass := 0; pass < 60; pass++ {
		testdb.Exec(t, dsn, "update gnomon.sink set updated_at = now() - interval '1 hour'") // skip the backoff in the test
		Deliver(ctx, c, func(s string) { logs = append(logs, s) })
		if testdb.Scalar(t, dsn, "select count(*) from gnomon.consumer c where c.name like 'sink:%' and c.pending_to is null and c.pos is not null and (select delivered from gnomon.sink where name = 'hook') > 0 and (select delivered from gnomon.sink where name = 'hook') >= "+want) == "1" {
			break
		}
	}
	mu.Lock()
	n := len(seen)
	dup := 0
	for _, v := range seen {
		if v > 1 {
			dup++
		}
	}
	mu.Unlock()
	if strconv.Itoa(n) != want {
		t.Fatalf("webhook got %d distinct changes, want %s (logs: %v)", n, want, logs)
	}
	if testdb.Scalar(t, dsn, "select delivered from gnomon.sink where name = 'hook'") != want {
		t.Fatalf("delivered count: %s", testdb.Scalar(t, dsn, "select delivered from gnomon.sink where name = 'hook'"))
	}
	if !strings.Contains(strings.Join(logs, "\n"), "503") {
		t.Fatalf("the scheduled failures never happened: %v", logs)
	}
	_ = dup // (duplicates are allowed: at least once)
	// the file sink: Debezium-shaped, with transaction markers
	b, _ := os.ReadFile(file)
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	changes, begins := 0, 0
	for _, l := range lines {
		var m map[string]any
		_ = json.Unmarshal([]byte(l), &m)
		if m["type"] == "begin" {
			begins++
		}
		if m["op"] != nil && m["source"] != nil {
			changes++
		}
	}
	if strconv.Itoa(changes) != want || begins < 10 {
		t.Fatalf("file sink: %d changes, %d transactions", changes, begins)
	}
	// NATS: one message per change with a Nats-Msg-Id header
	got := natsGot()
	ids := map[string]bool{}
	for _, m := range got {
		ids[m] = true
	}
	if strconv.Itoa(len(ids)) != want {
		t.Fatalf("nats got %d distinct ids, want %s", len(ids), want)
	}
	// a paused sink delivers nothing; replay delivers again
	testdb.Exec(t, dsn, "select gnomon.sink_status('hook', 'paused')", "insert into ev values (999, 1)")
	before := testdb.Scalar(t, dsn, "select delivered from gnomon.sink where name = 'hook'")
	Deliver(ctx, c, func(string) {})
	if testdb.Scalar(t, dsn, "select delivered from gnomon.sink where name = 'hook'") != before {
		t.Fatal("a paused sink delivered")
	}
}

// fakeNATS accepts NATS clients and records the Nats-Msg-Id of every HPUB.
func fakeNATS(t *testing.T) (string, func() []string) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var ids []string
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				fmt.Fprint(conn, "INFO {\"server_id\":\"fake\",\"headers\":true}\r\n")
				rd := bufio.NewReader(conn)
				for {
					line, err := rd.ReadString('\n')
					if err != nil {
						return
					}
					f := strings.Fields(line)
					switch {
					case len(f) == 0:
					case f[0] == "PING":
						fmt.Fprint(conn, "PONG\r\n")
					case f[0] == "HPUB" && len(f) == 4:
						hl, _ := strconv.Atoi(f[2])
						tl, _ := strconv.Atoi(f[3])
						buf := make([]byte, tl+2)
						if _, err := io.ReadFull(rd, buf); err != nil {
							return
						}
						for _, h := range strings.Split(string(buf[:hl]), "\r\n") {
							if v, ok := strings.CutPrefix(h, "Nats-Msg-Id: "); ok {
								mu.Lock()
								ids = append(ids, v)
								mu.Unlock()
							}
						}
					}
				}
			}(conn)
		}
	}()
	t.Cleanup(func() { ln.Close() })
	return ln.Addr().String(), func() []string { mu.Lock(); defer mu.Unlock(); return append([]string(nil), ids...) }
}
