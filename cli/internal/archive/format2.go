package archive

// Archive format 2: native Parquet types where the mapping is lossless
// (integers, floats, booleans, timestamps, text, bytea) and text otherwise, with the
// gnomon.columns metadata kept; rows sorted by row key, then version key; row groups of 65,536
// rows with statistics and a Bloom filter on the row key, so an engine reading the file in place
// finds a key without a scan. Format 1 files (every column as text) stay readable.

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/parquet-go/parquet-go"
)

// RowGroupRows is the number of rows per row group in format 2.
var RowGroupRows = 65536

func nativeKind(typ string) string {
	switch typ {
	case "smallint", "integer":
		return "i32"
	case "bigint":
		return "i64"
	case "real":
		return "f32"
	case "double precision":
		return "f64"
	case "boolean":
		return "bool"
	case "timestamp with time zone":
		return "tstz"
	case "timestamp without time zone":
		return "ts"
	case "bytea":
		return "bytea"
	}
	return "text"
}

func nodeFor(kind string) parquet.Node {
	switch kind {
	case "i32":
		return parquet.Int(32)
	case "i64":
		return parquet.Int(64)
	case "f32":
		return parquet.Leaf(parquet.FloatType)
	case "f64":
		return parquet.Leaf(parquet.DoubleType)
	case "bool":
		return parquet.Leaf(parquet.BooleanType)
	case "tstz":
		return parquet.TimestampAdjusted(parquet.Microsecond, true)
	case "ts":
		return parquet.TimestampAdjusted(parquet.Microsecond, false)
	case "bytea":
		return parquet.Leaf(parquet.ByteArrayType)
	}
	return parquet.String()
}

func selectFor(col column, kind string) string {
	q := pgx.Identifier{col.Name}.Sanitize()
	switch kind {
	case "i32", "i64":
		return q + "::int8"
	case "f32":
		return q + "::float4"
	case "f64":
		return q + "::float8"
	case "bool", "bytea":
		return q
	case "tstz", "ts":
		return fmt.Sprintf("case when %[1]s = 'infinity' then 9223372036854775807 when %[1]s = '-infinity' then -9223372036854775807 - 1 else (extract(epoch from %[1]s) * 1000000)::int8 end", q)
	}
	return q + "::text"
}

func holderFor(kind string) any {
	switch kind {
	case "i32", "i64", "tstz", "ts":
		return new(*int64)
	case "f32":
		return new(*float32)
	case "f64":
		return new(*float64)
	case "bool":
		return new(*bool)
	case "bytea":
		return new(*[]byte)
	}
	return new(*string)
}

// valueOf turns a scanned value into a Parquet value (and its text form, for encryption).
func valueOf(kind string, h any) (parquet.Value, bool) {
	switch kind {
	case "i32":
		if v := *h.(**int64); v != nil {
			return parquet.Int32Value(int32(*v)), true
		}
	case "i64", "tstz", "ts":
		if v := *h.(**int64); v != nil {
			return parquet.Int64Value(*v), true
		}
	case "f32":
		if v := *h.(**float32); v != nil {
			return parquet.FloatValue(*v), true
		}
	case "f64":
		if v := *h.(**float64); v != nil {
			return parquet.DoubleValue(*v), true
		}
	case "bool":
		if v := *h.(**bool); v != nil {
			return parquet.BooleanValue(*v), true
		}
	case "bytea":
		if v := *h.(**[]byte); v != nil {
			return parquet.ByteArrayValue(*v), true
		}
	default:
		if v := *h.(**string); v != nil {
			return parquet.ByteArrayValue([]byte(*v)), true
		}
	}
	return parquet.Value{}, false
}

func writeParquet(ctx context.Context, c *pgx.Conn, rel string, meta map[string]string, w io.Writer, cr *Crypto) (int64, error) {
	cols, err := columns(ctx, c, rel)
	if err != nil {
		return 0, err
	}
	nUser := len(cols)
	var keyIdx []int
	for i, col := range cols {
		if col.Name == "gn_rid" || !strings.HasPrefix(col.Name, "gn_") {
			keyIdx = append(keyIdx, i)
		}
	}
	kinds := make([]string, 0, nUser+1)
	for _, col := range cols {
		k := nativeKind(col.Type)
		if cr != nil && cr.encrypted(col.Name) {
			k = "text" // an encrypted value is text
		}
		kinds = append(kinds, k)
	}
	subjectAt := -1
	if cr != nil {
		for i, col := range cols {
			if col.Name == cr.SubjectStorage {
				subjectAt = i
			}
		}
		if subjectAt < 0 {
			return 0, fmt.Errorf("archive: the subject column %s is not in %s's versions", cr.Subject, rel)
		}
		if err := cr.prefetch(ctx, c, rel); err != nil {
			return 0, err
		}
		cols = append(cols, column{Name: "gn_subject", Type: "text"})
		kinds = append(kinds, "text")
	}
	g := parquet.Group{}
	for i, col := range cols {
		g[col.Name] = parquet.Optional(nodeFor(kinds[i]))
	}
	sch := parquet.NewSchema("gnomon_versions", g)
	idx := leafIndex(sch)
	ctype, _ := json.Marshal(cols)
	m2 := map[string]string{"gnomon.columns": string(ctype), "gnomon.format": "2"}
	for k, v := range meta {
		m2[k] = v
	}
	keys := make([]string, 0, len(m2))
	for k := range m2 {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	opts := []parquet.WriterOption{sch}
	for _, k := range keys {
		opts = append(opts, parquet.KeyValueMetadata(k, m2[k]))
	}
	var blooms []parquet.BloomFilterColumn
	var order []string
	for _, i := range keyIdx {
		blooms = append(blooms, parquet.SplitBlockFilter(10, cols[i].Name))
		order = append(order, pgx.Identifier{cols[i].Name}.Sanitize())
	}
	if len(blooms) > 0 {
		opts = append(opts, parquet.BloomFilters(blooms...))
	}
	pw := parquet.NewGenericWriter[any](w, opts...)
	sel := make([]string, nUser)
	for i := 0; i < nUser; i++ {
		sel[i] = selectFor(cols[i], kinds[i])
	}
	order = append(order, "gn_key", "gn_lsn")
	rows, err := c.Query(ctx, fmt.Sprintf("select %s from %s order by %s", strings.Join(sel, ", "), rel, strings.Join(order, ", ")))
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	var n int64
	inGroup := 0
	batch := make([]parquet.Row, 0, 1024)
	flush := func(endGroup bool) error {
		if len(batch) > 0 {
			if _, err := pw.WriteRows(batch); err != nil {
				return err
			}
			batch = batch[:0]
		}
		if endGroup {
			inGroup = 0
			return pw.Flush()
		}
		return nil
	}
	lastKey, lastSubject := "", ""
	for rows.Next() {
		hs := make([]any, nUser)
		for i := range hs {
			hs[i] = holderFor(kinds[i])
		}
		if err := rows.Scan(hs...); err != nil {
			return n, err
		}
		row := make(parquet.Row, len(cols))
		var subj string
		var key []byte
		if cr != nil {
			var kb strings.Builder
			for _, i := range keyIdx {
				if v, ok := valueOf(kinds[i], hs[i]); ok {
					kb.WriteString(textOf(v, cols[i].Type, true))
				}
				kb.WriteByte(0)
			}
			if kb.String() != lastKey {
				lastKey, lastSubject = kb.String(), ""
			}
			if pv, ok := valueOf(kinds[subjectAt], hs[subjectAt]); ok {
				lastSubject = textOf(pv, cols[subjectAt].Type, true)
			}
			subj = lastSubject
			key = cr.keys[subj]
		}
		for i := 0; i < nUser; i++ {
			leaf := idx[cols[i].Name]
			if cr != nil && cr.encrypted(cols[i].Name) {
				v := *hs[i].(**string)
				if v == nil || key == nil { // nothing, or a subject already erased
					row[leaf] = parquet.Value{}.Level(0, 0, leaf)
					continue
				}
				enc, err := seal(key, []byte(*v), aad(cr.Table, cols[i].Name, subj))
				if err != nil {
					return n, err
				}
				row[leaf] = parquet.ByteArrayValue([]byte(enc)).Level(0, 1, leaf)
				continue
			}
			if v, ok := valueOf(kinds[i], hs[i]); ok {
				row[leaf] = v.Level(0, 1, leaf)
			} else {
				row[leaf] = parquet.Value{}.Level(0, 0, leaf)
			}
		}
		if cr != nil {
			leaf := idx["gn_subject"]
			row[leaf] = parquet.ByteArrayValue([]byte(subj)).Level(0, 1, leaf)
		}
		batch = append(batch, row)
		n++
		inGroup++
		if len(batch) == cap(batch) || inGroup >= RowGroupRows {
			if err := flush(inGroup >= RowGroupRows); err != nil {
				return n, err
			}
		}
	}
	if err := rows.Err(); err != nil {
		return n, err
	}
	if err := flush(false); err != nil {
		return n, err
	}
	return n, pw.Close()
}

// textOf is a Parquet value's text form, as PostgreSQL reads it back for the column's type.
func textOf(v parquet.Value, typ string, format2 bool) string {
	switch v.Kind() {
	case parquet.Boolean:
		return strconv.FormatBool(v.Boolean())
	case parquet.Int32:
		return strconv.FormatInt(int64(v.Int32()), 10)
	case parquet.Int64:
		if format2 && (typ == "timestamp with time zone" || typ == "timestamp without time zone") {
			return formatMicros(v.Int64(), typ == "timestamp with time zone")
		}
		return strconv.FormatInt(v.Int64(), 10)
	case parquet.Float:
		return formatFloat(float64(v.Float()), 32)
	case parquet.Double:
		return formatFloat(v.Double(), 64)
	}
	if format2 && typ == "bytea" {
		return `\x` + hex.EncodeToString(v.ByteArray())
	}
	return string(v.ByteArray())
}

func formatFloat(f float64, bits int) string {
	switch {
	case math.IsNaN(f):
		return "NaN"
	case math.IsInf(f, 1):
		return "Infinity"
	case math.IsInf(f, -1):
		return "-Infinity"
	}
	return strconv.FormatFloat(f, 'g', -1, bits)
}

func formatMicros(us int64, tz bool) string {
	switch us {
	case math.MaxInt64:
		return "infinity"
	case math.MinInt64:
		return "-infinity"
	}
	t := time.UnixMicro(us).UTC()
	y := t.Year()
	bc := y <= 0
	if bc {
		y = 1 - y
	}
	s := fmt.Sprintf("%04d", y) + t.Format("-01-02 15:04:05.999999")
	if tz {
		s += "+00"
	}
	if bc {
		s += " BC"
	}
	return s
}
