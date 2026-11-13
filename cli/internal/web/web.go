// Package web is gnomon serve: the review app, its JSON API (/api/v1) and
// /metrics, behind one listener.
//
// Identity: a trusted proxy's header (--auth header:X-Forwarded-User, with an optional role map)
// for deployments behind single sign-on, or a database login form for local use. The server logs
// in as one role that is a member of every role it may act as, and runs each request as the
// person's role (SET LOCAL ROLE inside a transaction): every check in the database (authors cannot
// approve, confined roles cannot merge, branch access lists) applies to the person, not the
// server. Writes need a CSRF token. The server never needs a superuser login.
package web

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/bitsinfra/gnomon/cli/internal/gn"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed templates
var templateFS embed.FS

// Config of the app.
type Config struct {
	DSN     string
	Auth    string // "login" or "header:<Header-Name>"
	RoleMap string // file of "user role" lines (header auth)
	Version string
	BaseURL string
}

// App is the review app's handler.
type App struct {
	cfg     Config
	pool    *pgxpool.Pool
	header  string
	roles   map[string]string
	tpl     *template.Template
	mux     *http.ServeMux
	mu      sync.Mutex
	session map[string]*session
}

type session struct {
	role    string
	csrf    string
	expires time.Time
}

type pageData struct {
	Title   string
	Who     string
	CSRF    string
	Version string
	Error   string
	Notice  string
	D       map[string]any
}

// New connects the app's pool and builds its routes.
func New(ctx context.Context, cfg Config) (*App, error) {
	dsn := cfg.DSN
	if dsn == "" {
		dsn = gn.DefaultDSN()
	}
	pc, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	pc.ConnConfig.RuntimeParams["application_name"] = "gnomon-serve"
	pool, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		return nil, err
	}
	a := &App{cfg: cfg, pool: pool, session: map[string]*session{}, roles: map[string]string{}}
	if h, ok := strings.CutPrefix(cfg.Auth, "header:"); ok {
		a.header = h
		if cfg.RoleMap != "" {
			f, err := os.Open(cfg.RoleMap)
			if err != nil {
				return nil, err
			}
			sc := bufio.NewScanner(f)
			for sc.Scan() {
				fields := strings.Fields(sc.Text())
				if len(fields) == 2 && !strings.HasPrefix(fields[0], "#") {
					a.roles[fields[0]] = fields[1]
				}
			}
			f.Close()
		}
	} else if cfg.Auth != "" && cfg.Auth != "login" {
		return nil, fmt.Errorf("--auth is login or header:<name>, not %q", cfg.Auth)
	}
	funcs := template.FuncMap{
		"json": func(v any) string {
			if v == nil {
				return ""
			}
			if s, ok := v.(string); ok {
				return s
			}
			b, _ := json.Marshal(v)
			return string(b)
		},
		// (links take values as they are: html/template escapes them for the URL's query)
		"cell": gn.Cell,
		"eq":   func(a, b any) bool { return fmt.Sprint(a) == fmt.Sprint(b) },
		"truthy": func(v any) bool {
			b, ok := v.(bool)
			return ok && b
		},
	}
	a.tpl, err = template.New("").Funcs(funcs).ParseFS(templateFS, "templates/*.html")
	if err != nil {
		return nil, err
	}
	a.routes()
	return a, nil
}

func (a *App) ServeHTTP(w http.ResponseWriter, r *http.Request) { a.mux.ServeHTTP(w, r) }

// ---- identity

func randHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// who is the request's database role ("" = not signed in) and its CSRF token.
func (a *App) who(r *http.Request) (string, string) {
	if a.header != "" {
		u := r.Header.Get(a.header)
		if u == "" {
			return "", ""
		}
		role := u
		if m, ok := a.roles[u]; ok {
			role = m
		}
		return role, a.csrfFor(role)
	}
	ck, err := r.Cookie("gnomon_session")
	if err != nil {
		return "", ""
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	s, ok := a.session[ck.Value]
	if !ok || time.Now().After(s.expires) {
		return "", ""
	}
	return s.role, s.csrf
}

// With header auth the CSRF token is derived per role and process (the proxy carries identity).
func (a *App) csrfFor(role string) string {
	a.mu.Lock()
	defer a.mu.Unlock()
	k := "hdr:" + role
	s, ok := a.session[k]
	if !ok {
		s = &session{role: role, csrf: randHex(16), expires: time.Now().Add(24 * time.Hour)}
		a.session[k] = s
	}
	return s.csrf
}

func (a *App) login(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		a.render(w, r, "login", "Sign in", nil, "")
		return
	}
	user, pass := r.FormValue("user"), r.FormValue("password")
	cfg := a.pool.Config().ConnConfig.Copy()
	cfg.User, cfg.Password = user, pass
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	c, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		a.render(w, r, "login", "Sign in", nil, "sign-in failed: "+strings.SplitN(gn.PgError(err), "\n", 2)[0])
		return
	}
	c.Close(ctx)
	// the server must be able to act as this role
	conn, err := a.pool.Acquire(ctx)
	if err == nil {
		var ok bool
		_ = conn.QueryRow(ctx, "select pg_has_role(current_user, $1, 'member')", user).Scan(&ok)
		conn.Release()
		if !ok {
			a.render(w, r, "login", "Sign in", nil, "gnomon serve cannot act as "+user+": grant "+user+" to the server's login")
			return
		}
	}
	id := randHex(24)
	a.mu.Lock()
	a.session[id] = &session{role: user, csrf: randHex(16), expires: time.Now().Add(12 * time.Hour)}
	a.mu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: "gnomon_session", Value: id, Path: "/", HttpOnly: true, SameSite: http.SameSiteLaxMode, MaxAge: 12 * 3600})
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (a *App) logout(w http.ResponseWriter, r *http.Request) {
	if ck, err := r.Cookie("gnomon_session"); err == nil {
		a.mu.Lock()
		delete(a.session, ck.Value)
		a.mu.Unlock()
	}
	http.SetCookie(w, &http.Cookie{Name: "gnomon_session", Value: "", Path: "/", MaxAge: -1})
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

// ---- database access, as the person

// as runs fn in a transaction as the request's role. Read handlers run read-only.
func (a *App) as(ctx context.Context, role string, write bool, fn func(tx pgx.Tx) error) error {
	conn, err := a.pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	opts := pgx.TxOptions{}
	if !write {
		opts.AccessMode = pgx.ReadOnly
	}
	tx, err := conn.BeginTx(ctx, opts)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, "select set_config('role', $1, true), set_config('statement_timeout', '30000', true)", role); err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func rows(ctx context.Context, tx pgx.Tx, sql string, args ...any) ([]map[string]any, error) {
	res, err := gn.Query(ctx, tx.Conn(), sql, args...)
	if err != nil {
		return nil, err
	}
	if res.Maps == nil {
		return []map[string]any{}, nil
	}
	return res.Maps, nil
}

func one(ctx context.Context, tx pgx.Tx, sql string, args ...any) (any, error) {
	res, err := gn.Query(ctx, tx.Conn(), sql, args...)
	if err != nil {
		return nil, err
	}
	if len(res.Rows) == 0 {
		return nil, nil
	}
	return res.Rows[0][0], nil
}

func opt(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// ---- rendering

func (a *App) render(w http.ResponseWriter, r *http.Request, page, title string, d map[string]any, errMsg string) {
	role, csrf := a.who(r)
	pd := pageData{Title: title, Who: role, CSRF: csrf, Version: a.cfg.Version, Error: errMsg, D: d, Notice: r.URL.Query().Get("notice")}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'")
	if err := a.tpl.ExecuteTemplate(w, page, pd); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

// page wraps a read handler: signed in, read-only, errors on the page.
func (a *App) page(name, title string, fn func(ctx context.Context, tx pgx.Tx, r *http.Request) (map[string]any, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		role, _ := a.who(r)
		if role == "" {
			a.signin(w, r)
			return
		}
		var d map[string]any
		err := a.as(r.Context(), role, false, func(tx pgx.Tx) error {
			var e error
			d, e = fn(r.Context(), tx, r)
			return e
		})
		msg := ""
		if err != nil {
			msg = gn.PgError(err)
		}
		a.render(w, r, name, title, d, msg)
	}
}

func (a *App) signin(w http.ResponseWriter, r *http.Request) {
	if a.header != "" {
		http.Error(w, "no identity: the proxy must set "+a.header, http.StatusUnauthorized)
		return
	}
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

// action wraps a write: POST, signed in, CSRF token, then a redirect with a notice or the error.
func (a *App) action(fn func(ctx context.Context, tx pgx.Tx, r *http.Request) (string, string, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		role, csrf := a.who(r)
		if role == "" {
			a.signin(w, r)
			return
		}
		if subtle.ConstantTimeCompare([]byte(r.FormValue("csrf")), []byte(csrf)) != 1 || csrf == "" {
			http.Error(w, "bad or missing CSRF token", http.StatusForbidden)
			return
		}
		var back, notice string
		err := a.as(r.Context(), role, true, func(tx pgx.Tx) error {
			var e error
			back, notice, e = fn(r.Context(), tx, r)
			return e
		})
		if back == "" {
			back = r.Referer()
			if back == "" {
				back = "/"
			}
		}
		u, _ := url.Parse(back)
		q := u.Query()
		if err != nil {
			q.Set("notice", "refused: "+strings.SplitN(gn.PgError(err), "\n", 2)[0])
		} else {
			q.Set("notice", notice)
		}
		u.RawQuery = q.Encode()
		http.Redirect(w, r, u.String(), http.StatusSeeOther)
	}
}

// ---- routes

func (a *App) routes() {
	m := http.NewServeMux()
	a.mux = m
	m.HandleFunc("/login", a.login)
	m.HandleFunc("/logout", a.logout)
	m.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { fmt.Fprintln(w, "ok") })
	m.HandleFunc("/metrics", a.metrics)

	m.HandleFunc("/", a.page("branches", "Branches", func(ctx context.Context, tx pgx.Tx, r *http.Request) (map[string]any, error) {
		if r.URL.Path != "/" {
			return nil, fmt.Errorf("no page %s", r.URL.Path)
		}
		bs, err := rows(ctx, tx, `select b.name, b.parent, b.kind, b.status, b.created_by, b.created_at, b.behind, x.over_quota,
		         x.created_at + x.ttl as expires_at, (select count(*) from gnomon.warning w where w.branch = b.id) as warnings,
		         (select cr.id from gnomon.change_request cr where cr.branch = b.id and cr.status in ('open', 'approved') order by cr.id desc limit 1) as cr,
		         (select a.grp from gnomon.attempt a where a.branch = b.id limit 1) as attempt_group
		    from gnomon.branches b join gnomon.branch x on x.id = b.id order by coalesce(b.parent, ''), b.name`)
		if err != nil {
			return nil, err
		}
		return map[string]any{"branches": bs}, nil
	}))
	m.HandleFunc("/branch", a.page("branch", "Branch", a.branchPage))
	m.HandleFunc("/preview", a.page("preview", "Merge preview", func(ctx context.Context, tx pgx.Tx, r *http.Request) (map[string]any, error) {
		b := r.URL.Query().Get("branch")
		p, err := rows(ctx, tx, "select tbl::text as table, key, action, base, ours, theirs, result, conflicts from gnomon.merge_preview($1, $2)", b, opt(r.URL.Query().Get("into")))
		if err != nil {
			return map[string]any{"branch": b}, err
		}
		open, err := rows(ctx, tx, `select c.id, c.merge_id, c.tbl::text as table, c.key, c.col, c.kind, c.base, c.ours, c.theirs, c.resolution, c.value
		                              from gnomon.conflict c join gnomon.merge m on m.id = c.merge_id
		                             where m.source = (select id from gnomon.branch where name = $1) and m.status = 'conflicts' order by c.id`, b)
		if err != nil {
			return nil, err
		}
		return map[string]any{"branch": b, "into": r.URL.Query().Get("into"), "plan": p, "conflicts": open}, nil
	}))
	m.HandleFunc("/cr", a.page("crs", "Change requests", func(ctx context.Context, tx pgx.Tx, r *http.Request) (map[string]any, error) {
		id := r.URL.Query().Get("id")
		if id != "" {
			return nil, nil
		}
		cs, err := rows(ctx, tx, `select cr.id, b.name as branch, cr.title, cr.status, cr.opened_by, cr.opened_at, gnomon._cr_approved(cr.id) as approved
		                            from gnomon.change_request cr join gnomon.branch b on b.id = cr.branch order by cr.id desc limit 200`)
		return map[string]any{"requests": cs}, err
	}))
	m.HandleFunc("/cr/", a.page("cr", "Change request", func(ctx context.Context, tx pgx.Tx, r *http.Request) (map[string]any, error) {
		id, err := strconv.ParseInt(strings.TrimPrefix(r.URL.Path, "/cr/"), 10, 64)
		if err != nil {
			return nil, fmt.Errorf("no change request %q", r.URL.Path)
		}
		st, err := one(ctx, tx, "select gnomon.change_request_status($1)", id)
		if err != nil {
			return nil, err
		}
		d := map[string]any{"id": id, "status": st}
		if m, ok := st.(map[string]any); ok {
			sum, _ := rows(ctx, tx, "select tbl::text as table, inserts, updates, deletes from gnomon.diff_summary($1)", m["branch"])
			d["summary"] = sum
		}
		return d, nil
	}))
	m.HandleFunc("/row", a.page("row", "Row", func(ctx context.Context, tx pgx.Tx, r *http.Request) (map[string]any, error) {
		q := r.URL.Query()
		br := q.Get("branch")
		if br == "" {
			br = "main"
		}
		d := map[string]any{"table": q.Get("table"), "key": q.Get("key"), "branch": br}
		h, err := rows(ctx, tx, "select vkey, xid::text as xid, role, op, at, actor, reason, row_image, on_branch from gnomon.history($1, $2::jsonb, $3)", q.Get("table"), q.Get("key"), br)
		if err != nil {
			return d, err
		}
		b, err := rows(ctx, tx, "select col, value, xid::text as xid, role, actor, reason, at, on_branch from gnomon.blame($1, $2::jsonb, $3)", q.Get("table"), q.Get("key"), br)
		d["history"], d["blame"] = h, b
		return d, err
	}))
	m.HandleFunc("/log", a.page("log", "Log", func(ctx context.Context, tx pgx.Tx, r *http.Request) (map[string]any, error) {
		l, err := rows(ctx, tx, "select at, kind, on_branch, who, actor, reason, detail from gnomon.log($1, 200)", opt(r.URL.Query().Get("branch")))
		return map[string]any{"log": l}, err
	}))
	m.HandleFunc("/time", a.page("time", "Time travel", func(ctx context.Context, tx pgx.Tx, r *http.Request) (map[string]any, error) {
		q := r.URL.Query()
		d := map[string]any{"table": q.Get("table"), "branch": q.Get("branch"), "at": q.Get("at")}
		tabs, err := rows(ctx, tx, "select rel::text as table from gnomon.tracked order by 1")
		d["tables"] = tabs
		if err != nil || q.Get("table") == "" {
			return d, err
		}
		br := q.Get("branch")
		if br == "" {
			br = "main"
		}
		if _, err := tx.Exec(ctx, "select gnomon.begin($1, $2)", br, opt(q.Get("at"))); err != nil {
			return d, err
		}
		var rel string
		if err := tx.QueryRow(ctx, "select quote_ident(relname) from gnomon.tracked where rel = _gnomon.base_rel($1::regclass)", q.Get("table")).Scan(&rel); err != nil {
			return d, err
		}
		res, err := gn.Query(ctx, tx.Conn(), "select * from "+rel+" limit 200")
		if err == nil {
			d["columns"], d["rows"] = res.Columns, res.Rows
		}
		return d, err
	}))
	m.HandleFunc("/graph", a.page("graph", "Graph", a.graphPage))
	m.HandleFunc("/schema", a.page("schema", "Schema", func(ctx context.Context, tx pgx.Tx, r *http.Request) (map[string]any, error) {
		d, err := one(ctx, tx, "select gnomon.describe()")
		if err != nil {
			return nil, err
		}
		// schema versions: the open ones, and a branch's changes
		v, err := one(ctx, tx, `select coalesce(jsonb_agg(jsonb_build_object('id', sv.id, 'branch', b.name, 'status', sv.status, 'created_at', sv.created_at,
		    'changes', (select count(*) from gnomon.schema_change sc where sc.version = sv.id)) order by sv.id), '[]')
		  from gnomon.schema_version sv left join gnomon.branch b on b.id = sv.created_on_branch where sv.status = 'open'`)
		if err != nil {
			return nil, err
		}
		out := map[string]any{"describe": d, "versions": v, "branch": r.URL.Query().Get("branch")}
		if b := r.URL.Query().Get("branch"); b != "" {
			c, err := one(ctx, tx, `select coalesce(jsonb_agg(jsonb_build_object('version', version, 'op', op, 'table', tbl, 'detail', detail, 'sql', sql) order by version, seq), '[]')
			  from gnomon.schema_changes($1)`, b)
			if err != nil {
				return nil, err
			}
			out["changes"] = c
		}
		return out, nil
	}))

	// writes
	m.HandleFunc("/do/review", a.action(func(ctx context.Context, tx pgx.Tx, r *http.Request) (string, string, error) {
		id := r.FormValue("cr")
		_, err := tx.Exec(ctx, "select gnomon.review($1::bigint, $2, $3)", id, r.FormValue("verdict"), opt(r.FormValue("body")))
		return "/cr/" + id, "review recorded", err
	}))
	m.HandleFunc("/do/comment", a.action(func(ctx context.Context, tx pgx.Tx, r *http.Request) (string, string, error) {
		id := r.FormValue("cr")
		_, err := tx.Exec(ctx, "select gnomon.comment($1::bigint, $2, $3::regclass, $4::jsonb, $5)", id, r.FormValue("body"),
			opt(r.FormValue("table")), opt(r.FormValue("key")), opt(r.FormValue("col")))
		return "/cr/" + id, "comment added", err
	}))
	m.HandleFunc("/do/merge", a.action(func(ctx context.Context, tx pgx.Tx, r *http.Request) (string, string, error) {
		var mid int64
		err := tx.QueryRow(ctx, "select gnomon.merge($1, $2, 'atomic', null, null, $3::bigint, $4)", r.FormValue("branch"), opt(r.FormValue("into")),
			opt(r.FormValue("resume")), r.FormValue("close") == "on").Scan(&mid)
		if err != nil {
			return "", "", err
		}
		var status string
		_ = tx.QueryRow(ctx, "select status from gnomon.merge where id = $1", mid).Scan(&status)
		if status == "conflicts" {
			return "/preview?branch=" + url.QueryEscape(r.FormValue("branch")), fmt.Sprintf("merge %d stopped on conflicts: resolve them below, then resume", mid), nil
		}
		return "/log", fmt.Sprintf("merge %d %s", mid, status), nil
	}))
	m.HandleFunc("/do/resolve", a.action(func(ctx context.Context, tx pgx.Tx, r *http.Request) (string, string, error) {
		v := r.FormValue("value")
		if r.FormValue("choice") == "value" && !json.Valid([]byte(v)) {
			return "", "", errors.New("the value must be JSON (a string in double quotes, a number, an object)")
		}
		_, err := tx.Exec(ctx, "select gnomon.resolve($1::bigint, $2, $3::jsonb)", r.FormValue("id"), r.FormValue("choice"), opt(v))
		return "", "resolution recorded", err
	}))
	m.HandleFunc("/do/resolve-all", a.action(func(ctx context.Context, tx pgx.Tx, r *http.Request) (string, string, error) {
		_, err := tx.Exec(ctx, "select gnomon.resolve_all($1::bigint, $2)", r.FormValue("merge"), r.FormValue("choice"))
		return "", "all resolved", err
	}))
	m.HandleFunc("/do/undo", a.action(func(ctx context.Context, tx pgx.Tx, r *http.Request) (string, string, error) {
		var res string
		err := tx.QueryRow(ctx, "select gnomon.undo_merge($1::bigint)::text", r.FormValue("merge")).Scan(&res)
		return "/log", "undone: " + res, err
	}))
	m.HandleFunc("/do/open-cr", a.action(func(ctx context.Context, tx pgx.Tx, r *http.Request) (string, string, error) {
		var id int64
		err := tx.QueryRow(ctx, "select gnomon.open_change_request($1, $2, $3)", r.FormValue("branch"), r.FormValue("title"), opt(r.FormValue("body"))).Scan(&id)
		return fmt.Sprintf("/cr/%d", id), "change request opened", err
	}))
	m.HandleFunc("/do/graph-view", a.action(func(ctx context.Context, tx pgx.Tx, r *http.Request) (string, string, error) {
		_, err := tx.Exec(ctx, "select gnomon.save_graph_view($1, $2::regclass, $3::jsonb, $4, $5, $6, $7)", r.FormValue("name"), r.FormValue("table"),
			r.FormValue("key"), atoi(r.FormValue("depth"), 1), r.FormValue("branch"), r.FormValue("at"), opt(r.FormValue("note")))
		back := "/graph?" + url.Values{"table": {r.FormValue("table")}, "key": {r.FormValue("key")}, "branch": {r.FormValue("branch")},
			"at": {r.FormValue("at")}, "depth": {r.FormValue("depth")}}.Encode()
		return back, "saved view " + r.FormValue("name"), err
	}))
	m.HandleFunc("/do/graph-view-drop", a.action(func(ctx context.Context, tx pgx.Tx, r *http.Request) (string, string, error) {
		_, err := tx.Exec(ctx, "select gnomon.drop_graph_view($1)", r.FormValue("name"))
		return "/graph", "dropped view " + r.FormValue("name"), err
	}))
	m.HandleFunc("/do/drop", a.action(func(ctx context.Context, tx pgx.Tx, r *http.Request) (string, string, error) {
		_, err := tx.Exec(ctx, "select gnomon.drop_branch($1, true)", r.FormValue("branch"))
		return "/", "dropped " + r.FormValue("branch"), err
	}))

	// the undo button shows what an undo would hit before doing it: a dry run, rolled back
	m.HandleFunc("/undo-preview", a.page("undo", "Undo", func(ctx context.Context, tx pgx.Tx, r *http.Request) (map[string]any, error) {
		return map[string]any{"merge": r.URL.Query().Get("merge")}, nil
	}))
	m.HandleFunc("/api/v1/undo-preview", a.api(true, func(ctx context.Context, tx pgx.Tx, r *http.Request) (any, error) {
		if _, err := tx.Exec(ctx, "savepoint gn_undo_preview"); err != nil {
			return nil, err
		}
		var res string
		err := tx.QueryRow(ctx, "select gnomon.undo_merge($1::bigint)::text", r.URL.Query().Get("merge")).Scan(&res)
		_, _ = tx.Exec(ctx, "rollback to savepoint gn_undo_preview")
		if err != nil {
			return map[string]any{"would_fail": gn.PgError(err)}, nil
		}
		var v any
		_ = json.Unmarshal([]byte(res), &v)
		return map[string]any{"would_revert": v}, nil
	}))

	// the JSON API (for the pages' scripts, the Action and anything else)
	m.HandleFunc("/api/v1/branches", a.api(false, func(ctx context.Context, tx pgx.Tx, r *http.Request) (any, error) {
		return rows(ctx, tx, "select name, parent, kind, status, created_by, created_at, base, behind from gnomon.branches order by created_at desc")
	}))
	m.HandleFunc("/api/v1/summary", a.api(true, func(ctx context.Context, tx pgx.Tx, r *http.Request) (any, error) {
		return one(ctx, tx, "select gnomon.run_summary($1, false)", r.URL.Query().Get("branch"))
	}))
	m.HandleFunc("/api/v1/diff", a.api(false, func(ctx context.Context, tx pgx.Tx, r *http.Request) (any, error) {
		q := r.URL.Query()
		if t := q.Get("table"); t != "" {
			keys, err := one(ctx, tx, "select gnomon.diff_keys($1, $2, $3, $4::jsonb, $5)", q.Get("a"), opt(q.Get("b")), t, opt(q.Get("after")), atoi(q.Get("limit"), 100))
			if err != nil {
				return nil, err
			}
			kb, _ := json.Marshal(keys)
			d, err := rows(ctx, tx, "select tbl::text as table, key, kind, col, old, new from gnomon.diff($1, $2, array[$3::regclass], $4::jsonb)", q.Get("a"), opt(q.Get("b")), t, string(kb))
			return map[string]any{"keys": keys, "rows": d}, err
		}
		return rows(ctx, tx, "select tbl::text as table, key, kind, col, old, new from gnomon.diff($1, $2)", q.Get("a"), opt(q.Get("b")))
	}))
	m.HandleFunc("/api/v1/preview", a.api(false, func(ctx context.Context, tx pgx.Tx, r *http.Request) (any, error) {
		return rows(ctx, tx, "select tbl::text as table, key, action, base, ours, theirs, result, conflicts from gnomon.merge_preview($1, $2)", r.URL.Query().Get("branch"), opt(r.URL.Query().Get("into")))
	}))
	m.HandleFunc("/api/v1/requests", a.api(false, func(ctx context.Context, tx pgx.Tx, r *http.Request) (any, error) {
		return rows(ctx, tx, `select cr.id, b.name as branch, cr.title, cr.status, cr.opened_by, gnomon._cr_approved(cr.id) as approved
		                        from gnomon.change_request cr join gnomon.branch b on b.id = cr.branch order by cr.id desc`)
	}))
	m.HandleFunc("/api/v1/request", a.api(false, func(ctx context.Context, tx pgx.Tx, r *http.Request) (any, error) {
		return one(ctx, tx, "select gnomon.change_request_status($1::bigint)", r.URL.Query().Get("id"))
	}))
	m.HandleFunc("/api/v1/history", a.api(false, func(ctx context.Context, tx pgx.Tx, r *http.Request) (any, error) {
		q := r.URL.Query()
		br := q.Get("branch")
		if br == "" {
			br = "main"
		}
		return rows(ctx, tx, "select vkey, xid::text as xid, role, op, at, actor, reason, row_image, on_branch from gnomon.history($1, $2::jsonb, $3)", q.Get("table"), q.Get("key"), br)
	}))
	m.HandleFunc("/api/v1/log", a.api(false, func(ctx context.Context, tx pgx.Tx, r *http.Request) (any, error) {
		return rows(ctx, tx, "select at, kind, on_branch, who, actor, reason, detail from gnomon.log($1, $2)", opt(r.URL.Query().Get("branch")), atoi(r.URL.Query().Get("limit"), 50))
	}))
	m.HandleFunc("/api/v1/describe", a.api(false, func(ctx context.Context, tx pgx.Tx, r *http.Request) (any, error) {
		return one(ctx, tx, "select gnomon.describe()")
	}))
	m.HandleFunc("/api/v1/neighbors", a.api(false, a.neighborsAPI))
	m.HandleFunc("/api/v1/graph-views", a.api(false, func(ctx context.Context, tx pgx.Tx, r *http.Request) (any, error) {
		return rows(ctx, tx, "select name, tbl as table, key, depth, branch, at, note, created_by::text as created_by, created_at from gnomon.graph_views()")
	}))
	m.HandleFunc("/api/v1/review", a.apiWrite(func(ctx context.Context, tx pgx.Tx, r *http.Request) (any, error) {
		_, err := tx.Exec(ctx, "select gnomon.review($1::bigint, $2, $3)", r.FormValue("cr"), r.FormValue("verdict"), opt(r.FormValue("body")))
		return map[string]any{"ok": err == nil}, err
	}))
	m.HandleFunc("/api/v1/merge", a.apiWrite(func(ctx context.Context, tx pgx.Tx, r *http.Request) (any, error) {
		var mid int64
		if err := tx.QueryRow(ctx, "select gnomon.merge($1, $2)", r.FormValue("branch"), opt(r.FormValue("into"))).Scan(&mid); err != nil {
			return nil, err
		}
		return one(ctx, tx, "select jsonb_build_object('merge', id, 'status', status, 'stats', stats) from gnomon.merge where id = $1", mid)
	}))
}

func atoi(s string, def int) int {
	n, err := strconv.Atoi(s)
	if err != nil || n <= 0 {
		return def
	}
	return n
}

// api is a JSON read endpoint; volatile ones (that may compute through functions that write
// scratch state) run in a read-write transaction that is rolled back.
func (a *App) api(volatile bool, fn func(ctx context.Context, tx pgx.Tx, r *http.Request) (any, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		role, _ := a.who(r)
		if role == "" {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "sign in first"})
			return
		}
		var out any
		conn, err := a.pool.Acquire(r.Context())
		if err == nil {
			defer conn.Release()
			var tx pgx.Tx
			opts := pgx.TxOptions{AccessMode: pgx.ReadOnly}
			if volatile {
				opts.AccessMode = pgx.ReadWrite
			}
			tx, err = conn.BeginTx(r.Context(), opts)
			if err == nil {
				defer tx.Rollback(r.Context())
				if _, err = tx.Exec(r.Context(), "select set_config('role', $1, true), set_config('statement_timeout', '30000', true)", role); err == nil {
					out, err = fn(r.Context(), tx, r)
				}
			}
		}
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": gn.PgError(err), "sqlstate": gn.SQLState(err)})
			return
		}
		writeJSON(w, http.StatusOK, out)
	}
}

// apiWrite is a JSON write endpoint: POST, the CSRF token in X-CSRF-Token or the form.
func (a *App) apiWrite(fn func(ctx context.Context, tx pgx.Tx, r *http.Request) (any, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "POST only"})
			return
		}
		role, csrf := a.who(r)
		if role == "" {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "sign in first"})
			return
		}
		tok := r.Header.Get("X-CSRF-Token")
		if tok == "" {
			tok = r.FormValue("csrf")
		}
		if csrf == "" || subtle.ConstantTimeCompare([]byte(tok), []byte(csrf)) != 1 {
			writeJSON(w, http.StatusForbidden, map[string]any{"error": "bad or missing CSRF token"})
			return
		}
		var out any
		err := a.as(r.Context(), role, true, func(tx pgx.Tx) error {
			var e error
			out, e = fn(r.Context(), tx, r)
			return e
		})
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": gn.PgError(err), "sqlstate": gn.SQLState(err)})
			return
		}
		writeJSON(w, http.StatusOK, out)
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if v == nil {
		v = []any{}
	}
	_ = json.NewEncoder(w).Encode(v)
}

// metrics prints gnomon.metrics() in the Prometheus text format, as the server's own login (a
// member of gnomon_admin or pg_monitor).
func (a *App) metrics(w http.ResponseWriter, r *http.Request) {
	var s string
	if err := a.pool.QueryRow(r.Context(), "select gnomon.metrics_text($1)", r.URL.Query().Get("per_branch") == "1").Scan(&s); err != nil {
		http.Error(w, gn.PgError(err), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprint(w, s)
}

func (a *App) branchPage(ctx context.Context, tx pgx.Tx, r *http.Request) (map[string]any, error) {
	q := r.URL.Query()
	b := q.Get("name")
	d := map[string]any{"name": b, "kind": q.Get("kind"), "table": q.Get("table"), "keyq": q.Get("key")}
	sum, err := rows(ctx, tx, `select d.tbl::text as table, d.inserts, d.updates, d.deletes, t.outbox
	                             from gnomon.diff_summary($1) d join gnomon.tracked t on t.rel = d.tbl`, b)
	if err != nil {
		return d, err
	}
	d["summary"] = sum
	info, err := rows(ctx, tx, "select name, parent, kind, status, created_by, created_at, base, behind, note from gnomon.branches where name = $1", b)
	if err != nil {
		return d, err
	}
	if len(info) == 1 {
		d["info"] = info[0]
	}
	warn, _ := rows(ctx, tx, "select kind, tbl::text as table, key, col, at from gnomon.warning where branch = (select id from gnomon.branch where name = $1) order by id limit 50", b)
	d["warnings"] = warn
	// one table's rows, a page of keys at a time, filtered by kind and key
	t := q.Get("table")
	if t == "" && len(sum) > 0 {
		t = fmt.Sprint(sum[0]["table"])
	}
	d["table"] = t
	if t != "" {
		keys, err := one(ctx, tx, "select gnomon.diff_keys($1, null, $2::regclass, $3::jsonb, 50)", b, t, opt(q.Get("after")))
		if err != nil {
			return d, err
		}
		kb, _ := json.Marshal(keys)
		page, err := rows(ctx, tx, "select tbl::text as table, key, kind, col, old, new from gnomon.diff($1, null, array[$2::regclass], $3::jsonb)", b, t, string(kb))
		if err != nil {
			return d, err
		}
		var out []map[string]any
		for _, p := range page {
			if k := q.Get("kind"); k != "" && fmt.Sprint(p["kind"]) != k {
				continue
			}
			if kq := q.Get("key"); kq != "" && !strings.Contains(gn.Cell(p["key"]), kq) {
				continue
			}
			out = append(out, p)
		}
		d["rows"] = out
		if ks, ok := keys.([]any); ok && len(ks) == 50 {
			last, _ := json.Marshal(ks[len(ks)-1])
			d["next"] = string(last)
		}
		for _, s := range sum {
			if fmt.Sprint(s["table"]) == t && s["outbox"] == true {
				d["outbox"] = true
			}
		}
	}
	return d, nil
}

func (a *App) neighborsAPI(ctx context.Context, tx pgx.Tx, r *http.Request) (any, error) {
	q := r.URL.Query()
	br := q.Get("branch")
	if br == "" {
		br = "main"
	}
	if _, err := tx.Exec(ctx, "select gnomon.begin($1, $2)", br, opt(q.Get("at"))); err != nil {
		return nil, err
	}
	return rows(ctx, tx, "select level, rel::text as table, row_key as key, via, from_tbl::text as from_table, from_key, row_image from gnomon.neighbors($1, $2::jsonb, $3, 'both', 60)",
		q.Get("table"), q.Get("key"), atoi(q.Get("depth"), 1))
}

// graphPage lays the neighbors out in levels and draws them as SVG (no graph library).
func (a *App) graphPage(ctx context.Context, tx pgx.Tx, r *http.Request) (map[string]any, error) {
	q := r.URL.Query()
	d := map[string]any{"table": q.Get("table"), "key": q.Get("key"), "branch": q.Get("branch"), "at": q.Get("at"), "depth": atoi(q.Get("depth"), 1)}
	// saved views: each a link that shows it again
	views, err := rows(ctx, tx, "select name, tbl, key::text as key, depth, coalesce(branch, '') as branch, coalesce(at, '') as at, coalesce(note, '') as note, created_by::text as created_by from gnomon.graph_views()")
	if err != nil {
		return d, err
	}
	for _, v := range views {
		v["href"] = "/graph?" + url.Values{"table": {fmt.Sprint(v["tbl"])}, "key": {fmt.Sprint(v["key"])}, "branch": {fmt.Sprint(v["branch"])},
			"at": {fmt.Sprint(v["at"])}, "depth": {fmt.Sprint(v["depth"])}}.Encode()
	}
	d["views"] = views
	if q.Get("table") == "" {
		return d, nil
	}
	ns, err := a.neighborsAPI(ctx, tx, r)
	if err != nil {
		return d, err
	}
	list, _ := ns.([]map[string]any)
	changed := map[string]bool{}
	if br := q.Get("branch"); br != "" && br != "main" {
		ch, _ := rows(ctx, tx, "select distinct tbl::text as table, key from gnomon.diff($1)", br)
		for _, c := range ch {
			changed[fmt.Sprint(c["table"])+gn.Cell(c["key"])] = true
		}
	}
	type node struct {
		X, Y             int
		Label, Href, Cls string
	}
	type edge struct{ X1, Y1, X2, Y2 int }
	pos := map[string][2]int{}
	perLevel := map[int]int{}
	var nodes []node
	var edges []edge
	for _, n := range list {
		lvl := int(toF(n["level"]))
		i := perLevel[lvl]
		perLevel[lvl]++
		x, y := 30+lvl*230, 30+i*46
		id := fmt.Sprint(n["table"]) + gn.Cell(n["key"])
		pos[id] = [2]int{x, y}
		cls := "node"
		if changed[id] {
			cls = "node changed"
		}
		nodes = append(nodes, node{X: x, Y: y, Label: fmt.Sprintf("%v %s", n["table"], gn.Cell(n["key"])), Cls: cls,
			Href: "/graph?" + url.Values{"table": {fmt.Sprint(n["table"])}, "key": {gn.Cell(n["key"])}, "branch": {q.Get("branch")}, "at": {q.Get("at")}}.Encode()})
		if n["from_table"] != nil {
			if p, ok := pos[fmt.Sprint(n["from_table"])+gn.Cell(n["from_key"])]; ok {
				edges = append(edges, edge{p[0] + 190, p[1] + 14, x, y + 14})
			}
		}
	}
	h := 60
	for _, c := range perLevel {
		h = max(h, 40+c*46)
	}
	d["nodes"], d["edges"], d["height"], d["width"] = nodes, edges, h, 60+len(perLevel)*230
	d["list"] = list
	return d, nil
}

func toF(v any) float64 {
	switch x := v.(type) {
	case int32:
		return float64(x)
	case int64:
		return float64(x)
	case float64:
		return x
	case int:
		return float64(x)
	}
	f, _ := strconv.ParseFloat(fmt.Sprint(v), 64)
	return f
}
