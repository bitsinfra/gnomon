// Package archive moves version partitions to Parquet in object storage and back.
// Each archived file holds one write-time partition of _gnomon.<base>__v.
// Every column is stored as an optional UTF-8 string holding PostgreSQL's text form of the
// value, with the column types in the file's key/value metadata, so files are readable by
// DuckDB or any Parquet reader and load back exactly.
package archive

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/parquet-go/parquet-go"
)

// Store is where archive files live: local paths and file:// URIs, s3:// (and S3-compatible
// servers), gs:// (Google Cloud Storage's XML API). See s3.go.
type Store interface {
	// Create writes a new archive file; the URI is what the manifest records.
	Create(name string) (io.WriteCloser, string, error)
	// Fetch makes an archive file readable locally; call done when finished with it.
	Fetch(uri string) (local string, done func(), err error)
	// Put replaces an archive file with a local one.
	Put(uri, local string) error
}

type dirStore struct{ dir string }

func (d dirStore) Create(name string) (io.WriteCloser, string, error) {
	if err := os.MkdirAll(d.dir, 0o755); err != nil {
		return nil, "", err
	}
	p := filepath.Join(d.dir, name)
	f, err := os.Create(p)
	if err != nil {
		return nil, "", err
	}
	abs, _ := filepath.Abs(p)
	return f, "file://" + abs, nil
}

func (d dirStore) Fetch(uri string) (string, func(), error) { return LocalPath(uri), func() {}, nil }

func (d dirStore) Put(uri, local string) error {
	if LocalPath(uri) == local {
		return nil
	}
	b, err := os.ReadFile(local)
	if err != nil {
		return err
	}
	return os.WriteFile(LocalPath(uri), b, 0o644)
}

// LocalPath turns a file:// URI into a path.
func LocalPath(uri string) string {
	if strings.HasPrefix(uri, "file://") {
		if u, err := url.Parse(uri); err == nil {
			return u.Path
		}
	}
	return uri
}

// OpenStore resolves a destination (or an archived file's) URI.
func OpenStore(uri string) (Store, error) {
	switch {
	case strings.HasPrefix(uri, "s3://"), strings.HasPrefix(uri, "gs://"):
		cfg, err := s3ConfigFromEnv(uri[:2])
		if err != nil {
			return nil, err
		}
		return newS3Store(uri, cfg)
	case strings.HasPrefix(uri, "az://"):
		return nil, fmt.Errorf("%s: Azure Blob Storage is reached through a mounted path (blobfuse2) in this build", uri)
	default:
		return dirStore{dir: LocalPath(uri)}, nil
	}
}

// fetch makes an archive URI readable locally, whatever store it is in.
func fetch(uri string) (string, func(), error) {
	st, err := OpenStore(uri)
	if err != nil {
		return "", nil, err
	}
	return st.Fetch(uri)
}

// Partition is one archivable version partition.
type Partition struct {
	Table string // the tracked table (regclass text)
	Rel   string // the partition (qualified)
	Part  int
	Rows  int64
}

// Candidates lists partitions of a tracked table whose versions are all older than before.
func Candidates(ctx context.Context, c *pgx.Conn, table, before string) ([]Partition, error) {
	rows, err := c.Query(ctx, `
	  with t as (select * from gnomon.tracked where rel = _gnomon.base_rel($1::regclass)),
	       cut as (select gnomon._kxmin(k.coord) as k from gnomon.tick k where k.at <= $2::timestamptz order by k.id desc limit 1)
	  select (select rel::text from t), ch.oid::regclass::text,
	         (regexp_match(pg_get_expr(ch.relpartbound, ch.oid), 'FROM \((-?\d+)\)'))[1]::int as part,
	         (select k from cut)
	    from t join pg_inherits i on i.inhparent = ('_gnomon.' || quote_ident(t.base || '__v'))::regclass
	    join pg_class ch on ch.oid = i.inhrelid
	   where pg_get_expr(ch.relpartbound, ch.oid) <> 'DEFAULT'
	   order by 3`, table, before)
	if err != nil {
		return nil, err
	}
	type cand struct {
		table, rel string
		part       int
		cut        *int64
	}
	var cands []cand
	for rows.Next() {
		var x cand
		if err := rows.Scan(&x.table, &x.rel, &x.part, &x.cut); err != nil {
			return nil, err
		}
		cands = append(cands, x)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	var out []Partition
	for _, x := range cands {
		if x.cut == nil {
			return nil, fmt.Errorf("no tick at or before %s", before)
		}
		var n int64
		var maxKey *int64
		if err := c.QueryRow(ctx, fmt.Sprintf("select count(*), max(gn_key) from %s", x.rel)).Scan(&n, &maxKey); err != nil {
			return nil, err
		}
		if n == 0 || maxKey == nil || *maxKey >= *x.cut {
			continue
		}
		out = append(out, Partition{Table: x.table, Rel: x.rel, Part: x.part, Rows: n})
	}
	return out, nil
}

type column struct{ Name, Type string }

func columns(ctx context.Context, c *pgx.Conn, rel string) ([]column, error) {
	rows, err := c.Query(ctx, `select attname, format_type(atttypid, atttypmod) from pg_attribute
	  where attrelid = $1::regclass and attnum > 0 and not attisdropped order by attnum`, rel)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []column
	for rows.Next() {
		var col column
		if err := rows.Scan(&col.Name, &col.Type); err != nil {
			return nil, err
		}
		out = append(out, col)
	}
	return out, rows.Err()
}

func schemaFor(cols []column) *parquet.Schema {
	g := parquet.Group{}
	for _, col := range cols {
		g[col.Name] = parquet.Optional(parquet.String())
	}
	return parquet.NewSchema("gnomon_versions", g)
}

// leafIndex maps column names to their leaf position (Group fields are ordered by name).
func leafIndex(s *parquet.Schema) map[string]int {
	m := map[string]int{}
	for i, path := range s.Columns() {
		m[path[0]] = i
	}
	return m
}

// WriteParquet streams the rows of rel to w. Returns the row count.
func WriteParquet(ctx context.Context, c *pgx.Conn, rel string, meta map[string]string, w io.Writer) (int64, error) {
	return writeParquet(ctx, c, rel, meta, w, nil)
}

// File is a decoded archive file.
type File struct {
	Columns []column
	Meta    map[string]string
	Rows    []map[string]*string
}

// ReadParquet decodes an archive file.
func ReadParquet(path string) (*File, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	pf, err := parquet.OpenFile(f, st.Size())
	if err != nil {
		return nil, err
	}
	out := &File{Meta: map[string]string{}}
	for _, kv := range pf.Metadata().KeyValueMetadata {
		out.Meta[kv.Key] = kv.Value
	}
	if err := json.Unmarshal([]byte(out.Meta["gnomon.columns"]), &out.Columns); err != nil {
		return nil, fmt.Errorf("%s is not a gnomon archive: %w", path, err)
	}
	names := map[int]string{}
	for i, p := range pf.Schema().Columns() {
		names[i] = p[0]
	}
	types := map[string]string{}
	for _, col := range out.Columns {
		types[col.Name] = col.Type
	}
	format2 := out.Meta["gnomon.format"] == "2"
	r := parquet.NewReader(pf)
	defer r.Close()
	buf := make([]parquet.Row, 256)
	for {
		n, err := r.ReadRows(buf)
		for _, row := range buf[:n] {
			m := map[string]*string{}
			for _, v := range row {
				name := names[v.Column()]
				if v.IsNull() {
					m[name] = nil
				} else {
					s := textOf(v, types[name], format2)
					m[name] = &s
				}
			}
			out.Rows = append(out.Rows, m)
		}
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
	}
	return out, nil
}

// WriteFile writes a decoded archive back (used by erase-archives).
func WriteFile(path string, af *File) error {
	// rewritten files are format 1: every column as text
	meta := map[string]string{}
	for k, v := range af.Meta {
		meta[k] = v
	}
	meta["gnomon.format"] = "1"
	af = &File{Columns: af.Columns, Meta: meta, Rows: af.Rows}
	sch := schemaFor(af.Columns)
	idx := leafIndex(sch)
	tmp := path + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	var opts []parquet.WriterOption
	opts = append(opts, sch)
	keys := make([]string, 0, len(af.Meta))
	for k := range af.Meta {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		opts = append(opts, parquet.KeyValueMetadata(k, af.Meta[k]))
	}
	pw := parquet.NewGenericWriter[any](f, opts...)
	for _, m := range af.Rows {
		row := make(parquet.Row, len(af.Columns))
		for _, col := range af.Columns {
			leaf := idx[col.Name]
			if v := m[col.Name]; v == nil {
				row[leaf] = parquet.Value{}.Level(0, 0, leaf)
			} else {
				row[leaf] = parquet.ByteArrayValue([]byte(*v)).Level(0, 1, leaf)
			}
		}
		if _, err := pw.WriteRows([]parquet.Row{row}); err != nil {
			f.Close()
			return err
		}
	}
	if err := pw.Close(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Checksum is the sha256 of a file, hex.
func Checksum(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// Options for ArchiveOpts.
type Options struct {
	// Keep is a retention policy (JSON, as gnomon.set_retention takes): the whole partition is
	// written to the store and stays local, thinned by retention to the coordinates the policy
	// keeps. Reads there stay exact with no thaw; the file answers the rest.
	Keep string
	// Engine reads each archived partition in place as a foreign partition,
	// one of gnomon.archive_engine; an engine that reads CSV gets a copy beside the Parquet file.
	Engine string
}

// Archive writes each candidate partition to Parquet and calls gnomon.archive_partition.
func Archive(ctx context.Context, c *pgx.Conn, table, before, dest string, log func(string)) ([]Partition, error) {
	return ArchiveOpts(ctx, c, table, before, dest, Options{}, log)
}

// ArchiveOpts is Archive with options.
func ArchiveOpts(ctx context.Context, c *pgx.Conn, table, before, dest string, opt Options, log func(string)) ([]Partition, error) {
	store, err := OpenStore(dest)
	if err != nil {
		return nil, err
	}
	parts, err := Candidates(ctx, c, table, before)
	if err != nil {
		return nil, err
	}
	cr, err := loadCrypto(ctx, c, table) // crypto-shredding: the table's data subject (crypto.go)
	if err != nil {
		return nil, err
	}
	engineFormat := ""
	if opt.Engine != "" {
		if opt.Keep != "" {
			return nil, fmt.Errorf("archive: --engine reads dropped partitions in place; --keep keeps them local")
		}
		if cr != nil {
			return nil, fmt.Errorf("archive: %s has encrypted columns (crypto-shredding), which an engine cannot read in place", table)
		}
		if err := c.QueryRow(ctx, "select format from gnomon.archive_engine where name = $1", opt.Engine).Scan(&engineFormat); err != nil {
			return nil, fmt.Errorf("archive: no engine %q in gnomon.archive_engine: %w", opt.Engine, err)
		}
		if _, local := store.(dirStore); engineFormat == "csv" && !local {
			return nil, fmt.Errorf("archive: engine %s reads a CSV file the server can open: archive to a local directory", opt.Engine)
		}
	}
	for _, p := range parts {
		name := fmt.Sprintf("%s.p%d.parquet", strings.NewReplacer(".", "_", `"`, "").Replace(p.Table), p.Part)
		w, uri, err := store.Create(name)
		if err != nil {
			return nil, err
		}
		n, err := writeParquet(ctx, c, p.Rel, map[string]string{"gnomon.table": p.Table, "gnomon.part": fmt.Sprint(p.Part)}, w, cr)
		if cerr := w.Close(); err == nil {
			err = cerr
		}
		if err != nil {
			return nil, err
		}
		// verify the file reads back from the store before the partition is dropped
		local, done, err := store.Fetch(uri)
		if err != nil {
			return nil, err
		}
		sum, err := Checksum(local)
		if err != nil {
			done()
			return nil, err
		}
		af, err := ReadParquet(local)
		done()
		if err != nil || int64(len(af.Rows)) != n {
			rows := 0
			if af != nil {
				rows = len(af.Rows)
			}
			return nil, fmt.Errorf("archive %s did not read back (%d rows): %v", uri, rows, err)
		}
		location := uri
		if engineFormat == "csv" {
			// the engine's copy, beside the Parquet file, while the partition is still here
			location = strings.TrimSuffix(LocalPath(uri), ".parquet") + ".csv"
			if err := writeCSV(ctx, c, p.Rel, location); err != nil {
				return nil, err
			}
		} else if engineFormat == "parquet" {
			location = LocalPath(uri)
			if strings.Contains(uri, "://") && !strings.HasPrefix(uri, "file://") {
				location = uri
			}
		}
		if _, err := c.Exec(ctx, "select gnomon.archive_partition($1::regclass, $2, $3, $4, $5, $6, 2)", p.Table, p.Part, uri, n, sum, opt.Keep != ""); err != nil {
			return nil, err
		}
		if opt.Engine != "" {
			var rel string
			if err := c.QueryRow(ctx, "select gnomon.attach_archive($1::regclass, $2, $3, $4)", p.Table, p.Part, opt.Engine, location).Scan(&rel); err != nil {
				return nil, err
			}
			log(fmt.Sprintf("attached %s partition %d in place: %s (%s)", p.Table, p.Part, rel, opt.Engine))
		}
		p.Rows = n
		log(fmt.Sprintf("archived %s partition %d: %d versions -> %s", p.Table, p.Part, n, uri))
	}
	if opt.Keep != "" && len(parts) > 0 {
		if _, err := c.Exec(ctx, "select gnomon.set_retention($1::regclass, $2::jsonb)", table, opt.Keep); err != nil {
			return parts, err
		}
		var res string
		if err := c.QueryRow(ctx, "select gnomon.apply_retention($1::regclass)::text", table).Scan(&res); err != nil {
			return parts, err
		}
		log("kept locally, thinned by retention: " + res)
	}
	return parts, nil
}

// Restore loads an archived partition back and marks it restored.
func Restore(ctx context.Context, c *pgx.Conn, table string, part int) error {
	var uri, sum string
	if err := c.QueryRow(ctx, "select uri, checksum from gnomon.archive where tbl = _gnomon.base_rel($1::regclass) and part = $2", table, part).Scan(&uri, &sum); err != nil {
		return fmt.Errorf("no archive of %s partition %d: %w", table, part, err)
	}
	local, done, err := fetch(uri)
	if err != nil {
		return err
	}
	defer done()
	got, err := Checksum(local)
	if err != nil {
		return err
	}
	if got != sum {
		return fmt.Errorf("checksum mismatch for %s: the file changed since it was archived", uri)
	}
	af, err := ReadParquet(local)
	if err != nil {
		return err
	}
	if err := decryptRows(ctx, c, table, af.Rows); err != nil {
		return err
	}
	tx, err := c.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var rel string
	if err := tx.QueryRow(ctx, "select gnomon.restore_partition($1::regclass, $2)", table, part).Scan(&rel); err != nil {
		return err
	}
	// a partition archived with --keep is still here, thinned: the file replaces it whole
	var thinned bool
	_ = tx.QueryRow(ctx, "select thinned from gnomon.archive where tbl = _gnomon.base_rel($1::regclass) and part = $2", table, part).Scan(&thinned)
	if thinned {
		if _, err := tx.Exec(ctx, "delete from "+rel); err != nil {
			return err
		}
	}
	const batch = 500
	for i := 0; i < len(af.Rows); i += batch {
		j := min(i+batch, len(af.Rows))
		b, err := json.Marshal(af.Rows[i:j])
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, fmt.Sprintf("insert into %s select * from jsonb_populate_recordset(null::%s, $1::jsonb)", rel, rel), string(b)); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(ctx, "select gnomon.restore_done($1::regclass, $2)", table, part); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// EraseArchives applies gnomon.erasure markers to archived files: erased columns become null
// for the erased keys, and the manifest checksum is updated.
func EraseArchives(ctx context.Context, c *pgx.Conn, log func(string)) (int, error) {
	// archived values are their text forms (WriteParquet): match the erased key by the text forms
	// of its values, read through the table's column types, or by its row id for wide keys (whose
	// version rows carry gn_rid instead of the key columns)
	rows, err := c.Query(ctx, `
	  select a.id, a.uri, e.key::text, t.key_cols::text[], t.wide_key, e.tbl::text, t.base,
	         array(select 'gn_c' || (t.colmap ->> a2.attnum::text) from unnest(e.cols) x
	                 join pg_attribute a2 on a2.attrelid = t.rel and a2.attname = x) ||
	         array(select 'gn_h' || (t.colmap ->> a2.attnum::text) from unnest(e.cols) x
	                 join pg_attribute a2 on a2.attrelid = t.rel and a2.attname = x)
	    from gnomon.erasure e join gnomon.archive a on a.tbl = e.tbl and not a.restored
	    join gnomon.tracked t on t.rel = e.tbl
	   order by a.id`)
	if err != nil {
		return 0, err
	}
	type job struct {
		id      int64
		uri     string
		key     string
		keyCols []string
		wide    bool
		tbl     string
		base    string
		cols    []string
		match   map[string]string
	}
	var jobs []job
	for rows.Next() {
		var j job
		if err := rows.Scan(&j.id, &j.uri, &j.key, &j.keyCols, &j.wide, &j.tbl, &j.base, &j.cols); err != nil {
			return 0, err
		}
		jobs = append(jobs, j)
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	for i := range jobs {
		j := &jobs[i]
		var q string
		if j.wide {
			eqs := make([]string, len(j.keyCols))
			for n, k := range j.keyCols {
				id := pgx.Identifier{k}.Sanitize()
				eqs[n] = fmt.Sprintf("i.%s = r.%s", id, id)
			}
			q = fmt.Sprintf("select jsonb_build_object('gn_rid', i.gn_rid::text) from %s i, jsonb_populate_record(null::%s, $1::jsonb) r where %s",
				pgx.Identifier{"_gnomon", j.base + "__id"}.Sanitize(), j.tbl, strings.Join(eqs, " and "))
		} else {
			pairs := make([]string, len(j.keyCols))
			for n, k := range j.keyCols {
				pairs[n] = fmt.Sprintf("%s, r.%s::text", quoteLiteral(k), pgx.Identifier{k}.Sanitize())
			}
			q = fmt.Sprintf("select jsonb_build_object(%s) from jsonb_populate_record(null::%s, $1::jsonb) r", strings.Join(pairs, ", "), j.tbl)
		}
		var m []byte
		if err := c.QueryRow(ctx, q, j.key).Scan(&m); err != nil {
			if err == pgx.ErrNoRows {
				continue // a wide key with no row id: it never had a version to archive
			}
			return 0, fmt.Errorf("erased key %s of %s: %w", j.key, j.tbl, err)
		}
		if err := json.Unmarshal(m, &j.match); err != nil {
			return 0, err
		}
	}
	changedFiles := 0
	for _, j := range jobs {
		store, err := OpenStore(j.uri)
		if err != nil {
			return changedFiles, err
		}
		path, done, err := store.Fetch(j.uri)
		if err != nil {
			return changedFiles, err
		}
		af, err := ReadParquet(path)
		if err != nil {
			done()
			return changedFiles, err
		}
		changed := 0
		for _, r := range af.Rows {
			match := len(j.match) > 0
			for k, want := range j.match {
				v := r[k]
				if v == nil || *v != want {
					match = false
					break
				}
			}
			if !match {
				continue
			}
			for _, col := range j.cols {
				if _, ok := r[col]; ok && r[col] != nil {
					r[col] = nil
					changed++
				}
			}
		}
		if changed == 0 {
			done()
			continue
		}
		if err := WriteFile(path, af); err != nil {
			done()
			return changedFiles, err
		}
		sum, err := Checksum(path)
		if err == nil {
			err = store.Put(j.uri, path)
		}
		done()
		if err != nil {
			return changedFiles, err
		}
		if _, err := c.Exec(ctx, "update gnomon.archive set checksum = $1 where id = $2", sum, j.id); err != nil {
			return changedFiles, err
		}
		changedFiles++
		log(fmt.Sprintf("erased %d value(s) in %s", changed, j.uri))
	}
	return changedFiles, nil
}

// quoteLiteral quotes s as an SQL string literal.
func quoteLiteral(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

// writeCSV copies a partition's rows to a CSV file an engine such as file_fdw reads.
func writeCSV(ctx context.Context, c *pgx.Conn, rel, path string) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	if _, err := c.PgConn().CopyTo(ctx, f, fmt.Sprintf("copy (select * from %s order by gn_key, gn_lsn) to stdout with (format csv, header true, null '\\N')", rel)); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}
