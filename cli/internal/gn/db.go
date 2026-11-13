// Package gn holds the gnomon CLI's database access and command implementations.
package gn

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/netip"
	"os"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
)

// Options shared by every command.
type Options struct {
	DSN    string
	Branch string
	JSON   bool
	Out    io.Writer
}

// DefaultDSN is GNOMON_DSN, or empty (the libpq environment: PGHOST, ...).
func DefaultDSN() string { return os.Getenv("GNOMON_DSN") }

// Connect opens a connection. An empty DSN uses GNOMON_DSN, then the libpq environment (PGHOST, ...).
func Connect(ctx context.Context, dsn string) (*pgx.Conn, error) {
	if dsn == "" {
		dsn = os.Getenv("GNOMON_DSN")
	}
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("bad connection string: %w", err)
	}
	if cfg.RuntimeParams == nil {
		cfg.RuntimeParams = map[string]string{}
	}
	cfg.RuntimeParams["application_name"] = "gnomon-cli"
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	return conn, nil
}

// UseBranch points the session at a branch (and optionally a past coordinate) for this connection.
func UseBranch(ctx context.Context, c *pgx.Conn, branch, asOf string) error {
	if branch == "" && asOf == "" {
		return nil
	}
	if branch == "" {
		branch = "main"
	}
	var path string
	var as any
	if asOf != "" {
		as = asOf
	}
	return c.QueryRow(ctx, "select gnomon.use($1, $2)", branch, as).Scan(&path)
}

// Result is a generic query result.
type Result struct {
	Columns []string         `json:"columns"`
	Rows    [][]any          `json:"rows"`
	Tag     string           `json:"tag,omitempty"`
	Maps    []map[string]any `json:"-"`
	void    bool             // every column is a function's void result: nothing to show
}

// voidOID is the type of a function that returns nothing.
const voidOID = 2278

// Query runs SQL and collects the rows.
func Query(ctx context.Context, c *pgx.Conn, sql string, args ...any) (*Result, error) {
	rows, err := c.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	res := &Result{}
	var oids []uint32
	fds := rows.FieldDescriptions()
	for _, f := range fds {
		res.Columns = append(res.Columns, f.Name)
		oids = append(oids, f.DataTypeOID)
	}
	res.void = len(oids) > 0
	for _, o := range oids {
		res.void = res.void && o == voidOID
	}
	for rows.Next() {
		vals, err := rows.Values()
		if err != nil {
			return nil, err
		}
		raw := rows.RawValues()
		for i, v := range vals {
			// json and jsonb are decoded again from their text, keeping numbers exact
			if (oids[i] == pgtype.JSONOID || oids[i] == pgtype.JSONBOID) && i < len(raw) && raw[i] != nil {
				if x, ok := exactJSON(raw[i], oids[i] == pgtype.JSONBOID && fds[i].Format == pgtype.BinaryFormatCode); ok {
					vals[i] = x
					continue
				}
			}
			vals[i] = normalize(v, oids[i])
		}
		res.Rows = append(res.Rows, vals)
		m := map[string]any{}
		for i, col := range res.Columns {
			m[col] = vals[i]
		}
		res.Maps = append(res.Maps, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	res.Tag = rows.CommandTag().String()
	return res, nil
}

// normalize turns a driver value into what the table and JSON output show: the text PostgreSQL
// would print for types the driver decodes into Go structs (uuid, interval, time, date, inet).
func normalize(v any, oid uint32) any {
	switch x := v.(type) {
	case []byte:
		return fmt.Sprintf("\\x%x", x)
	case [16]uint8:
		return fmt.Sprintf("%x-%x-%x-%x-%x", x[0:4], x[4:6], x[6:8], x[8:10], x[10:16])
	case time.Time:
		if oid == pgtype.DateOID {
			return x.Format("2006-01-02")
		}
		return x.Format(time.RFC3339Nano)
	case pgtype.Numeric:
		switch {
		case !x.Valid:
			return nil
		case x.NaN:
			return "NaN"
		case x.InfinityModifier == pgtype.Infinity:
			return "Infinity"
		case x.InfinityModifier == pgtype.NegativeInfinity:
			return "-Infinity"
		}
		b, err := x.MarshalJSON()
		if err != nil {
			return fmt.Sprint(x)
		}
		return number(string(b))
	case pgtype.Interval:
		if !x.Valid {
			return nil
		}
		return intervalText(x)
	case pgtype.Time:
		if !x.Valid {
			return nil
		}
		return clockText(x.Microseconds)
	case netip.Prefix:
		if oid == pgtype.InetOID && x.Bits() == x.Addr().BitLen() {
			return x.Addr().String()
		}
		return x.String()
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = normalize(e, 0)
		}
		return out
	case fmt.Stringer:
		return x.String()
	case map[string]any, string, bool, nil, int16, int32, int64, float32, float64, int:
		return x
	default:
		b, err := json.Marshal(x)
		if err != nil {
			return fmt.Sprint(x)
		}
		var out any
		if json.Unmarshal(b, &out) == nil {
			return out
		}
		return string(b)
	}
}

// number keeps a JSON or numeric value exact: a float64 when that prints the same digits (1.50
// shows as 1.5, as it always has), otherwise its digits (a bigint key, a long numeric), which
// float64 would round.
func number(s string) any {
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return json.Number(s)
	}
	t := s
	if strings.Contains(t, ".") && !strings.ContainsAny(t, "eE") {
		t = strings.TrimRight(strings.TrimRight(t, "0"), ".")
	}
	if strconv.FormatFloat(f, 'f', -1, 64) == t {
		return f
	}
	return json.Number(s)
}

// exactJSON decodes json or jsonb (binary jsonb carries a version byte) with exact numbers.
func exactJSON(b []byte, jsonbBinary bool) (any, bool) {
	if jsonbBinary {
		if len(b) == 0 || b[0] != 1 {
			return nil, false
		}
		b = b[1:]
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	var v any
	if d.Decode(&v) != nil {
		return nil, false
	}
	return exactNumbers(v), true
}

func exactNumbers(v any) any {
	switch x := v.(type) {
	case json.Number:
		return number(string(x))
	case map[string]any:
		for k, e := range x {
			x[k] = exactNumbers(e)
		}
	case []any:
		for i, e := range x {
			x[i] = exactNumbers(e)
		}
	}
	return v
}

// intervalText prints an interval as PostgreSQL does: "1 year 2 mons 3 days 04:05:06.5".
func intervalText(iv pgtype.Interval) string {
	var parts []string
	unit := func(n int64, one, many string) {
		if n == 1 {
			parts = append(parts, "1 "+one)
		} else if n != 0 {
			parts = append(parts, fmt.Sprintf("%d %s", n, many))
		}
	}
	unit(int64(iv.Months/12), "year", "years")
	unit(int64(iv.Months%12), "mon", "mons")
	unit(int64(iv.Days), "day", "days")
	if iv.Microseconds != 0 || len(parts) == 0 {
		parts = append(parts, clockText(iv.Microseconds))
	}
	return strings.Join(parts, " ")
}

// clockText prints microseconds as hh:mm:ss[.ffffff].
func clockText(us int64) string {
	sign := ""
	if us < 0 {
		sign, us = "-", -us
	}
	const sec, min, hour = int64(1000000), int64(60000000), int64(3600000000)
	out := fmt.Sprintf("%s%02d:%02d:%02d", sign, us/hour, us/min%60, us/sec%60)
	if f := us % sec; f != 0 {
		out += strings.TrimRight(fmt.Sprintf(".%06d", f), "0")
	}
	return out
}

// Print writes a result as an aligned table, or JSON.
func Print(w io.Writer, res *Result, asJSON bool) error {
	if asJSON {
		out := make([]map[string]any, 0, len(res.Maps))
		out = append(out, res.Maps...)
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		return enc.Encode(out)
	}
	if res.void {
		return nil
	}
	if len(res.Columns) == 0 {
		if res.Tag != "" {
			fmt.Fprintln(w, res.Tag)
		}
		return nil
	}
	tw := tabwriter.NewWriter(w, 0, 2, 2, ' ', 0)
	fmt.Fprintln(tw, strings.Join(res.Columns, "\t"))
	seps := make([]string, len(res.Columns))
	for i, c := range res.Columns {
		seps[i] = strings.Repeat("-", max(3, len(c)))
	}
	fmt.Fprintln(tw, strings.Join(seps, "\t"))
	for _, r := range res.Rows {
		cells := make([]string, len(r))
		for i, v := range r {
			cells[i] = Cell(v)
		}
		fmt.Fprintln(tw, strings.Join(cells, "\t"))
	}
	if err := tw.Flush(); err != nil {
		return err
	}
	fmt.Fprintf(w, "(%d row%s)\n", len(res.Rows), plural(len(res.Rows)))
	return nil
}

// Cell renders one value for table output.
func Cell(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return strings.ReplaceAll(x, "\n", `\n`)
	case map[string]any, []any:
		b, _ := json.Marshal(sortKeys(x))
		return string(b)
	default:
		return fmt.Sprint(x)
	}
}

func sortKeys(v any) any {
	m, ok := v.(map[string]any)
	if !ok {
		return v
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := make(map[string]any, len(m))
	for _, k := range keys {
		out[k] = sortKeys(m[k])
	}
	return out
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}

// PgError extracts a readable message from a PostgreSQL error.
func PgError(err error) string {
	if pe, ok := err.(*pgconn.PgError); ok {
		msg := fmt.Sprintf("%s (SQLSTATE %s)", pe.Message, pe.Code)
		if pe.Detail != "" {
			msg += "\n  detail: " + pe.Detail
		}
		if pe.Hint != "" {
			msg += "\n  hint: " + pe.Hint
		}
		return msg
	}
	return err.Error()
}

// SQLState returns the SQLSTATE of an error, or "".
func SQLState(err error) string {
	if pe, ok := err.(*pgconn.PgError); ok {
		return pe.Code
	}
	return ""
}
