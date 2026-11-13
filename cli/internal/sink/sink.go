// Package sink delivers gnomon's change feed to webhooks, files, NATS, Kafka and Parquet files,
// run by the job loop of gnomon daemon.
//
// Delivery is at least once: a batch is polled (which moves the sink's consumer position) and
// delivered in one transaction, committed only after the destination accepted it, so a failure
// rolls the position back and the batch is sent again. Every change carries an id (table, key,
// version key, LSN) that is a total order: webhooks get it as Idempotency-Key, NATS as
// Nats-Msg-Id (JetStream deduplicates by it), Kafka as a header with an idempotent producer
// (kafka.go), files as a field, Parquet files by their name (parquet.go). A batch that keeps failing is
// copied to gnomon.sink_dead and the sink paused.
package sink

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/bitsinfra/gnomon/cli/internal/gn"
	"github.com/jackc/pgx/v5"
)

// MaxFailures before a sink is paused and its batch kept in gnomon.sink_dead.
var MaxFailures = 5

func init() { gn.SinkJobs = Deliver }

type change struct {
	ID   string         `json:"id"`
	Vkey int64          `json:"vkey"`
	Vlsn string         `json:"lsn"`
	Tbl  string         `json:"table"`
	Key  map[string]any `json:"key"`
	Op   string         `json:"op"`
	Xid  string         `json:"xid"`
	Role any            `json:"role"`
	New  any            `json:"new"`
	Old  any            `json:"old"`
	TS   any            `json:"ts"`
}

type sinkRow struct {
	name, kind, format string
	config             map[string]any
	state              map[string]any
	failures           int
	updated            time.Time
}

// Deliver runs one delivery pass over every active sink.
func Deliver(ctx context.Context, c *pgx.Conn, log func(string)) {
	res, err := gn.Query(ctx, c, "select name, kind, config, format, failures, updated_at, state from gnomon.sink where status = 'active' order by name")
	if err != nil {
		if gn.SQLState(err) != "42P01" && gn.SQLState(err) != "42501" {
			log("sinks: " + gn.PgError(err))
		}
		return
	}
	for _, m := range res.Maps {
		s := sinkRow{name: fmt.Sprint(m["name"]), kind: fmt.Sprint(m["kind"]), format: fmt.Sprint(m["format"])}
		s.config, _ = m["config"].(map[string]any)
		s.state, _ = m["state"].(map[string]any)
		s.failures = int(toInt(m["failures"]))
		if t, err := time.Parse(time.RFC3339Nano, fmt.Sprint(m["updated_at"])); err == nil {
			s.updated = t
		}
		// backoff: 2^failures seconds after the last failure
		if s.failures > 0 && time.Since(s.updated) < time.Duration(1<<min(s.failures, 10))*time.Second {
			continue
		}
		for i := 0; i < 20; i++ { // a few batches per pass
			n, err := deliverOne(ctx, c, &s)
			if err != nil {
				fail(ctx, c, s, err, log)
				break
			}
			if n == 0 {
				break
			}
			s.failures = 0
		}
	}
}

func toInt(v any) int64 {
	switch x := v.(type) {
	case int32:
		return int64(x)
	case int64:
		return x
	case float64:
		return int64(x)
	}
	return 0
}

func deliverOne(ctx context.Context, c *pgx.Conn, s *sinkRow) (int, error) {
	// Kafka: a producer id before anything is sent, saved on its own (kafka.go)
	var kst kafkaState
	if s.kind == "kafka" {
		var err error
		kst, err = kafkaEnsureProducer(ctx, *s, func(st kafkaState) error {
			b, _ := json.Marshal(st)
			_, err := c.Exec(ctx, "select gnomon.sink_state($1, $2::jsonb)", s.name, string(b))
			return err
		})
		if err != nil {
			return 0, err
		}
	}
	tx, err := c.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	batch := 500
	if v := toInt(s.config["batch"]); v > 0 {
		batch = int(v)
	}
	res, err := gn.Query(ctx, tx.Conn(), "select id, vkey, vlsn::text, tbl, key, op, xid::text, role, new, old, ts from gnomon.sink_batch($1, $2)", s.name, batch)
	if err != nil {
		return 0, err
	}
	var ch []change
	for _, m := range res.Maps {
		k, _ := m["key"].(map[string]any)
		ch = append(ch, change{ID: fmt.Sprint(m["id"]), Vkey: toInt(m["vkey"]), Vlsn: fmt.Sprint(m["vlsn"]), Tbl: fmt.Sprint(m["tbl"]), Key: k,
			Op: fmt.Sprint(m["op"]), Xid: fmt.Sprint(m["xid"]), Role: m["role"], New: m["new"], Old: m["old"], TS: m["ts"]})
	}
	var newState *kafkaState
	if len(ch) > 0 && s.kind == "kafka" {
		plain := *s
		plain.config = map[string]any{}
		for k, v := range s.config {
			if k != "transactions" { // markers are per transaction, Kafka's order is per partition
				plain.config[k] = v
			}
		}
		next, err := kafkaPublish(ctx, plain, kst, ch, format(plain, ch))
		if err != nil {
			return 0, err
		}
		b, _ := json.Marshal(next)
		if _, err := tx.Exec(ctx, "select gnomon.sink_state($1, $2::jsonb)", s.name, string(b)); err != nil {
			return 0, err
		}
		newState = &next
	} else if len(ch) > 0 {
		if err := send(ctx, *s, ch); err != nil {
			return 0, err
		}
	}
	if len(ch) > 0 {
		if _, err := tx.Exec(ctx, "select gnomon.sink_report($1, $2)", s.name, len(ch)); err != nil {
			return 0, err
		}
	} else if s.failures > 0 {
		_, _ = tx.Exec(ctx, "select gnomon.sink_report($1, 0)", s.name)
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	if newState != nil {
		b, _ := json.Marshal(newState)
		_ = json.Unmarshal(b, &s.state)
	}
	return len(ch), nil
}

func fail(ctx context.Context, c *pgx.Conn, s sinkRow, cause error, log func(string)) {
	log(fmt.Sprintf("sink %s: %v", s.name, cause))
	if s.failures+1 < MaxFailures {
		_, _ = c.Exec(ctx, "select gnomon.sink_report($1, 0, $2)", s.name, cause.Error())
		return
	}
	// the batch that keeps failing: kept for inspection, the sink paused (its position unmoved)
	tx, err := c.Begin(ctx)
	if err != nil {
		return
	}
	defer tx.Rollback(ctx)
	res, err := gn.Query(ctx, tx.Conn(), "select coalesce(jsonb_agg(to_jsonb(b)), '[]') from gnomon.sink_batch($1, 500) b", s.name)
	if err != nil {
		return
	}
	b, _ := json.Marshal(res.Rows[0][0])
	tx.Rollback(ctx)
	_, _ = c.Exec(ctx, "select gnomon.sink_report($1, 0, $2, $3::jsonb, true)", s.name, cause.Error(), string(b))
	log(fmt.Sprintf("sink %s paused after %d failures; the batch is in gnomon.sink_dead", s.name, s.failures+1))
}

// format turns changes into messages.
func format(s sinkRow, ch []change) []map[string]any {
	host, _ := os.Hostname()
	withTx, _ := s.config["transactions"].(bool)
	var out []map[string]any
	lastXid := ""
	for i, c := range ch {
		if withTx && c.Xid != lastXid {
			if lastXid != "" {
				out = append(out, map[string]any{"type": "end", "xid": lastXid})
			}
			out = append(out, map[string]any{"type": "begin", "xid": c.Xid})
			lastXid = c.Xid
		}
		switch s.format {
		case "debezium":
			op := map[string]string{"insert": "c", "update": "u", "delete": "d", "truncate": "t"}[c.Op]
			out = append(out, map[string]any{"before": c.Old, "after": c.New, "op": op, "ts_ms": tsMillis(c.TS),
				"source": map[string]any{"connector": "gnomon", "table": c.Tbl, "xid": c.Xid, "lsn": c.Vlsn, "vkey": c.Vkey, "id": c.ID}})
		case "cloudevents":
			out = append(out, map[string]any{"specversion": "1.0", "id": c.ID, "source": "gnomon://" + host + "/" + c.Tbl,
				"type": "gnomon.row." + c.Op, "time": c.TS, "datacontenttype": "application/json", "subject": keyText(c.Key), "data": c})
		default:
			out = append(out, map[string]any{"type": "change", "id": c.ID, "table": c.Tbl, "key": c.Key, "op": c.Op, "xid": c.Xid,
				"vkey": c.Vkey, "lsn": c.Vlsn, "role": c.Role, "new": c.New, "old": c.Old, "ts": c.TS})
		}
		if withTx && i == len(ch)-1 {
			out = append(out, map[string]any{"type": "end", "xid": c.Xid})
		}
	}
	return out
}

func keyText(k map[string]any) string {
	b, _ := json.Marshal(k)
	return string(b)
}

func tsMillis(v any) int64 {
	if t, err := time.Parse(time.RFC3339Nano, fmt.Sprint(v)); err == nil {
		return t.UnixMilli()
	}
	return 0
}

func send(ctx context.Context, s sinkRow, ch []change) error {
	msgs := format(s, ch)
	switch s.kind {
	case "webhook":
		b, _ := json.Marshal(msgs)
		return gn.PostJSON(ctx, fmt.Sprint(s.config["url"]), b, fmt.Sprint(s.config["secret"]), ch[0].ID+".."+ch[len(ch)-1].ID)
	case "file":
		p := fmt.Sprint(s.config["path"])
		f, err := os.OpenFile(p, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o640)
		if err != nil {
			return err
		}
		w := bufio.NewWriter(f)
		enc := json.NewEncoder(w)
		for _, m := range msgs {
			if err := enc.Encode(m); err != nil {
				f.Close()
				return err
			}
		}
		if err := w.Flush(); err != nil {
			f.Close()
			return err
		}
		if err := f.Sync(); err != nil {
			f.Close()
			return err
		}
		return f.Close()
	case "nats":
		return natsPublish(ctx, fmt.Sprint(s.config["url"]), fmt.Sprint(s.config["subject"]), msgs)
	case "parquet":
		return parquetPublish(ctx, s, ch)
	}
	return fmt.Errorf("sink kind %s is not supported", s.kind)
}

// natsPublish speaks the NATS client protocol (INFO, CONNECT, HPUB with a Nats-Msg-Id header,
// PING/PONG to know the server has every message) with no client library.
func natsPublish(ctx context.Context, rawURL, subject string, msgs []map[string]any) error {
	if subject == "" || subject == "<nil>" {
		subject = "gnomon.changes"
	}
	u, err := url.Parse(rawURL)
	if err != nil || u.Host == "" {
		return fmt.Errorf("bad NATS url %q", rawURL)
	}
	host := u.Host
	if !strings.Contains(host, ":") {
		host += ":4222"
	}
	d := net.Dialer{Timeout: 5 * time.Second}
	conn, err := d.DialContext(ctx, "tcp", host)
	if err != nil {
		return err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
	rd := bufio.NewReader(conn)
	line, err := rd.ReadString('\n')
	if err != nil || !strings.HasPrefix(line, "INFO ") {
		return fmt.Errorf("NATS server did not send INFO: %q %v", line, err)
	}
	connect := map[string]any{"verbose": false, "pedantic": false, "headers": true, "name": "gnomon-sink", "lang": "go", "version": "0"}
	if u.User != nil {
		connect["user"] = u.User.Username()
		if p, ok := u.User.Password(); ok {
			connect["pass"] = p
		}
	}
	cb, _ := json.Marshal(connect)
	w := bufio.NewWriter(conn)
	fmt.Fprintf(w, "CONNECT %s\r\n", cb)
	for _, m := range msgs {
		body, _ := json.Marshal(m)
		id := fmt.Sprint(m["id"])
		if id == "<nil>" {
			id = fmt.Sprintf("%v:%v", m["type"], m["xid"])
		}
		hdr := "NATS/1.0\r\nNats-Msg-Id: " + id + "\r\n\r\n"
		fmt.Fprintf(w, "HPUB %s %d %d\r\n%s%s\r\n", subject, len(hdr), len(hdr)+len(body), hdr, body)
	}
	fmt.Fprint(w, "PING\r\n")
	if err := w.Flush(); err != nil {
		return err
	}
	for {
		line, err := rd.ReadString('\n')
		if err != nil {
			return err
		}
		switch {
		case strings.HasPrefix(line, "PONG"):
			return nil
		case strings.HasPrefix(line, "-ERR"):
			return errors.New("NATS: " + strings.TrimSpace(line))
		case strings.HasPrefix(line, "PING"):
			fmt.Fprint(conn, "PONG\r\n")
		}
	}
}
