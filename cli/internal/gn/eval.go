package gn

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

func init() {
	register(&Command{Name: "eval", Usage: "eval <spec.json> [--trials n] [--keep]", Summary: "run an agent against a tagged state several times and score each trial", Run: evalCmd})
}

// EvalSpec is what `gnomon eval` reads.
type EvalSpec struct {
	Name    string   `json:"name"`
	Base    string   `json:"base"`    // a tag (or any reference) every trial forks at
	Task    string   `json:"task"`    // passed to the agent as GNOMON_TASK
	Command []string `json:"command"` // the agent; it gets DATABASE_URL, GNOMON_DSN, GNOMON_BRANCH, GNOMON_TASK, GNOMON_RUN
	Trials  int      `json:"trials"`
	Expect  struct {
		Diff      string   `json:"diff"`      // a snapshot file (normalized diff), relative to the spec
		Ignore    []string `json:"ignore"`    // columns the comparison ignores
		Checks    bool     `json:"checks"`    // the configured checks must pass
		Unchanged []string `json:"unchanged"` // tables that must not change
		MaxRows   int      `json:"max_rows"`  // rows changed at most
		MaxSecs   float64  `json:"max_seconds"`
	} `json:"expect"`
}

// TrialResult is one line of eval output.
type TrialResult struct {
	Trial      int      `json:"trial"`
	Branch     string   `json:"branch"`
	DiffMatch  *bool    `json:"diff_match,omitempty"`
	ChecksPass *bool    `json:"checks_pass,omitempty"`
	Rows       int      `json:"rows_changed"`
	Extra      int      `json:"rows_beyond_expected"`
	Violations []string `json:"violations"`
	Steps      int      `json:"steps"`
	Seconds    float64  `json:"seconds"`
	ExitCode   int      `json:"exit_code"`
	Pass       bool     `json:"pass"`
}

func evalCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("eval")
	trials := fs.Int("trials", 0, "trials (default: the spec's, or 1)")
	keep := fs.Bool("keep", false, "keep the trial branches")
	pos, err := parse(fs, args)
	if err != nil || len(pos) != 1 {
		return ErrUsage
	}
	b, err := os.ReadFile(pos[0])
	if err != nil {
		return err
	}
	var spec EvalSpec
	if err := json.Unmarshal(b, &spec); err != nil {
		return fmt.Errorf("%s: %w", pos[0], err)
	}
	n := spec.Trials
	if *trials > 0 {
		n = *trials
	}
	if n <= 0 {
		n = 1
	}
	var want []string
	if spec.Expect.Diff != "" {
		wb, err := os.ReadFile(filepath.Join(filepath.Dir(pos[0]), spec.Expect.Diff))
		if err != nil {
			return err
		}
		want = strings.Split(strings.TrimRight(string(wb), "\n"), "\n")
	}
	o2 := *o
	o2.Branch = ""
	return withConn(ctx, &o2, func(c *pgx.Conn) error {
		enc := json.NewEncoder(o.Out)
		passed := 0
		for i := 1; i <= n; i++ {
			r, err := evalTrial(ctx, c, o.DSN, spec, i, want)
			if err != nil {
				return err
			}
			if r.Pass {
				passed++
			}
			if err := enc.Encode(r); err != nil {
				return err
			}
			if !*keep {
				_, _ = c.Exec(ctx, "select gnomon.drop_branch($1, true)", r.Branch)
			}
		}
		return enc.Encode(map[string]any{"summary": spec.Name, "trials": n, "passed": passed, "pass_rate": float64(passed) / float64(n)})
	})
}

func evalTrial(ctx context.Context, c *pgx.Conn, dsn string, spec EvalSpec, i int, want []string) (*TrialResult, error) {
	r := &TrialResult{Trial: i, Violations: []string{}}
	if err := c.QueryRow(ctx, "select gnomon.create_scratch('eval', 'main')").Scan(&r.Branch); err != nil {
		return nil, err
	}
	if spec.Base != "" {
		// fork at the base: a scratch branch made at that reference
		_, _ = c.Exec(ctx, "select gnomon.drop_branch($1, true)", r.Branch)
		r.Branch = fmt.Sprintf("eval-%s-%d", randomHex(3), i)
		if _, err := c.Exec(ctx, "select gnomon.create_branch($1, 'main', 'scratch', $2)", r.Branch, spec.Base); err != nil {
			return nil, err
		}
	}
	var opts string
	if err := c.QueryRow(ctx, "select gnomon.connection_options($1)", r.Branch).Scan(&opts); err != nil {
		return nil, err
	}
	run := "eval-" + r.Branch
	branchDSN := strings.TrimSpace(dsn + " options='" + opts + "'")
	start := time.Now()
	if len(spec.Command) > 0 {
		ctx2, cancel := context.WithTimeout(ctx, 30*time.Minute)
		cmd := exec.CommandContext(ctx2, spec.Command[0], spec.Command[1:]...)
		cmd.Env = append(os.Environ(), "DATABASE_URL="+branchDSN, "GNOMON_DSN="+branchDSN, "GNOMON_BRANCH="+r.Branch,
			"GNOMON_TASK="+spec.Task, "GNOMON_RUN="+run, "PGOPTIONS="+opts)
		var out bytes.Buffer
		cmd.Stdout, cmd.Stderr = &out, &out
		if err := cmd.Run(); err != nil {
			if ee, ok := err.(*exec.ExitError); ok {
				r.ExitCode = ee.ExitCode()
			} else {
				r.ExitCode = -1
			}
			r.Violations = append(r.Violations, "the agent failed: "+strings.TrimSpace(lastLines(out.String(), 3)))
		}
		cancel()
	}
	r.Seconds = time.Since(start).Seconds()
	got, rows, err := BranchSnapshot(ctx, c, r.Branch, spec.Expect.Ignore)
	if err != nil {
		return nil, err
	}
	r.Rows = rows
	if want != nil {
		ok := strings.Join(got, "\n") == strings.Join(want, "\n")
		r.DiffMatch = &ok
		if !ok {
			wantSet := map[string]bool{}
			for _, w := range want {
				wantSet[w] = true
			}
			for _, g := range got {
				if !wantSet[g] {
					r.Extra++
				}
			}
			r.Violations = append(r.Violations, fmt.Sprintf("the diff differs from %s", spec.Expect.Diff))
		}
	}
	if spec.Expect.Checks {
		var failed int
		if err := c.QueryRow(ctx, "select count(*) filter (where not passed) from gnomon.run_checks($1)", r.Branch).Scan(&failed); err != nil {
			return nil, err
		}
		ok := failed == 0
		r.ChecksPass = &ok
		if !ok {
			r.Violations = append(r.Violations, fmt.Sprintf("%d check(s) failed", failed))
		}
	}
	for _, t := range spec.Expect.Unchanged {
		var n int
		if err := c.QueryRow(ctx, "select count(*) from gnomon.diff($1, null, array[$2::regclass])", r.Branch, t).Scan(&n); err == nil && n > 0 {
			r.Violations = append(r.Violations, fmt.Sprintf("%s changed (%d field(s))", t, n))
		}
	}
	if spec.Expect.MaxRows > 0 && r.Rows > spec.Expect.MaxRows {
		r.Violations = append(r.Violations, fmt.Sprintf("%d rows changed, more than %d", r.Rows, spec.Expect.MaxRows))
	}
	if spec.Expect.MaxSecs > 0 && r.Seconds > spec.Expect.MaxSecs {
		r.Violations = append(r.Violations, fmt.Sprintf("%.1fs, more than %.1fs", r.Seconds, spec.Expect.MaxSecs))
	}
	_ = c.QueryRow(ctx, "select count(*) from gnomon.agent_call where run = $1", run).Scan(&r.Steps)
	r.Pass = len(r.Violations) == 0
	return r, nil
}

func lastLines(s string, n int) string {
	l := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(l) > n {
		l = l[len(l)-n:]
	}
	return strings.Join(l, " | ")
}

// BranchSnapshot is a branch's diff normalized as sdk/spec/SPEC.md says (Snapshots): the same
// rules as the SDKs' testing layers. It also returns how many rows changed.
func BranchSnapshot(ctx context.Context, c *pgx.Conn, branch string, ignore []string) ([]string, int, error) {
	res, err := Query(ctx, c, "select format('%I.%I', n.nspname, cl.relname) as tbl, d.key::text as key, d.kind, d.col, d.old::text as old, d.new::text as new from gnomon.diff($1) d join pg_class cl on cl.oid = d.tbl join pg_namespace n on n.oid = cl.relnamespace", branch)
	if err != nil {
		return nil, 0, err
	}
	var diff []DiffRow
	keys := map[string]bool{}
	for _, m := range res.Maps {
		d := DiffRow{Table: fmt.Sprint(m["tbl"]), Kind: fmt.Sprint(m["kind"])}
		_ = jsonUseNumber(fmt.Sprint(m["key"]), &d.Key)
		if m["col"] != nil {
			s := fmt.Sprint(m["col"])
			d.Col = &s
		}
		if m["old"] != nil {
			_ = jsonUseNumber(fmt.Sprint(m["old"]), &d.Old)
		}
		if m["new"] != nil {
			_ = jsonUseNumber(fmt.Sprint(m["new"]), &d.New)
		}
		diff = append(diff, d)
		keys[d.Table+fmt.Sprint(m["key"])] = true
	}
	fk, err := Query(ctx, c, `select format('%I.%I', n.nspname, c.relname) as tbl,
	   (select array_agg(a.attname::text order by k.o) from unnest(f.conkey) with ordinality k(n, o) join pg_attribute a on a.attrelid = f.conrelid and a.attnum = k.n) as cols,
	   format('%I.%I', pn.nspname, p.relname) as ref,
	   (select array_agg(a.attname::text order by k.o) from unnest(f.confkey) with ordinality k(n, o) join pg_attribute a on a.attrelid = f.confrelid and a.attnum = k.n) as rcols
	  from pg_constraint f join pg_class c on c.oid = f.conrelid join pg_namespace n on n.oid = c.relnamespace
	  join pg_class p on p.oid = f.confrelid join pg_namespace pn on pn.oid = p.relnamespace where f.contype = 'f'`)
	if err != nil {
		return nil, 0, err
	}
	var fks []ForeignKey
	for _, m := range fk.Maps {
		fks = append(fks, ForeignKey{Table: fmt.Sprint(m["tbl"]), Columns: toStrings(m["cols"]), References: fmt.Sprint(m["ref"]), ReferencedColumns: toStrings(m["rcols"])})
	}
	return NormalizeDiff(diff, ignore, fks), len(keys), nil
}

func jsonUseNumber(s string, v any) error {
	d := json.NewDecoder(strings.NewReader(s))
	d.UseNumber()
	return d.Decode(v)
}

// DiffRow is one row of gnomon.diff.
type DiffRow struct {
	Table string         `json:"table"`
	Key   map[string]any `json:"key"`
	Kind  string         `json:"kind"`
	Col   *string        `json:"col"`
	Old   any            `json:"old"`
	New   any            `json:"new"`
}

// ForeignKey for NormalizeDiff.
type ForeignKey struct {
	Table             string   `json:"table"`
	Columns           []string `json:"columns"`
	References        string   `json:"references"`
	ReferencedColumns []string `json:"referenced_columns"`
}

// stableJSONGo writes JSON with object keys sorted and numbers as written.
func stableJSONGo(v any) string {
	b, _ := json.Marshal(v) // encoding/json sorts map keys; json.Number keeps its text
	return string(b)
}

func cmpKeyGo(a, b map[string]any) int {
	ks := make([]string, 0, len(a))
	for k := range a {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	for _, k := range ks {
		x, y := a[k], b[k]
		xn, xok := asBig(x)
		yn, yok := asBig(y)
		if xok && yok {
			if c := xn.Cmp(yn); c != 0 {
				return c
			}
			continue
		}
		sx, sy := fmt.Sprint(x), fmt.Sprint(y)
		if sx != sy {
			if sx < sy {
				return -1
			}
			return 1
		}
	}
	return 0
}

func asBig(v any) (*big.Float, bool) {
	switch x := v.(type) {
	case json.Number:
		f, ok := new(big.Float).SetString(x.String())
		return f, ok
	case float64:
		return big.NewFloat(x), true
	}
	return nil, false
}

// NormalizeDiff implements the specification's snapshot rules (checked against sdk/spec/snapshot).
func NormalizeDiff(diff []DiffRow, ignore []string, fks []ForeignKey) []string {
	ig := map[string]bool{}
	for _, c := range ignore {
		ig[c] = true
	}
	byTable := map[string][]map[string]any{}
	for _, d := range diff {
		dup := false
		for _, k := range byTable[d.Table] {
			if stableJSONGo(k) == stableJSONGo(d.Key) {
				dup = true
			}
		}
		if !dup {
			byTable[d.Table] = append(byTable[d.Table], d.Key)
		}
	}
	ph, idx := map[string]string{}, map[string]int{}
	for t, ks := range byTable {
		sort.SliceStable(ks, func(i, j int) bool { return cmpKeyGo(ks[i], ks[j]) < 0 })
		short := t[strings.LastIndex(t, ".")+1:]
		for i, k := range ks {
			ph[t+"|"+stableJSONGo(k)] = fmt.Sprintf("<%s:%d>", short, i+1)
			idx[t+"|"+stableJSONGo(k)] = i + 1
		}
	}
	value := func(table string, key map[string]any, col string, v any) string {
		if _, isKey := key[col]; isKey && len(key) == 1 {
			if p, ok := ph[table+"|"+stableJSONGo(key)]; ok {
				return p
			}
		}
		for _, f := range fks {
			if f.Table == table && len(f.Columns) == 1 && f.Columns[0] == col {
				if p, ok := ph[f.References+"|"+stableJSONGo(map[string]any{f.ReferencedColumns[0]: v})]; ok {
					return p
				}
			}
		}
		return stableJSONGo(v)
	}
	type line struct {
		t string
		i int
		s string
	}
	seen := map[string]bool{}
	var lines []line
	add := func(t string, i int, s string) {
		if !seen[s] {
			seen[s] = true
			lines = append(lines, line{t, i, s})
		}
	}
	for _, d := range diff {
		id := d.Table + "|" + stableJSONGo(d.Key)
		p, i := ph[id], idx[id]
		switch d.Kind {
		case "delete":
			add(d.Table, i, fmt.Sprintf("%s %s delete", d.Table, p))
		case "insert":
			img, _ := d.New.(map[string]any)
			for c, v := range img {
				if !ig[c] {
					add(d.Table, i, fmt.Sprintf("%s %s insert %s = %s", d.Table, p, c, value(d.Table, d.Key, c, v)))
				}
			}
		default:
			if d.Col == nil || ig[*d.Col] {
				continue
			}
			add(d.Table, i, fmt.Sprintf("%s %s update %s: %s -> %s", d.Table, p, *d.Col, value(d.Table, d.Key, *d.Col, d.Old), value(d.Table, d.Key, *d.Col, d.New)))
		}
	}
	sort.Slice(lines, func(a, b int) bool {
		if lines[a].t != lines[b].t {
			return lines[a].t < lines[b].t
		}
		if lines[a].i != lines[b].i {
			return lines[a].i < lines[b].i
		}
		return lines[a].s < lines[b].s
	})
	out := make([]string, len(lines))
	for i, l := range lines {
		out[i] = l.s
	}
	return out
}
