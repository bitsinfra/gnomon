package sink

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"io"
	"math/rand"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/bitsinfra/gnomon/cli/internal/testdb"
	"github.com/jackc/pgx/v5"
	"github.com/parquet-go/parquet-go"
)

// Kafka's own partitioner, checked against values the Java client computes.
func TestMurmur2(t *testing.T) {
	for _, c := range []struct {
		in   string
		want int32
	}{{"21", -973932308}, {"foobar", -790332482}, {"a-little-bit-long-string", -985981536},
		{"a-little-bit-longer-string", -1486304829}, {"lkjh234lh9fiuh90y23oiuhsafujhadof229phr9h19h89h8", -58897971}, {"abc", 479470107}} {
		if got := murmur2([]byte(c.in)); got != c.want {
			t.Errorf("murmur2(%q) = %d, want %d", c.in, got, c.want)
		}
	}
}

type fakeRecord struct {
	part    int32
	key     string
	value   map[string]any
	headers map[string]string
}

// fakeKafka speaks Metadata v1, InitProducerId v0 and Produce v3, checks each batch's CRC-32C,
// keeps idempotent-producer sequences (a duplicate batch is acknowledged and not appended), and
// on every fifth produce request appends the batch and then drops the connection without the
// acknowledgement.
func fakeKafka(t *testing.T, topic string, partitions int) (string, func() []fakeRecord) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	host, portS, _ := net.SplitHostPort(ln.Addr().String())
	port, _ := strconv.Atoi(portS)
	var mu sync.Mutex
	var log []fakeRecord
	next := map[string]int32{}
	pids := int64(1000)
	produces := 0
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				for {
					var size [4]byte
					if _, err := io.ReadFull(conn, size[:]); err != nil {
						return
					}
					req := make([]byte, binary.BigEndian.Uint32(size[:]))
					if _, err := io.ReadFull(conn, req); err != nil {
						return
					}
					r := &kread{b: req}
					api := r.i16()
					ver := r.i16()
					corr := r.i32()
					_ = r.str()
					var out kbuf
					out.i32(corr)
					drop := false
					switch api {
					case 3:
						// Metadata v4, as Kafka 4 requires (it no longer serves v0-v3)
						if ver != 4 {
							t.Errorf("fake kafka: Metadata v%d, want v4", ver)
							return
						}
						out.i32(0) // throttle_time_ms
						out.i32(1)
						out.i32(1)
						out.str(host)
						out.i32(int32(port))
						out.nullStr()
						out.nullStr() // cluster_id
						out.i32(1)
						out.i32(1)
						out.i16(0)
						out.str(topic)
						out.i8(0)
						out.i32(int32(partitions))
						for p := 0; p < partitions; p++ {
							out.i16(0)
							out.i32(int32(p))
							out.i32(1)
							out.i32(1)
							out.i32(1)
							out.i32(1)
							out.i32(1)
						}
					case 22:
						mu.Lock()
						pids++
						pid := pids
						mu.Unlock()
						out.i32(0)
						out.i16(0)
						out.i64(pid)
						out.i16(0)
					case 0:
						_ = r.str()
						_ = r.i16()
						_ = r.i32()
						var results [][2]int32
						for nt := r.i32(); nt > 0; nt-- {
							_ = r.str()
							for np := r.i32(); np > 0; np-- {
								part := r.i32()
								code := appendBatch(t, &mu, &log, next, part, r.bytes())
								results = append(results, [2]int32{part, int32(code)})
							}
						}
						mu.Lock()
						produces++
						drop = produces%5 == 0
						mu.Unlock()
						out.i32(1)
						out.str(topic)
						out.i32(int32(len(results)))
						for _, res := range results {
							out.i32(res[0])
							out.i16(int16(res[1]))
							out.i64(0)
							out.i64(-1)
						}
						out.i32(0)
					default:
						return
					}
					if drop {
						return // appended, never acknowledged
					}
					frame := binary.BigEndian.AppendUint32(nil, uint32(len(out.b)))
					if _, err := conn.Write(append(frame, out.b...)); err != nil {
						return
					}
				}
			}(conn)
		}
	}()
	t.Cleanup(func() { ln.Close() })
	return ln.Addr().String(), func() []fakeRecord { mu.Lock(); defer mu.Unlock(); return append([]fakeRecord(nil), log...) }
}

// appendBatch decodes a v2 record batch; returns the partition's error code.
func appendBatch(t *testing.T, mu *sync.Mutex, log *[]fakeRecord, next map[string]int32, part int32, b []byte) int {
	r := &kread{b: b}
	_ = r.i64()
	_ = r.i32()
	_ = r.i32()
	if r.i8() != 2 {
		t.Errorf("magic is not 2")
		return 2
	}
	crc := uint32(r.i32())
	if crc32.Checksum(b[r.off:], crc32.MakeTable(crc32.Castagnoli)) != crc {
		t.Errorf("CRC-32C mismatch")
		return 2
	}
	_ = r.i16()
	_ = r.i32()
	_ = r.i64()
	_ = r.i64()
	pid := r.i64()
	epoch := r.i16()
	base := r.i32()
	n := r.i32()
	var recs []fakeRecord
	for i := int32(0); i < n; i++ {
		_ = r.varint()
		_ = r.i8()
		_ = r.varint()
		_ = r.varint()
		k := string(r.varBytes())
		var v map[string]any
		_ = json.Unmarshal(r.varBytes(), &v)
		h := map[string]string{}
		for nh := r.varint(); nh > 0; nh-- {
			hk := string(r.varBytes())
			h[hk] = string(r.varBytes())
		}
		recs = append(recs, fakeRecord{part: part, key: k, value: v, headers: h})
	}
	if r.err != nil {
		t.Errorf("record batch: %v", r.err)
		return 2
	}
	mu.Lock()
	defer mu.Unlock()
	id := fmt.Sprintf("%d/%d/%d", pid, epoch, part)
	switch {
	case base == next[id]:
		*log = append(*log, recs...)
		next[id] = base + n
		return 0
	case base+n <= next[id]:
		return 0 // a duplicate: acknowledged, not appended (KIP-98)
	default:
		return 45 // out of order
	}
}

// Exactly once into Kafka across lost acknowledgements, keyed partitioning, and one Parquet file
// per batch.
func TestKafkaAndParquetSinks(t *testing.T) {
	dsn := testdb.New(t, t.Name())
	daemon := fmt.Sprintf("cli_ksinkd_%d", os.Getpid())
	testdb.Exec(t, dsn,
		"create table ev (id int primary key, v int not null)",
		"select gnomon.track('ev')",
		"drop role if exists "+daemon, "create role "+daemon+" login", "grant gnomon_admin to "+daemon)
	t.Cleanup(func() {
		testdb.Exec(t, dsn, "drop owned by "+daemon)
		testdb.Exec(t, testdb.Base()+" dbname=postgres", "drop role if exists "+daemon)
	})
	addr, records := fakeKafka(t, "gn.test", 3)
	dir := t.TempDir()
	testdb.Exec(t, dsn,
		fmt.Sprintf(`select gnomon.sink_add('k', 'kafka', '{"brokers": "%s", "topic": "gn.test", "batch": 7}')`, addr),
		fmt.Sprintf(`select gnomon.sink_add('pq', 'parquet', '{"to": "%s", "batch": 11}', format => 'debezium')`, dir))
	for i := 0; i < 10; i++ {
		testdb.Exec(t, dsn, fmt.Sprintf("insert into ev select g, %d from generate_series(%d, %d) g", i, i*5+1, i*5+5))
		testdb.Exec(t, dsn, fmt.Sprintf("update ev set v = v + 1 where id %% 3 = %d", i%3))
	}
	want, _ := strconv.Atoi(testdb.Scalar(t, dsn, "select count(*) from gnomon.changes((select gnomon.coord_text(track_coord) from gnomon.tracked where relname = 'ev'))"))
	ctx := context.Background()
	c, err := pgx.Connect(ctx, testdb.WithUser(dsn, daemon))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close(ctx)
	MaxFailures = 1000
	var logs []string
	for pass := 0; pass < 100; pass++ {
		testdb.Exec(t, dsn, "update gnomon.sink set updated_at = now() - interval '1 hour'")
		Deliver(ctx, c, func(s string) { logs = append(logs, s) })
		if testdb.Scalar(t, dsn, fmt.Sprintf("select count(*) from gnomon.sink where delivered >= %d", want)) == "2" {
			break
		}
	}
	got := records()
	ids := map[string]int{}
	for _, r := range got {
		ids[r.headers["gnomon-id"]]++
		if p := KafkaPartition([]byte(r.key), 3); p != r.part {
			t.Fatalf("key %s on partition %d, Kafka's partitioner says %d", r.key, r.part, p)
		}
	}
	if len(ids) != want || len(got) != want {
		t.Fatalf("kafka: %d records, %d distinct, want %d exactly once (logs: %v)", len(got), len(ids), want, logs)
	}
	lost := 0
	for _, l := range logs {
		if l != "" {
			lost++
		}
	}
	if lost == 0 {
		t.Fatal("no acknowledgement was ever lost: the test did not exercise redelivery")
	}
	// one row's changes in order on its partition
	last := map[string]float64{}
	for _, r := range got {
		vk, _ := r.value["vkey"].(float64)
		if vk < last[r.key] {
			t.Fatalf("key %s out of order", r.key)
		}
		last[r.key] = vk
	}
	// the sink's producer state is saved
	if testdb.Scalar(t, dsn, "select (state ->> 'producer_id')::bigint > 0 from gnomon.sink where name = 'k'") != "true" {
		t.Fatal("producer state not saved")
	}
	// Parquet: the files hold every change once
	files, _ := filepath.Glob(filepath.Join(dir, "pq-*.parquet"))
	seen := map[string]bool{}
	rows := 0
	for _, f := range files {
		fh, err := os.Open(f)
		if err != nil {
			t.Fatal(err)
		}
		st, _ := fh.Stat()
		pf, err := parquet.OpenFile(fh, st.Size())
		if err != nil {
			t.Fatal(err)
		}
		idCol := -1
		for i, p := range pf.Schema().Columns() {
			if p[0] == "id" {
				idCol = i
			}
		}
		for _, rg := range pf.RowGroups() {
			rr := rg.Rows()
			buf := make([]parquet.Row, 64)
			for {
				n, err := rr.ReadRows(buf)
				for _, row := range buf[:n] {
					rows++
					seen[row[idCol].String()] = true
				}
				if err != nil {
					break
				}
			}
			rr.Close()
		}
		fh.Close()
	}
	if len(seen) != want || rows != want {
		t.Fatalf("parquet: %d rows, %d distinct, want %d", rows, len(seen), want)
	}
}

// The delivery process killed with SIGKILL again and again mid-stream: restarted each time, the webhook still receives every committed change at least
// once, and the sink's count is exact.
func TestSinkSurvivesKill9(t *testing.T) {
	dsn := testdb.New(t, t.Name())
	daemon := fmt.Sprintf("cli_ksinkk_%d", os.Getpid())
	testdb.Exec(t, dsn,
		"create table ev (id int primary key, v int not null)",
		"select gnomon.track('ev')",
		"drop role if exists "+daemon, "create role "+daemon+" login", "grant gnomon_admin to "+daemon)
	t.Cleanup(func() {
		testdb.Exec(t, dsn, "drop owned by "+daemon)
		testdb.Exec(t, testdb.Base()+" dbname=postgres", "drop role if exists "+daemon)
	})
	var mu sync.Mutex
	seen := map[string]int{}
	hook := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		time.Sleep(15 * time.Millisecond) // a window for the kill between accepting and committing
		var msgs []map[string]any
		_ = json.Unmarshal(b, &msgs)
		mu.Lock()
		for _, m := range msgs {
			seen[fmt.Sprint(m["id"])]++
		}
		mu.Unlock()
	}))
	defer hook.Close()
	testdb.Exec(t, dsn, fmt.Sprintf(`select gnomon.sink_add('h', 'webhook', '{"url": "%s", "secret": "s", "batch": 5}')`, hook.URL))
	for i := 0; i < 20; i++ {
		testdb.Exec(t, dsn, fmt.Sprintf("insert into ev select g, %d from generate_series(%d, %d) g", i, i*10+1, i*10+10))
	}
	want, _ := strconv.Atoi(testdb.Scalar(t, dsn, "select count(*) from gnomon.changes((select gnomon.coord_text(track_coord) from gnomon.tracked where relname = 'ev'))"))
	kills := 0
	for round := 0; round < 12; round++ {
		cmd := exec.Command(os.Args[0], "-test.run=^$")
		cmd.Env = append(os.Environ(), "GNOMON_SINK_CHILD="+testdb.WithUser(dsn, daemon))
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		time.Sleep(time.Duration(40+rand.Intn(60)) * time.Millisecond)
		_ = cmd.Process.Signal(syscall.SIGKILL)
		_ = cmd.Wait()
		kills++
	}
	// what is left, delivered by this process
	ctx := context.Background()
	c, err := pgx.Connect(ctx, testdb.WithUser(dsn, daemon))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close(ctx)
	for pass := 0; pass < 50; pass++ {
		Deliver(ctx, c, func(string) {})
		if testdb.Scalar(t, dsn, fmt.Sprintf("select delivered >= %d from gnomon.sink where name = 'h'", want)) == "true" {
			break
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if len(seen) != want {
		t.Fatalf("after %d kills the webhook has %d distinct changes, want %d", kills, len(seen), want)
	}
	if d := testdb.Scalar(t, dsn, "select delivered from gnomon.sink where name = 'h'"); d != strconv.Itoa(want) {
		t.Fatalf("the sink counts %s delivered, want %d", d, want)
	}
	dups := 0
	for _, n := range seen {
		if n > 1 {
			dups++
		}
	}
	t.Logf("%d kills, %d changes, %d delivered more than once (at least once)", kills, want, dups)
}

// Against a real broker (GNOMON_KAFKA_BROKERS, and GNOMON_KAFKA_TOPIC created beforehand with
// three partitions): every change is delivered, and two batches sent again as after a lost
// acknowledgement (the delivery's position and the producer's sequences set back to before them,
// as when the delivery's transaction does not commit; the producer itself was saved when it was
// made) are not appended twice. The test logs KAFKA_WANT=<n>,
// the number of records the topic must hold; test/shell/kafka.sh reads the topic back with
// Kafka's console consumer and checks it.
func TestKafkaRealBroker(t *testing.T) {
	brokers, topic := os.Getenv("GNOMON_KAFKA_BROKERS"), os.Getenv("GNOMON_KAFKA_TOPIC")
	if brokers == "" || topic == "" {
		t.Skip("GNOMON_KAFKA_BROKERS and GNOMON_KAFKA_TOPIC are not set")
	}
	dsn := testdb.New(t, t.Name())
	daemon := fmt.Sprintf("cli_kreal_%d", os.Getpid())
	testdb.Exec(t, dsn,
		"create table ev (id int primary key, v int not null)",
		"select gnomon.track('ev')",
		"drop role if exists "+daemon, "create role "+daemon+" login", "grant gnomon_admin to "+daemon)
	t.Cleanup(func() {
		testdb.Exec(t, dsn, "drop owned by "+daemon)
		testdb.Exec(t, testdb.Base()+" dbname=postgres", "drop role if exists "+daemon)
	})
	testdb.Exec(t, dsn, fmt.Sprintf(`select gnomon.sink_add('k', 'kafka', '{"brokers": "%s", "topic": "%s", "batch": 7}')`, brokers, topic))
	ctx := context.Background()
	c, err := pgx.Connect(ctx, testdb.WithUser(dsn, daemon))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close(ctx)
	deliver := func() {
		testdb.Exec(t, dsn, "update gnomon.sink set updated_at = now() - interval '1 hour'")
		Deliver(ctx, c, func(s string) {
			if s != "" {
				t.Log(s)
			}
		})
	}
	delivered := func() int {
		n, _ := strconv.Atoi(testdb.Scalar(t, dsn, "select delivered from gnomon.sink where name = 'k'"))
		return n
	}
	// one change first: the producer is made and saved (in a transaction of its own)
	testdb.Exec(t, dsn, "insert into ev values (0, 0)")
	deliver()
	if delivered() != 1 {
		t.Fatalf("first delivery: %d of 1", delivered())
	}
	// ten more (two batches), delivered, then "not committed": the delivery's position and the
	// producer's sequences go back, and the same two batches are sent again
	testdb.Exec(t, dsn,
		"create table snap_c as select c.* from gnomon.consumer c join gnomon.sink s on s.consumer = c.name where s.name = 'k'",
		"create table snap_s as select delivered, state from gnomon.sink where name = 'k'")
	testdb.Exec(t, dsn, "insert into ev select g, 0 from generate_series(1, 10) g")
	deliver()
	if delivered() != 11 {
		t.Fatalf("second delivery: %d of 11", delivered())
	}
	testdb.Exec(t, dsn, `do $$ declare cols text; begin
	  select string_agg(quote_ident(attname), ', ') into cols from pg_attribute
	   where attrelid = 'gnomon.consumer'::regclass and attnum > 0 and not attisdropped and attname <> 'name';
	  execute format('update gnomon.consumer c set (%1$s) = (select %1$s from snap_c x where x.name = c.name) where c.name in (select name from snap_c)', cols);
	  update gnomon.sink s set delivered = x.delivered, state = x.state from snap_s x where s.name = 'k';
	end $$`)
	if delivered() != 1 {
		t.Fatalf("set back: %d", delivered())
	}
	deliver()
	if delivered() != 11 {
		t.Fatalf("the same batches again: %d of 11", delivered())
	}
	// the rest: updates, deletes and more inserts across many batches
	for i := 0; i < 8; i++ {
		testdb.Exec(t, dsn, fmt.Sprintf("insert into ev select g, %d from generate_series(%d, %d) g", i, 11+i*5, 15+i*5))
		testdb.Exec(t, dsn, fmt.Sprintf("update ev set v = v + 1 where id %% 4 = %d", i%4))
		testdb.Exec(t, dsn, fmt.Sprintf("delete from ev where id = %d", 3+i*6))
	}
	want, _ := strconv.Atoi(testdb.Scalar(t, dsn, "select count(*) from gnomon.changes((select gnomon.coord_text(track_coord) from gnomon.tracked where relname = 'ev'))"))
	for pass := 0; pass < 50 && delivered() < want; pass++ {
		deliver()
	}
	if delivered() != want {
		t.Fatalf("delivered %d of %d", delivered(), want)
	}
	t.Logf("KAFKA_WANT=%d", want)
}

func TestMain(m *testing.M) {
	if dsn := os.Getenv("GNOMON_SINK_CHILD"); dsn != "" {
		ctx := context.Background()
		c, err := pgx.Connect(ctx, dsn)
		if err != nil {
			os.Exit(1)
		}
		for {
			Deliver(ctx, c, func(string) {})
			time.Sleep(2 * time.Millisecond)
		}
	}
	os.Exit(m.Run())
}
