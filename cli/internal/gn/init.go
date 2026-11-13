package gn

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/jackc/pgx/v5"
)

func init() {
	register(&Command{Name: "init", Usage: "init [--schema public] [--plain-sql file] [--no-heartbeat]", Summary: "install gnomon, track a schema, set up the heartbeat, run doctor", Run: initCmd})
	register(&Command{Name: "export", Usage: "export --branch b [--mask profile] [--as-of ref] [--tables a,b] [--where 'table: condition'] --to <dsn|directory>", Summary: "a branch (masked, subset) as a database of its own", Run: exportCmd})
}

// gnomon init: from an empty database to a tracked schema with a heartbeat.
func initCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("init")
	schema := fs.String("schema", "public", "the schema to track")
	plain := fs.String("plain-sql", "", "the plain-SQL install script, where CREATE EXTENSION is not available")
	noHB := fs.Bool("no-heartbeat", false, "do not set up the heartbeat")
	if _, err := parse(fs, args); err != nil {
		return err
	}
	o2 := *o
	o2.Branch = ""
	return withConn(ctx, &o2, func(c *pgx.Conn) error {
		say := func(f string, a ...any) { fmt.Fprintf(o.Out, f+"\n", a...) }
		var ver int
		var super bool
		var db, user string
		if err := c.QueryRow(ctx, "select current_setting('server_version_num')::int, (select rolsuper from pg_roles where rolname = current_user), current_database(), current_user").Scan(&ver, &super, &db, &user); err != nil {
			return err
		}
		if ver < 150000 {
			return fmt.Errorf("PostgreSQL %d.%d: gnomon needs 15 or later", ver/10000, ver%10000)
		}
		say("server: PostgreSQL %d.%d, database %s, as %s%s", ver/10000, ver%10000, db, user, map[bool]string{true: " (superuser)", false: ""}[super])
		var installed, available bool
		_ = c.QueryRow(ctx, "select exists (select 1 from pg_namespace where nspname = 'gnomon'), exists (select 1 from pg_available_extensions where name = 'gnomon')").Scan(&installed, &available)
		switch {
		case installed:
			say("gnomon: installed")
		case available:
			if !super {
				var canCreate bool
				_ = c.QueryRow(ctx, "select has_database_privilege(current_user, current_database(), 'CREATE')").Scan(&canCreate)
				if !canCreate {
					return fmt.Errorf("installing gnomon needs a superuser (or the provider's extension admin role): ask for one, or run this as one")
				}
			}
			if _, err := c.Exec(ctx, "create extension gnomon"); err != nil {
				return err
			}
			say("gnomon: installed with CREATE EXTENSION")
		case *plain != "":
			b, err := os.ReadFile(*plain)
			if err != nil {
				return err
			}
			if _, err := c.Exec(ctx, string(b)); err != nil {
				return fmt.Errorf("the plain-SQL install failed: %w", err)
			}
			say("gnomon: installed from %s", *plain)
		default:
			return fmt.Errorf("the gnomon extension is not available on this server: install it (make install), or pass --plain-sql gnomon-plain--<version>.sql (tools/build_install_forms.sh builds it)")
		}
		var n int
		if err := c.QueryRow(ctx, "select gnomon.track_schema($1)", *schema).Scan(&n); err != nil {
			return err
		}
		res, err := Query(ctx, c, `select c.relname from pg_class c join pg_namespace s on s.oid = c.relnamespace
		                            where s.nspname = $1 and c.relkind in ('r', 'p') and not exists (select 1 from pg_index i where i.indrelid = c.oid and i.indisprimary)
		                              and not exists (select 1 from pg_inherits h where h.inhrelid = c.oid) order by 1`, *schema)
		if err != nil {
			return err
		}
		var total int
		_ = c.QueryRow(ctx, "select count(*) from gnomon.tracked where nsp = $1", *schema).Scan(&total)
		say("tracked: %d table(s) in %s (%d now)", total, *schema, n)
		if len(res.Rows) > 0 {
			var names []string
			for _, r := range res.Rows {
				names = append(names, fmt.Sprint(r[0]))
			}
			say("skipped (no primary key; gnomon.track(table, key => ...) names one): %s", strings.Join(names, ", "))
		}
		if !*noHB {
			var cmod, cron bool
			_ = c.QueryRow(ctx, "select current_setting('shared_preload_libraries') like '%gnomon_c%', exists (select 1 from pg_extension where extname = 'pg_cron')").Scan(&cmod, &cron)
			switch {
			case cmod:
				var dbs string
				_ = c.QueryRow(ctx, "select coalesce(current_setting('gnomon.heartbeat_databases', true), '')").Scan(&dbs)
				if strings.Contains(","+dbs+",", ","+db+",") {
					say("heartbeat: the C module's worker ticks this database")
				} else {
					say("heartbeat: the C module is loaded; add %s to gnomon.heartbeat_databases (postgresql.conf) and reload", db)
				}
			case cron:
				if _, err := c.Exec(ctx, "select cron.schedule('gnomon-heartbeat', '1 seconds', 'select gnomon.heartbeat()')"); err != nil {
					say("heartbeat: pg_cron is installed but scheduling failed (%s); run gnomon daemon instead", PgError(err))
				} else {
					say("heartbeat: scheduled with pg_cron every second")
				}
			default:
				say("heartbeat: nothing runs it yet. Run this somewhere (a service unit follows):\n  gnomon daemon --dsn '<a gnomon_admin login>'")
				say(`  [Unit]
  Description=gnomon heartbeat and job loop
  [Service]
  Environment=GNOMON_DSN=postgresql://gnomon_daemon@localhost/%s
  ExecStart=/usr/local/bin/gnomon daemon
  Restart=always
  [Install]
  WantedBy=multi-user.target`, db)
			}
			_, _ = c.Exec(ctx, "select gnomon.heartbeat()")
		}
		dr, err := Query(ctx, c, "select check_name, status, detail from gnomon.doctor() where status <> 'ok'")
		if err == nil {
			for _, m := range dr.Maps {
				say("doctor %v: %v: %v", m["status"], m["check_name"], m["detail"])
			}
		}
		say(`
next:
  gnomon branch create try-it
  gnomon --branch try-it sql "update ... "
  gnomon diff try-it
  gnomon merge try-it --preview
  gnomon agent create my-agent      (a connection string for an agent, confined to its branch)`)
		return nil
	})
}

// gnomon export: pre-data from pg_dump, the branch's rows (masked, subset, as of a
// moment) in one repeatable-read transaction, post-data without gnomon's triggers and policies,
// sequences past the copied maximum.
func exportCmd(ctx context.Context, o *Options, args []string) error {
	fs := flags("export")
	mask := fs.String("mask", "", "a mask profile the rows are read through")
	asOf := fs.String("as-of", "", "the branch as of this moment")
	tables := fs.String("tables", "", "only these tables (default: every table of the tracked schemas)")
	var where multi
	fs.Var(&where, "where", "table: condition (repeat); parents of kept rows come with them")
	to := fs.String("to", "", "a connection string, or a directory")
	if _, err := parse(fs, args); err != nil {
		return err
	}
	if *to == "" {
		return ErrUsage
	}
	branch := o.Branch
	if branch == "" {
		branch = "main"
	}
	o2 := *o
	o2.Branch = ""
	return withConn(ctx, &o2, func(c *pgx.Conn) error {
		return Export(ctx, c, ExportOptions{DSN: o.DSN, Branch: branch, Mask: *mask, AsOf: *asOf, Tables: splitList(*tables), Where: where, To: *to, Log: func(s string) { fmt.Fprintln(o.Out, s) }})
	})
}

func splitList(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(s, ",")
}

// ExportOptions for Export.
type ExportOptions struct {
	DSN, Branch, Mask, AsOf, To string
	Tables, Where               []string
	Log                         func(string)
}

// Export writes a branch as a database of its own: to a directory (pre.sql, data.sql, post.sql,
// restore with psql in that order) or into another database.
func Export(ctx context.Context, c *pgx.Conn, eo ExportOptions) error {
	if eo.Log == nil {
		eo.Log = func(string) {}
	}
	var schemas []string
	res, err := Query(ctx, c, "select distinct nsp from gnomon.tracked order by 1")
	if err != nil {
		return err
	}
	for _, r := range res.Rows {
		schemas = append(schemas, fmt.Sprint(r[0]))
	}
	dumpArgs := func(section string) []string {
		a := []string{"--section=" + section, "--no-owner", "--no-privileges"}
		for _, s := range schemas {
			a = append(a, "--schema="+s)
		}
		return a
	}
	pre, err := pgDump(ctx, c, dumpArgs("pre-data"))
	if err != nil {
		return err
	}
	post, err := pgDump(ctx, c, dumpArgs("post-data"))
	if err != nil {
		return err
	}
	post = stripGnomon(post)
	// the target may have the schemas already (public always does)
	pre = createSchema.ReplaceAllString(pre, "CREATE SCHEMA IF NOT EXISTS $1;")

	tx, err := c.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadWrite})
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var coord string
	if err := tx.QueryRow(ctx, "select gnomon.coordinate_text()").Scan(&coord); err != nil {
		return err
	}
	var asOf any
	if eo.AsOf != "" {
		asOf = eo.AsOf
		coord = eo.AsOf
	}
	if _, err := tx.Exec(ctx, "select gnomon.begin($1, $2)", eo.Branch, asOf); err != nil {
		return err
	}
	// the tables, parents first, and where each is read
	tres, err := Query(ctx, tx.Conn(), `
	  with recursive t as (
	    select c.oid as rel, n.nspname as nsp, c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
	     where n.nspname = any($1) and c.relkind in ('r', 'p') and not exists (select 1 from pg_inherits h where h.inhrelid = c.oid)),
	  d as (select rel, 0 as depth from t
	        union all select f.conrelid, d.depth + 1 from pg_constraint f join d on f.confrelid = d.rel
	         where f.contype = 'f' and f.conrelid <> f.confrelid and d.depth < 30)
	  select t.nsp, t.relname, format('%I.%I', t.nsp, t.relname) as q, max(d.depth) as depth,
	         exists (select 1 from gnomon.tracked x where x.rel = t.rel) as tracked
	    from t join d on d.rel = t.rel group by 1, 2, 3, 5 order by 4, 3`, schemas)
	if err != nil {
		return err
	}
	filters := map[string]string{}
	for _, w := range eo.Where {
		tn, cond, ok := strings.Cut(w, ":")
		if !ok {
			return fmt.Errorf("--where is 'table: condition', not %q", w)
		}
		filters[strings.TrimSpace(tn)] = strings.TrimSpace(cond)
	}
	want := map[string]bool{}
	for _, t := range eo.Tables {
		want[strings.TrimSpace(t)] = true
	}
	type tab struct{ nsp, name, q, src string }
	var tabs []tab
	for _, m := range tres.Maps {
		name, q := fmt.Sprint(m["relname"]), fmt.Sprint(m["q"])
		if len(want) > 0 && !want[name] && !want[q] {
			continue
		}
		src := quoteIdent(name) // through the session's path: the branch's routing view (or the table on main)
		if eo.Mask != "" && m["tracked"] == true {
			var ms string
			if err := tx.QueryRow(ctx, "select format('%I', _gnomon.mask_schema((select id from gnomon.mask_profile where name = $1), $2))", eo.Mask, m["nsp"]).Scan(&ms); err != nil {
				return fmt.Errorf("mask profile %s: %w", eo.Mask, err)
			}
			src = ms + "." + quoteIdent(name)
		} else if eo.Branch == "main" && eo.AsOf == "" {
			src = q
		}
		tabs = append(tabs, tab{fmt.Sprint(m["nsp"]), name, q, src})
	}
	// the rows: filtered tables first into temp tables, then parents of kept rows closed over
	for _, t := range tabs {
		cond := filters[t.name]
		if cond == "" {
			cond = filters[t.q]
		}
		if cond == "" {
			cond = "true"
		}
		if _, err := tx.Exec(ctx, fmt.Sprintf("create temp table %s on commit drop as select * from %s as %s where %s",
			quoteIdent("gn_exp_"+t.nsp+"_"+t.name), t.src, quoteIdent(t.name), cond)); err != nil {
			return fmt.Errorf("%s: %w", t.q, err)
		}
	}
	for pass := 0; pass < 20 && len(filters) > 0; pass++ {
		added := int64(0)
		for _, t := range tabs {
			fk, err := Query(ctx, tx.Conn(), `select c.confrelid::regclass::text as parent, pn.nspname as pnsp, pc.relname as pname,
			        (select array_agg(a.attname order by k.o) from unnest(c.conkey) with ordinality k(n, o) join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.n) as cols,
			        (select array_agg(a.attname order by k.o) from unnest(c.confkey) with ordinality k(n, o) join pg_attribute a on a.attrelid = c.confrelid and a.attnum = k.n) as pcols
			   from pg_constraint c join pg_class pc on pc.oid = c.confrelid join pg_namespace pn on pn.oid = pc.relnamespace
			  where c.contype = 'f' and c.conrelid = $1::regclass`, t.q)
			if err != nil {
				return err
			}
			for _, f := range fk.Maps {
				var ptab *tab
				for i := range tabs {
					if tabs[i].nsp == fmt.Sprint(f["pnsp"]) && tabs[i].name == fmt.Sprint(f["pname"]) {
						ptab = &tabs[i]
					}
				}
				if ptab == nil {
					continue
				}
				cols, pcols := toStrings(f["cols"]), toStrings(f["pcols"])
				var on, nn, same []string
				for i := range cols {
					on = append(on, fmt.Sprintf("p.%s = ch.%s", quoteIdent(pcols[i]), quoteIdent(cols[i])))
					nn = append(nn, "ch."+quoteIdent(cols[i])+" is not null")
					same = append(same, fmt.Sprintf("x.%s = p.%s", quoteIdent(pcols[i]), quoteIdent(pcols[i])))
				}
				pt := quoteIdent("gn_exp_" + ptab.nsp + "_" + ptab.name)
				ct := quoteIdent("gn_exp_" + t.nsp + "_" + t.name)
				tag, err := tx.Exec(ctx, fmt.Sprintf(`insert into %[1]s select distinct p.* from %[2]s as p join %[3]s ch on %[4]s
				    where %[5]s and not exists (select 1 from %[1]s x where %[6]s)`, pt, ptab.src, ct, strings.Join(on, " and "),
					strings.Join(nn, " and "), strings.Join(same, " and ")))
				if err != nil {
					return fmt.Errorf("parents of %s: %w", t.q, err)
				}
				added += tag.RowsAffected()
			}
		}
		if added == 0 {
			break
		}
	}
	var data bytes.Buffer
	counts := map[string]int64{}
	for _, t := range tabs {
		var colList string
		if err := tx.QueryRow(ctx, `select string_agg(quote_ident(attname), ', ' order by attnum) from pg_attribute
		                             where attrelid = $1::regclass and attnum > 0 and not attisdropped and attgenerated = ''`, t.q).Scan(&colList); err != nil {
			return err
		}
		fmt.Fprintf(&data, "COPY %s (%s) FROM stdin;\n", t.q, colList)
		tag, err := tx.Conn().PgConn().CopyTo(ctx, &data, fmt.Sprintf("copy (select %s from %s) to stdout", colList, quoteIdent("gn_exp_"+t.nsp+"_"+t.name)))
		if err != nil {
			return fmt.Errorf("copy %s: %w", t.q, err)
		}
		counts[t.q] = tag.RowsAffected()
		data.WriteString("\\.\n\n")
	}
	// sequences past the copied maximum
	seqs, err := Query(ctx, tx.Conn(), `select format('%I.%I', sn.nspname, s.relname) as seq, format('%I.%I', tn.nspname, t.relname) as tbl, a.attname
	   from pg_depend d join pg_class s on s.oid = d.objid and s.relkind = 'S' join pg_namespace sn on sn.oid = s.relnamespace
	   join pg_class t on t.oid = d.refobjid join pg_namespace tn on tn.oid = t.relnamespace
	   join pg_attribute a on a.attrelid = t.oid and a.attnum = d.refobjsubid
	  where d.deptype in ('a', 'i') and tn.nspname = any($1)`, schemas)
	if err != nil {
		return err
	}
	for _, s := range seqs.Maps {
		fmt.Fprintf(&data, "SELECT pg_catalog.setval(%s, greatest(1, coalesce((SELECT max(%s) FROM %s), 0)), (SELECT max(%s) FROM %s) IS NOT NULL);\n",
			quoteLiteral(fmt.Sprint(s["seq"])), quoteIdent(fmt.Sprint(s["attname"])), s["tbl"], quoteIdent(fmt.Sprint(s["attname"])), s["tbl"])
	}
	header := fmt.Sprintf("-- gnomon export of branch %s at %s%s\n", eo.Branch, coord, map[bool]string{true: ", mask profile " + eo.Mask, false: ""}[eo.Mask != ""])
	if err := tx.Rollback(ctx); err != nil {
		return err
	}
	for _, t := range tabs {
		eo.Log(fmt.Sprintf("%s: %d row(s)", t.q, counts[t.q]))
	}
	if strings.Contains(eo.To, "=") || strings.HasPrefix(eo.To, "postgres") {
		target, err := Connect(ctx, eo.To)
		if err != nil {
			return err
		}
		defer target.Close(ctx)
		for _, part := range []string{pre} {
			if _, err := target.Exec(ctx, part); err != nil {
				return fmt.Errorf("pre-data into the target: %w", err)
			}
		}
		if err := loadCopyScript(ctx, target, data.String()); err != nil {
			return err
		}
		if _, err := target.Exec(ctx, post); err != nil {
			return fmt.Errorf("post-data into the target: %w", err)
		}
		eo.Log("exported into the target database (" + strings.TrimSpace(header[3:]) + ")")
		return nil
	}
	if err := os.MkdirAll(eo.To, 0o755); err != nil {
		return err
	}
	for name, body := range map[string]string{"pre.sql": header + pre, "data.sql": header + data.String(), "post.sql": header + post,
		"README": header + "Restore into an empty database: psql -v ON_ERROR_STOP=1 -f pre.sql -f data.sql -f post.sql\n"} {
		if err := os.WriteFile(filepath.Join(eo.To, name), []byte(body), 0o644); err != nil {
			return err
		}
	}
	eo.Log("wrote " + eo.To + ": psql -f pre.sql -f data.sql -f post.sql into an empty database")
	return nil
}

func toStrings(v any) []string {
	var out []string
	if a, ok := v.([]any); ok {
		for _, x := range a {
			out = append(out, fmt.Sprint(x))
		}
	}
	return out
}

// pgDump runs pg_dump against the connection's database.
func pgDump(ctx context.Context, c *pgx.Conn, args []string) (string, error) {
	cfg := c.Config()
	env := os.Environ()
	env = append(env, "PGHOST="+cfg.Host, fmt.Sprintf("PGPORT=%d", cfg.Port), "PGUSER="+cfg.User, "PGDATABASE="+cfg.Database)
	if cfg.Password != "" {
		env = append(env, "PGPASSWORD="+cfg.Password)
	}
	cmd := exec.CommandContext(ctx, "pg_dump", args...)
	cmd.Env = env
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("pg_dump: %v: %s", err, errb.String())
	}
	// (psql meta-commands such as \restrict, which pg_dump 18 writes, are not SQL a connection runs)
	var lines []string
	for _, l := range strings.Split(out.String(), "\n") {
		if strings.HasPrefix(l, "\\") {
			continue
		}
		lines = append(lines, l)
	}
	return strings.Join(lines, "\n"), nil
}

// stripGnomon drops gnomon's own objects from a post-data dump: its triggers, policies and the
// row-level security it switched on (kept where a policy of the user's own remains).
var createSchema = regexp.MustCompile(`(?m)^CREATE SCHEMA (\S+);`)
var policyOn = regexp.MustCompile(`(?i)create policy\s+\S+\s+on\s+(\S+)`)
var rlsOn = regexp.MustCompile(`(?i)alter table\s+(only\s+)?(\S+)\s+enable row level security`)

func stripGnomon(post string) string {
	var stmts []string
	userPolicy := map[string]bool{}
	for _, st := range SplitSQL(post) {
		h := StatementHead(st)
		if strings.Contains(h, "gnomon_") || strings.Contains(h, "_gnomon.") {
			continue
		}
		if m := policyOn.FindStringSubmatch(h); m != nil {
			userPolicy[m[1]] = true
		}
		stmts = append(stmts, st)
	}
	var keep []string
	for _, st := range stmts {
		if m := rlsOn.FindStringSubmatch(StatementHead(st)); m != nil && !userPolicy[m[2]] {
			continue
		}
		keep = append(keep, st)
	}
	return strings.Join(keep, "\n\n") + "\n"
}

// loadCopyScript runs a script of COPY ... FROM stdin blocks and statements.
func loadCopyScript(ctx context.Context, c *pgx.Conn, script string) error {
	for script != "" {
		i := strings.Index(script, "COPY ")
		if i < 0 {
			if strings.TrimSpace(script) != "" {
				if _, err := c.Exec(ctx, script); err != nil {
					return err
				}
			}
			return nil
		}
		if strings.TrimSpace(script[:i]) != "" {
			if _, err := c.Exec(ctx, script[:i]); err != nil {
				return err
			}
		}
		script = script[i:]
		nl := strings.Index(script, "\n")
		cmd := strings.TrimSuffix(strings.TrimSpace(script[:nl]), ";")
		end := strings.Index(script, "\n\\.\n")
		if end < 0 {
			return fmt.Errorf("unterminated COPY block")
		}
		body := script[nl+1 : end+1]
		if _, err := c.PgConn().CopyFrom(ctx, strings.NewReader(body), strings.Replace(cmd, "FROM stdin", "FROM STDIN", 1)); err != nil {
			return fmt.Errorf("%s: %w", cmd, err)
		}
		script = script[end+4:]
	}
	return nil
}

func quoteIdent(s string) string { return `"` + strings.ReplaceAll(s, `"`, `""`) + `"` }
func quoteLiteral(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}
