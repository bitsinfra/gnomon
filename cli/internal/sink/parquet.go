package sink

// The Parquet sink: each batch becomes one Parquet file in a directory or object
// store (the archiver's stores: paths, file://, s3://, gs://). A file's name is derived from the
// first and last change of its batch, so a batch delivered again after a failure overwrites its
// own file instead of adding a second one.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/bitsinfra/gnomon/cli/internal/archive"
	"github.com/parquet-go/parquet-go"
)

var parquetColumns = []string{"id", "table", "op", "key", "new", "old", "xid", "vkey", "lsn", "ts", "role"}

func parquetSchema() *parquet.Schema {
	g := parquet.Group{}
	for _, c := range parquetColumns {
		g[c] = parquet.Optional(parquet.String())
	}
	return parquet.NewSchema("gnomon_changes", g)
}

// ParquetFileName is the file a batch is written to.
func ParquetFileName(sink string, ch []change) string {
	h := sha256.Sum256([]byte(ch[0].ID + "\x00" + ch[len(ch)-1].ID))
	return fmt.Sprintf("%s-%d-%s.parquet", strings.ReplaceAll(sink, "/", "_"), ch[0].Vkey, hex.EncodeToString(h[:8]))
}

func parquetPublish(ctx context.Context, s sinkRow, ch []change) error {
	to := fmt.Sprint(s.config["to"])
	st, err := archive.OpenStore(to)
	if err != nil {
		return err
	}
	w, _, err := st.Create(ParquetFileName(s.name, ch))
	if err != nil {
		return err
	}
	sch := parquetSchema()
	idx := map[string]int{}
	for i, path := range sch.Columns() {
		idx[path[0]] = i
	}
	pw := parquet.NewWriter(w, sch, parquet.KeyValueMetadata("gnomon.sink", s.name), parquet.KeyValueMetadata("gnomon.format", "changes-1"))
	js := func(v any) parquet.Value {
		if v == nil {
			return parquet.NullValue()
		}
		b, _ := json.Marshal(v)
		return parquet.ByteArrayValue(b)
	}
	str := func(v string) parquet.Value { return parquet.ByteArrayValue([]byte(v)) }
	for _, c := range ch {
		row := make(parquet.Row, len(parquetColumns))
		vals := map[string]parquet.Value{
			"id": str(c.ID), "table": str(c.Tbl), "op": str(c.Op), "key": js(c.Key), "new": js(c.New), "old": js(c.Old),
			"xid": str(c.Xid), "vkey": str(fmt.Sprint(c.Vkey)), "lsn": str(c.Vlsn), "ts": js(c.TS), "role": js(c.Role),
		}
		for name, v := range vals {
			i := idx[name]
			if v.IsNull() {
				row[i] = parquet.NullValue().Level(0, 0, i)
			} else {
				row[i] = v.Level(0, 1, i)
			}
		}
		if _, err := pw.WriteRows([]parquet.Row{row}); err != nil {
			w.Close()
			return err
		}
	}
	if err := pw.Close(); err != nil {
		w.Close()
		return err
	}
	return w.Close()
}
