// Package mcp is gnomon's Model Context Protocol server: JSON-RPC 2.0 over stdio, and stateless
// Streamable HTTP.
//
// It runs as a role set up with gnomon.confine (stdio: the DSN's role; HTTP: the agent role a
// bearer token maps to, taken with SET LOCAL ROLE per call): the database, not this server,
// decides what the agent may do. The tools only make the common things convenient; an agent that
// sends arbitrary SQL through `execute` still cannot merge, undo on main or write main.
//
// Every call is one transaction with a statement timeout, a lock timeout and an idle timeout.
// Writes are attributed (gnomon.note: the agent, the call's reason, the run, the call and the
// tool), so history, blame and the log show them. Reads go through a cursor and fetch one row past
// the limit, so a cut result says so. Each call is recorded with gnomon.record_call when the role
// may (an agent, or gnomon's server): reads with the coordinate they ran at and a digest of their
// rows, so `gnomon agent replay` can check what the agent saw.
//
// Protocol revisions: 2026-07-28 (stateless: no initialize, the version in each request's _meta,
// server/discover) and 2025-06-18 (initialize).
package mcp

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/bitsinfra/gnomon/cli/internal/gn"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

const (
	protoStateless = "2026-07-28"
	protoLegacy    = "2025-06-18"
	metaVersion    = "io.modelcontextprotocol/protocolVersion"
	metaServer     = "io.modelcontextprotocol/serverInfo"
	metaClient     = "io.modelcontextprotocol/clientInfo"
)

var supported = []string{protoStateless, "2025-11-25", protoLegacy}

// Server serves one agent: a database connection (stdio) or a role per call (HTTP).
type Server struct {
	DSN     string
	Version string
	// Agent names the caller in attribution and in the run record ("" = the role's agent name, or "mcp").
	Agent string
	// RequireReason refuses writes whose call carries no reason.
	RequireReason bool
	// Timeouts per call: statement, lock, idle in transaction.
	StatementTimeout, LockTimeout, IdleTimeout time.Duration
	// Result caps (an agent's budget overrides them when smaller).
	MaxRows, MaxBytes int
	// Run identifies this session's calls in the run record; empty: a random one.
	Run string
	// Role is SET LOCAL in every call (HTTP); empty: the connection's own role.
	Role string

	mu        sync.Mutex
	conn      *pgx.Conn
	callSeq   int
	record    int // 0 unknown, 1 on, -1 off (the role may not record)
	callTimes []time.Time
	budget    *budget
	client    string
	cmodule   *bool
}

type budget struct{ calls, rows, bytes int }

type request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

type tool struct {
	Name        string         `json:"name"`
	Title       string         `json:"title,omitempty"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
	Annotations map[string]any `json:"annotations,omitempty"`
	write       bool           // runs in a write transaction, attributed
	run         func(ctx context.Context, c *call) (any, error)
}

// takesBranch: the tool works on one branch that a call may leave out. (log without one lists
// every branch, conflicts without one are a merge's, and drop_branch never drops by default.)
func (t *tool) takesBranch() bool {
	switch t.Name {
	case "log", "conflicts", "drop_branch":
		return false
	}
	props, _ := t.InputSchema["properties"].(map[string]any)
	_, ok := props["branch"]
	return ok
}

// home is the open branch the calling role is assigned to (gnomon agent create, gnomon.assign),
// or "" (main). It reads in a savepoint, so a database without assignments leaves the call as it was.
func (s *Server) home(ctx context.Context, tx pgx.Tx) string {
	sp, err := tx.Begin(ctx)
	if err != nil {
		return ""
	}
	defer sp.Rollback(ctx)
	var b *string
	if err := sp.QueryRow(ctx, `select b.name from gnomon.assignment a join gnomon.branch b on b.id = a.branch
	                             where a.role = current_user and a.db = current_database() and b.status = 'open'`).Scan(&b); err != nil || b == nil {
		return ""
	}
	return *b
}

func obj(props map[string]any, required ...string) map[string]any {
	if required == nil {
		required = []string{}
	}
	return map[string]any{"type": "object", "properties": props, "required": required}
}

func str(desc string) map[string]any { return map[string]any{"type": "string", "description": desc} }
func boolean(desc string) map[string]any {
	return map[string]any{"type": "boolean", "description": desc}
}
func integer(desc string) map[string]any {
	return map[string]any{"type": "integer", "description": desc}
}
func jsonv(desc string) map[string]any { return map[string]any{"description": desc} }

var reasonProp = str("why: kept with the change in history, blame and the log")

func ro(idempotent bool) map[string]any {
	return map[string]any{"readOnlyHint": true, "idempotentHint": idempotent, "openWorldHint": false}
}
func rw(destructive bool) map[string]any {
	return map[string]any{"readOnlyHint": false, "destructiveHint": destructive, "openWorldHint": false}
}

// The tools, sorted by name when listed (a deterministic order).
var tools = []tool{
	{Name: "describe", Title: "Describe the database", Annotations: ro(true),
		Description: "Tables you can read, their columns, keys and foreign keys both ways, which are tracked (branch-writable), protected, outboxes or action tables, masked columns, row estimates, and your session: branch, base, write rights, limits. Call it first.",
		InputSchema: obj(map[string]any{"schema": str("one schema; default every schema on the path"), "branch": str("branch to describe the session on")}), run: describeTool},
	{Name: "status", Title: "Where am I", Annotations: ro(true),
		Description: "The branch, whether reads are routed to it, its changes, how far main has moved, warnings, its change request and quota.",
		InputSchema: obj(map[string]any{"branch": str("branch")}), run: statusTool},
	{Name: "list_branches", Title: "List branches", Annotations: ro(true),
		Description: "List gnomon branches (name, parent, kind, status, base, how far behind main).",
		InputSchema: obj(map[string]any{}), run: listBranches},
	{Name: "create_branch", Title: "Create a branch", Annotations: rw(false), write: true,
		Description: "Create a branch of the database. Writes on a branch never touch main until a person (or a merge policy) merges it.",
		InputSchema: obj(map[string]any{"name": str("branch name"), "parent": str("parent branch, default main"),
			"scratch": boolean("unlogged, swept after a TTL")}, "name"), run: createBranch},
	{Name: "query", Title: "Read with SQL", Annotations: ro(true),
		Description: "Run one read-only SQL statement on a branch (or main), optionally as of a past coordinate, tag or timestamp. Returns at most `limit` rows; `truncated` says when there were more (page with OFFSET or a key range).",
		InputSchema: obj(map[string]any{"sql": str("one SELECT statement"), "branch": str("branch; default: the one you are assigned, else main"),
			"as_of": str("coordinate, tag:<name> or timestamp"), "limit": integer("rows to return (default 200)")}, "sql"), run: query},
	{Name: "execute", Title: "Write with SQL", Annotations: rw(true), write: true,
		Description: "Run one SQL statement that writes, on a branch. Refused on main. Upserts (INSERT ... ON CONFLICT) need the C module on branches; write them as UPDATE then INSERT ... WHERE NOT EXISTS. Inserting into an action table sends nothing until a person merges.",
		InputSchema: obj(map[string]any{"sql": str("INSERT/UPDATE/DELETE"), "branch": str("branch to write"), "reason": reasonProp}, "sql", "branch"), run: execute},
	{Name: "dry_run", Title: "Try statements", Annotations: ro(false),
		Description: "Run statements on a throwaway copy of a branch and return their diff, the checks and any error; nothing is kept.",
		InputSchema: obj(map[string]any{"statements": map[string]any{"type": "array", "items": map[string]any{"type": "string"}}, "branch": str("branch; default: the one you are assigned, else main"),
			"checks": boolean("run the checks too (default true)")}, "statements"), run: dryRun},
	{Name: "diff", Title: "Diff", Annotations: ro(true),
		Description: "What a branch changed against its base, field by field (or between two refs).",
		InputSchema: obj(map[string]any{"branch": str("branch"), "against": str("optional second ref, e.g. main")}, "branch"), run: diff},
	{Name: "merge_preview", Title: "Preview a merge", Annotations: ro(true),
		Description: "What merging the branch would do, including conflicts. Changes nothing.",
		InputSchema: obj(map[string]any{"branch": str("branch"), "into": str("target, default the parent")}, "branch"), run: mergePreview},
	{Name: "request_merge", Title: "Ask for review", Annotations: rw(false), write: true,
		Description: "Open a change request so a person can review and merge the branch. Writing to the branch afterwards makes an approval stale.",
		InputSchema: obj(map[string]any{"branch": str("branch"), "title": str("title"), "body": str("description")}, "branch", "title"), run: requestMerge},
	{Name: "change_request_status", Title: "Review status", Annotations: ro(true),
		Description: "A change request's reviews (stale ones marked), comments anchored to rows, check results and merge state.",
		InputSchema: obj(map[string]any{"id": integer("change request id")}, "id"), run: crStatus},
	{Name: "run_checks", Title: "Run checks", Annotations: rw(false), write: true,
		Description: "Run the configured checks on a branch.",
		InputSchema: obj(map[string]any{"branch": str("branch")}, "branch"), run: runChecks},
	{Name: "history", Title: "Row history", Annotations: ro(true),
		Description: "Every version of one row of a tracked table, on main or a branch, with who, when and why.",
		InputSchema: obj(map[string]any{"table": str("table"), "key": jsonv("primary key, e.g. {\"id\": 3} (a bare value for a one-column key)"),
			"branch": str("branch; default: the one you are assigned, else main")}, "table", "key"), run: history},
	{Name: "blame", Title: "Blame", Annotations: ro(true),
		Description: "For each column of a row: who last changed it, when and why.",
		InputSchema: obj(map[string]any{"table": str("table"), "key": jsonv("primary key"), "branch": str("branch; default: the one you are assigned, else main")}, "table", "key"), run: blame},
	{Name: "log", Title: "Commit log", Annotations: ro(true),
		Description: "Commits, merges and undos, newest first.",
		InputSchema: obj(map[string]any{"branch": str("one branch"), "limit": integer("rows, default 50")}), run: logTool},
	{Name: "conflicts", Title: "Conflicts", Annotations: ro(true),
		Description: "Conflicts recorded by a merge, or by a rebase of a branch.",
		InputSchema: obj(map[string]any{"merge": integer("merge id"), "branch": str("branch (rebase conflicts)")}), run: conflicts},
	{Name: "resolve", Title: "Resolve a conflict", Annotations: rw(false), write: true,
		Description: "Record a resolution of a conflict: ours, theirs, base, or a value.",
		InputSchema: obj(map[string]any{"id": integer("conflict id"), "choice": str("ours|theirs|base|value"), "value": jsonv("the value, with choice=value")}, "id", "choice"), run: resolve},
	{Name: "rebase", Title: "Rebase", Annotations: rw(false), write: true,
		Description: "Carry a branch onto its parent's current state (what a stale-read warning asks for). dry_run shows what it would do.",
		InputSchema: obj(map[string]any{"branch": str("branch"), "dry_run": boolean("change nothing")}, "branch"), run: rebase},
	{Name: "stale_reads", Title: "Stale reads", Annotations: ro(true),
		Description: "Rows the branch read that main changed since (C module read sets).",
		InputSchema: obj(map[string]any{"branch": str("branch")}, "branch"), run: staleReads},
	{Name: "checkpoint", Title: "Checkpoint", Annotations: rw(false), write: true,
		Description: "Name the branch's state now, to rewind to later.",
		InputSchema: obj(map[string]any{"branch": str("branch"), "name": str("checkpoint name")}, "branch", "name"), run: checkpoint},
	{Name: "rewind", Title: "Rewind", Annotations: rw(true), write: true,
		Description: "Set every row the branch changed since a checkpoint back to its state there. Undoable.",
		InputSchema: obj(map[string]any{"branch": str("branch"), "to": str("checkpoint name"), "reason": reasonProp}, "branch", "to"), run: rewind},
	{Name: "revert", Title: "Revert rows", Annotations: rw(true), write: true,
		Description: "Set rows of a table on a branch to their state at a past moment (keys or a filter narrow it). Undoable; dry_run shows it.",
		InputSchema: obj(map[string]any{"branch": str("branch"), "table": str("table"), "at": str("coordinate, tag:<name> or timestamp"),
			"keys": jsonv("array of keys"), "filter": str("SQL condition on the table's columns"), "dry_run": boolean("change nothing"), "reason": reasonProp},
			"branch", "table", "at"), run: revert},
	{Name: "drop_branch", Title: "Drop a branch", Annotations: rw(true), write: true,
		Description: "Drop one of your branches and what it holds.",
		InputSchema: obj(map[string]any{"branch": str("branch")}, "branch"), run: dropBranch},
	{Name: "neighbors", Title: "Related rows", Annotations: ro(true),
		Description: "Rows related to one row through foreign keys (both ways) and declared links, level by level, on a branch.",
		InputSchema: obj(map[string]any{"table": str("table"), "key": jsonv("primary key"), "depth": integer("levels, default 1"),
			"branch": str("branch; default: the one you are assigned, else main"), "max_rows": integer("cap, default 100")}, "table", "key"), run: neighbors},
	{Name: "impact", Title: "Impact of a branch", Annotations: ro(true),
		Description: "A branch's changes as a graph: the changed rows, how they connect, and the rows around them.",
		InputSchema: obj(map[string]any{"branch": str("branch")}, "branch"), run: impact},
	{Name: "done", Title: "Say you are done", Annotations: rw(false), write: true,
		Description: "Say the work on a branch is finished: opens (or comments on) its change request for a person to review.",
		InputSchema: obj(map[string]any{"branch": str("branch"), "summary": str("what you did and why")}, "branch", "summary"), run: done},
}

func init() {
	sort.Slice(tools, func(i, j int) bool { return tools[i].Name < tools[j].Name })
}

// call is one tool call: its arguments and its transaction.
type call struct {
	s      *Server
	args   map[string]any
	tool   *tool
	tx     pgx.Tx
	branch string
	coord  string
	rows   int64
	digest string
	xid    string
	warn   []string
}

func (c *call) str(k string) string {
	if v, ok := c.args[k]; ok && v != nil {
		if s, ok := v.(string); ok {
			return s
		}
		b, _ := json.Marshal(v)
		return string(b)
	}
	return ""
}

func (c *call) intArg(k string, def int) int {
	if v, ok := c.args[k].(float64); ok && v > 0 {
		return int(v)
	}
	return def
}

func (c *call) boolArg(k string, def bool) bool {
	if v, ok := c.args[k].(bool); ok {
		return v
	}
	return def
}

func (c *call) jsonArg(k string) any {
	v, ok := c.args[k]
	if !ok || v == nil {
		return nil
	}
	b, _ := json.Marshal(v)
	return string(b)
}

func (c *call) rowsOf(sql string, args ...any) ([]map[string]any, error) {
	res, err := gn.Query(context.Background(), c.tx.Conn(), sql, args...)
	if err != nil {
		return nil, err
	}
	return res.Maps, nil
}

func (c *call) value(sql string, args ...any) (any, error) {
	res, err := gn.Query(context.Background(), c.tx.Conn(), sql, args...)
	if err != nil {
		return nil, err
	}
	if len(res.Rows) == 0 || len(res.Rows[0]) == 0 {
		return nil, nil
	}
	return res.Rows[0][0], nil
}

func (c *call) on(branch, asOf string) error {
	if branch == "" {
		branch = "main"
	}
	c.branch = branch
	var as any
	if asOf != "" {
		as = asOf
	}
	_, err := c.tx.Exec(context.Background(), "select gnomon.begin($1, $2)", branch, as)
	return err
}

func (s *Server) defaults() {
	if s.StatementTimeout == 0 {
		s.StatementTimeout = 30 * time.Second
	}
	if s.LockTimeout == 0 {
		s.LockTimeout = 5 * time.Second
	}
	if s.IdleTimeout == 0 {
		s.IdleTimeout = 60 * time.Second
	}
	if s.MaxRows == 0 {
		s.MaxRows = 200
	}
	if s.MaxBytes == 0 {
		s.MaxBytes = 1 << 20
	}
	if s.Run == "" {
		var b [6]byte
		_, _ = rand.Read(b[:])
		s.Run = "mcp-" + time.Now().UTC().Format("20060102-150405") + "-" + hex.EncodeToString(b[:])
	}
}

func (s *Server) db(ctx context.Context) (*pgx.Conn, error) {
	if s.conn != nil && !s.conn.IsClosed() {
		return s.conn, nil
	}
	c, err := gn.Connect(ctx, s.DSN)
	if err != nil {
		return nil, err
	}
	s.conn = c
	return c, nil
}

func ms(d time.Duration) string { return fmt.Sprintf("%d", d.Milliseconds()) }

// begin opens a call's transaction: the role, the timeouts, and for reads repeatable read (one
// snapshot, whose coordinate is recorded).
func (s *Server) begin(ctx context.Context, conn *pgx.Conn, write bool) (pgx.Tx, error) {
	opts := pgx.TxOptions{}
	if !write {
		opts.IsoLevel = pgx.RepeatableRead
		opts.AccessMode = pgx.ReadOnly
	}
	tx, err := conn.BeginTx(ctx, opts)
	if err != nil {
		return nil, err
	}
	if s.Role != "" {
		if _, err := tx.Exec(ctx, "select set_config('role', $1, true)", s.Role); err != nil {
			tx.Rollback(ctx)
			return nil, err
		}
	}
	for _, kv := range [][2]string{{"statement_timeout", ms(s.StatementTimeout)}, {"lock_timeout", ms(s.LockTimeout)},
		{"idle_in_transaction_session_timeout", ms(s.IdleTimeout)}} {
		if _, err := tx.Exec(ctx, "select set_config($1, $2, true)", kv[0], kv[1]); err != nil {
			tx.Rollback(ctx)
			return nil, err
		}
	}
	return tx, nil
}

// agentName is the name calls are attributed to.
func (s *Server) agentName(ctx context.Context, conn *pgx.Conn) string {
	if s.Agent != "" {
		return s.Agent
	}
	var n *string
	role := s.Role
	if role == "" {
		_ = conn.QueryRow(ctx, "select current_user").Scan(&role)
	}
	_ = conn.QueryRow(ctx, "select name from gnomon.agent where role = $1", role).Scan(&n)
	if n != nil {
		s.Agent = *n
	} else {
		s.Agent = "mcp:" + role
	}
	return s.Agent
}

func (s *Server) loadBudget(ctx context.Context, conn *pgx.Conn) {
	if s.budget != nil {
		return
	}
	s.budget = &budget{}
	role := s.Role
	if role == "" {
		_ = conn.QueryRow(ctx, "select current_user").Scan(&role)
	}
	var c, r, b *int32
	if err := conn.QueryRow(ctx, "select calls_per_minute, max_result_rows, max_result_bytes from gnomon.agent where role = $1", role).Scan(&c, &r, &b); err == nil {
		if c != nil {
			s.budget.calls = int(*c)
		}
		if r != nil {
			s.budget.rows = int(*r)
		}
		if b != nil {
			s.budget.bytes = int(*b)
		}
	}
}

func (s *Server) maxRows(asked int) int {
	n := asked
	if n <= 0 {
		n = s.MaxRows
	}
	if s.budget != nil && s.budget.rows > 0 && s.budget.rows < n {
		n = s.budget.rows
	}
	return n
}

func (s *Server) maxBytes() int {
	if s.budget != nil && s.budget.bytes > 0 && s.budget.bytes < s.MaxBytes {
		return s.budget.bytes
	}
	return s.MaxBytes
}

// rateOK keeps calls per minute within the agent's budget.
func (s *Server) rateOK() bool {
	if s.budget == nil || s.budget.calls <= 0 {
		return true
	}
	now := time.Now()
	keep := s.callTimes[:0]
	for _, t := range s.callTimes {
		if now.Sub(t) < time.Minute {
			keep = append(keep, t)
		}
	}
	s.callTimes = keep
	if len(s.callTimes) >= s.budget.calls {
		return false
	}
	s.callTimes = append(s.callTimes, now)
	return true
}

var forUpdate = regexp.MustCompile(`(?i)\bfor\s+(no\s+key\s+)?(update|share)\b`)

// runTool runs one tool call end to end and returns the MCP result.
func (s *Server) runTool(ctx context.Context, t *tool, args map[string]any) map[string]any {
	s.defaults()
	conn, err := s.db(ctx)
	if err != nil {
		return toolError(err, "")
	}
	s.loadBudget(ctx, conn)
	if !s.rateOK() {
		return toolError(fmt.Errorf("over budget: %d calls per minute [gnomon:agent_budget]", s.budget.calls), "")
	}
	s.callSeq++
	c := &call{s: s, args: args, tool: t}
	if t.write && s.RequireReason && c.str("reason") == "" && (t.Name == "execute" || t.Name == "revert" || t.Name == "rewind") {
		return toolError(errors.New("this server requires a reason with every write: pass `reason`"), "")
	}
	tx, err := s.begin(ctx, conn, t.write)
	if err != nil {
		return toolError(err, "")
	}
	c.tx = tx
	// a call that names no branch works on the role's assigned branch, as its own sessions do
	if t.takesBranch() && c.str("branch") == "" {
		if h := s.home(ctx, tx); h != "" {
			args["branch"] = h
		}
	}
	if t.write {
		meta, _ := json.Marshal(map[string]any{"run": s.Run, "call": s.callSeq, "tool": t.Name, "client": s.client})
		if _, err := tx.Exec(ctx, "select gnomon.note($1, $2, $3::jsonb)", s.agentName(ctx, conn), c.str("reason"), string(meta)); err != nil {
			tx.Rollback(ctx)
			return s.fail(ctx, conn, c, err)
		}
	} else {
		_ = tx.QueryRow(ctx, "select case when pg_is_in_recovery() then null else gnomon.coordinate_text() end").Scan(&c.coord)
	}
	out, err := t.run(ctx, c)
	if err == nil && t.write {
		var x *string
		_ = tx.QueryRow(ctx, "select pg_current_xact_id_if_assigned()::text").Scan(&x)
		if x != nil {
			c.xid = *x
		}
	}
	if err != nil {
		tx.Rollback(ctx)
		return s.fail(ctx, conn, c, err)
	}
	c.warnings(ctx)
	if t.write {
		err = tx.Commit(ctx)
	} else {
		err = tx.Rollback(ctx)
	}
	if err != nil {
		return s.fail(ctx, conn, c, err)
	}
	s.recordCall(ctx, conn, c, "")
	body := map[string]any{"result": out}
	if len(c.warn) > 0 {
		body["warnings"] = c.warn
	}
	text, _ := json.MarshalIndent(body, "", " ")
	return map[string]any{
		"content":           []map[string]any{{"type": "text", "text": string(text)}},
		"structuredContent": body,
		"isError":           false,
	}
}

// warnings for the call's branch: early conflict warnings and stale reads ("rebase"), and a
// FOR UPDATE that takes no lock in the SQL core.
func (c *call) warnings(ctx context.Context) {
	if c.branch == "" || c.branch == "main" {
		return
	}
	rows, err := c.rowsOf("select kind, tbl::text as table, key from gnomon.warning where branch = (select id from gnomon.branch where name = $1) order by id limit 20", c.branch)
	if err == nil {
		for _, r := range rows {
			c.warn = append(c.warn, fmt.Sprintf("%v on %v %v: main changed what this branch holds; consider the rebase tool", r["kind"], r["table"], gn.Cell(r["key"])))
		}
	}
	if sql := c.str("sql"); sql != "" && forUpdate.MatchString(sql) && !c.s.cModule(ctx, c) {
		c.warn = append(c.warn, "SELECT ... FOR UPDATE takes no row lock on a branch in gnomon's SQL core (the C module is not loaded) [gnomon:sql_only_dml]")
	}
}

func (s *Server) cModule(ctx context.Context, c *call) bool {
	if s.cmodule == nil {
		var v *string
		_ = c.tx.QueryRow(ctx, "select current_setting('gnomon.c_module', true)").Scan(&v)
		on := v != nil && *v == "on"
		s.cmodule = &on
	}
	return *s.cmodule
}

func (s *Server) fail(ctx context.Context, conn *pgx.Conn, c *call, err error) map[string]any {
	expl := ""
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		var e *string
		_ = conn.QueryRow(ctx, "select gnomon.explain_error($1, $2)", pe.Code, pe.Message+" "+pe.Hint).Scan(&e)
		if e != nil {
			expl = *e
		}
	}
	s.recordCall(ctx, conn, c, gn.PgError(err))
	return toolError(err, expl)
}

func toolError(err error, explanation string) map[string]any {
	msg := gn.PgError(err)
	body := map[string]any{"error": msg}
	if explanation != "" {
		msg += "\n" + explanation
		body["explanation"] = explanation
	}
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		body["sqlstate"] = pe.Code
	}
	return map[string]any{"content": []map[string]any{{"type": "text", "text": msg}}, "structuredContent": body, "isError": true}
}

func (s *Server) recordCall(ctx context.Context, conn *pgx.Conn, c *call, errText string) {
	if s.record < 0 || c == nil {
		return
	}
	args, _ := json.Marshal(c.args)
	var xid, coord, digest, e any
	if c.xid != "" {
		xid = c.xid
	}
	if c.coord != "" {
		coord = c.coord
	}
	if c.digest != "" {
		digest = c.digest
	}
	if errText != "" {
		e = errText
	}
	var br any
	if c.branch != "" {
		br = c.branch
	}
	q := "select gnomon.record_call($1, $2, $3::jsonb, $4, $5, $6::xid8, $7, $8, $9, $10)"
	var err error
	if s.Role != "" {
		tx, terr := conn.Begin(ctx)
		if terr != nil {
			return
		}
		_, _ = tx.Exec(ctx, "select set_config('role', $1, true)", s.Role)
		_, err = tx.Exec(ctx, q, s.Run, c.tool.Name, string(args), br, coord, xid, c.rows, digest, e, s.Agent)
		if err == nil {
			err = tx.Commit(ctx)
		} else {
			tx.Rollback(ctx)
		}
	} else {
		_, err = conn.Exec(ctx, q, s.Run, c.tool.Name, string(args), br, coord, xid, c.rows, digest, e, s.Agent)
	}
	if err != nil && gn.SQLState(err) == "42501" {
		s.record = -1 // this role may not record: it is neither an agent nor gnomon's server
	} else if err == nil {
		s.record = 1
	}
}

func digest(rows []map[string]any) string {
	b, _ := json.Marshal(rows)
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

// ---- tools

func describeTool(ctx context.Context, c *call) (any, error) {
	if err := c.on(c.str("branch"), ""); err != nil {
		return nil, err
	}
	var sc any
	if s := c.str("schema"); s != "" {
		sc = s
	}
	return c.value("select gnomon.describe($1)", sc)
}

func statusTool(ctx context.Context, c *call) (any, error) {
	if err := c.on(c.str("branch"), ""); err != nil {
		return nil, err
	}
	return c.value("select gnomon.status()")
}

func listBranches(ctx context.Context, c *call) (any, error) {
	return c.rowsOf("select name, parent, kind, status, base, behind from gnomon.branches order by created_at")
}

func createBranch(ctx context.Context, c *call) (any, error) {
	kind := "logged"
	if c.boolArg("scratch", false) {
		kind = "scratch"
	}
	parent := c.str("parent")
	if parent == "" {
		parent = "main"
	}
	id, err := c.value("select gnomon.create_branch($1, $2, $3)", c.str("name"), parent, kind)
	if err != nil {
		return nil, err
	}
	c.branch = c.str("name")
	return map[string]any{"branch": c.str("name"), "id": id, "parent": parent}, nil
}

// query reads through a cursor: one row past the limit says the result was cut; a byte cap too.
func query(ctx context.Context, c *call) (any, error) {
	if err := c.on(c.str("branch"), c.str("as_of")); err != nil {
		return nil, err
	}
	limit := c.s.maxRows(c.intArg("limit", 0))
	sql := strings.TrimRight(strings.TrimSpace(c.str("sql")), ";")
	// (a cursor takes one SELECT, VALUES, TABLE or WITH query: a second statement is refused)
	// (the extended protocol, whatever the driver would pick: PostgreSQL refuses a second statement)
	if _, err := c.tx.Conn().PgConn().ExecParams(ctx, "declare gn_mcp_q no scroll cursor for "+sql, nil, nil, nil, nil).Close(); err != nil {
		return nil, err
	}
	res, err := gn.Query(ctx, c.tx.Conn(), fmt.Sprintf("fetch forward %d from gn_mcp_q", limit+1))
	if err != nil {
		return nil, err
	}
	truncated := false
	rows := res.Maps
	if len(rows) > limit {
		rows, truncated = rows[:limit], true
	}
	size, cut := 0, len(rows)
	for i, r := range rows {
		b, _ := json.Marshal(r)
		size += len(b)
		if size > c.s.maxBytes() {
			cut, truncated = i, true
			break
		}
	}
	rows = rows[:cut]
	if rows == nil {
		rows = []map[string]any{}
	}
	c.rows, c.digest = int64(len(rows)), digest(rows)
	out := map[string]any{"columns": res.Columns, "rows": rows, "truncated": truncated}
	if truncated {
		out["note"] = fmt.Sprintf("more rows than returned (limit %d rows, %d bytes); narrow the query or page with a key range", limit, c.s.maxBytes())
	}
	if c.coord != "" {
		out["coordinate"] = c.coord
	}
	return out, nil
}

func execute(ctx context.Context, c *call) (any, error) {
	b := c.str("branch")
	if b == "" || b == "main" {
		return nil, fmt.Errorf("execute writes branches only; create a branch first [gnomon:main_read_only]")
	}
	if err := c.on(b, ""); err != nil {
		return nil, err
	}
	if len(gn.SplitSQL(c.str("sql"))) > 1 {
		return nil, &pgconn.PgError{Code: "42601", Message: "one statement per call: this one holds several", Hint: "Split them into calls, or use dry_run for a sequence. [gnomon:one_statement]"}
	}
	res, err := gn.Query(ctx, c.tx.Conn(), c.str("sql"))
	if err != nil {
		return nil, err
	}
	c.rows = int64(len(res.Rows))
	out := map[string]any{"status": res.Tag}
	if len(res.Maps) > 0 {
		lim := c.s.maxRows(0)
		rows := res.Maps
		if len(rows) > lim {
			rows = rows[:lim]
			out["truncated"] = true
		}
		out["rows"] = rows
	}
	return out, nil
}

func dryRun(ctx context.Context, c *call) (any, error) {
	stmts := []string{}
	if a, ok := c.args["statements"].([]any); ok {
		for _, x := range a {
			stmts = append(stmts, fmt.Sprint(x))
		}
	}
	var br any
	if b := c.str("branch"); b != "" {
		br = b
		c.branch = b
	}
	return c.value("select gnomon.dry_run($1::text[], $2, $3)", stmts, br, c.boolArg("checks", true))
}

func diff(ctx context.Context, c *call) (any, error) {
	c.branch = c.str("branch")
	if other := c.str("against"); other != "" {
		return c.rowsOf("select tbl::text as table, key, kind, col, old, new from gnomon.diff($1, $2)", other, c.str("branch"))
	}
	return c.rowsOf("select tbl::text as table, key, kind, col, old, new from gnomon.diff($1)", c.str("branch"))
}

func mergePreview(ctx context.Context, c *call) (any, error) {
	c.branch = c.str("branch")
	var into any
	if v := c.str("into"); v != "" {
		into = v
	}
	return c.rowsOf("select tbl::text as table, key, action, conflicts, result from gnomon.merge_preview($1, $2)", c.str("branch"), into)
}

func requestMerge(ctx context.Context, c *call) (any, error) {
	c.branch = c.str("branch")
	var body any
	if b := c.str("body"); b != "" {
		body = b
	}
	id, err := c.value("select gnomon.open_change_request($1, $2, $3)", c.str("branch"), c.str("title"), body)
	if err != nil {
		return nil, err
	}
	return map[string]any{"change_request": id, "note": "a person with merge rights (or a merge policy) must approve and merge it"}, nil
}

func crStatus(ctx context.Context, c *call) (any, error) {
	return c.value("select gnomon.change_request_status($1)", c.intArg("id", 0))
}

func runChecks(ctx context.Context, c *call) (any, error) {
	c.branch = c.str("branch")
	return c.rowsOf("select check_name, passed, detail from gnomon.run_checks($1)", c.str("branch"))
}

func history(ctx context.Context, c *call) (any, error) {
	br := c.str("branch")
	if br == "" {
		br = "main"
	}
	c.branch = br
	return c.rowsOf("select vkey, xid::text, role, op, at, actor, reason, row_image, on_branch from gnomon.history($1, $2::jsonb, $3)",
		c.str("table"), c.jsonArg("key"), br)
}

func blame(ctx context.Context, c *call) (any, error) {
	br := c.str("branch")
	if br == "" {
		br = "main"
	}
	return c.rowsOf("select col, value, xid::text, role, actor, reason, at, on_branch from gnomon.blame($1, $2::jsonb, $3)",
		c.str("table"), c.jsonArg("key"), br)
}

func logTool(ctx context.Context, c *call) (any, error) {
	var br any
	if b := c.str("branch"); b != "" {
		br = b
	}
	return c.rowsOf("select at, kind, on_branch, who, actor, reason, detail from gnomon.log($1, $2)", br, c.intArg("limit", 50))
}

func conflicts(ctx context.Context, c *call) (any, error) {
	if b := c.str("branch"); b != "" {
		c.branch = b
		return c.rowsOf("select id, tbl::text as table, key, col, kind, base, ours, theirs, resolution from gnomon.conflict where branch = (select id from gnomon.branch where name = $1) order by id", b)
	}
	return c.rowsOf("select id, tbl::text as table, key, col, kind, base, ours, theirs, resolution, value from gnomon.conflict where merge_id = $1 order by id", c.intArg("merge", 0))
}

func resolve(ctx context.Context, c *call) (any, error) {
	if _, err := c.tx.Exec(ctx, "select gnomon.resolve($1, $2, $3::jsonb)", c.intArg("id", 0), c.str("choice"), c.jsonArg("value")); err != nil {
		return nil, err
	}
	return map[string]any{"resolved": c.intArg("id", 0)}, nil
}

func rebase(ctx context.Context, c *call) (any, error) {
	c.branch = c.str("branch")
	return c.value("select gnomon.rebase($1, null, $2)", c.str("branch"), c.boolArg("dry_run", false))
}

func staleReads(ctx context.Context, c *call) (any, error) {
	c.branch = c.str("branch")
	return c.rowsOf("select tbl::text as table, key, read_at from gnomon.stale_reads($1)", c.str("branch"))
}

func checkpoint(ctx context.Context, c *call) (any, error) {
	c.branch = c.str("branch")
	return c.value("select gnomon.checkpoint($1, $2)", c.str("name"), c.str("branch"))
}

func rewind(ctx context.Context, c *call) (any, error) {
	c.branch = c.str("branch")
	return c.value("select gnomon.rewind($1, $2)", c.str("branch"), c.str("to"))
}

func revert(ctx context.Context, c *call) (any, error) {
	b := c.str("branch")
	if b == "" || b == "main" {
		return nil, fmt.Errorf("revert from an agent writes branches only")
	}
	c.branch = b
	var filter any
	if f := c.str("filter"); f != "" {
		filter = f
	}
	return c.value("select gnomon.revert($1, $2, $3::jsonb, $4, null, $5, $6)", c.str("table"), c.str("at"), c.jsonArg("keys"), filter, b, c.boolArg("dry_run", false))
}

func dropBranch(ctx context.Context, c *call) (any, error) {
	if _, err := c.tx.Exec(ctx, "select gnomon.drop_branch($1, true)", c.str("branch")); err != nil {
		return nil, err
	}
	return map[string]any{"dropped": c.str("branch")}, nil
}

func neighbors(ctx context.Context, c *call) (any, error) {
	if err := c.on(c.str("branch"), ""); err != nil {
		return nil, err
	}
	return c.rowsOf("select level, rel::text as table, row_key as key, via, from_tbl::text as from_table, from_key, row_image from gnomon.neighbors($1, $2::jsonb, $3, 'both', $4)",
		c.str("table"), c.jsonArg("key"), c.intArg("depth", 1), c.intArg("max_rows", 100))
}

func impact(ctx context.Context, c *call) (any, error) {
	c.branch = c.str("branch")
	return c.value("select gnomon.impact($1)", c.str("branch"))
}

func done(ctx context.Context, c *call) (any, error) {
	if err := c.on(c.str("branch"), ""); err != nil {
		return nil, err
	}
	id, err := c.value("select gnomon.done($1)", c.str("summary"))
	if err != nil {
		return nil, err
	}
	return map[string]any{"change_request": id}, nil
}

// ---- protocol

const instructions = "Gnomon gives this database branches. Call describe first: its session is the branch your calls work " +
	"on when they name none (the branch you are assigned, or else main: then create a branch). Read it with query " +
	"and write it with execute (one statement each); inspect diff, merge_preview and run_checks; checkpoint before a risky " +
	"change and rewind if it goes wrong; then request_merge (or done) for a person to review. Main is read-only to you, " +
	"and inserting into an action table sends nothing until a person merges. Pass a reason with writes: it is kept in history."

func (s *Server) capabilities() map[string]any {
	return map[string]any{"tools": map[string]any{"listChanged": false}}
}

func (s *Server) serverInfo() map[string]any {
	return map[string]any{"name": "gnomon", "version": s.Version}
}

// handle answers one JSON-RPC request. Requests that carry a protocol version in _meta are the
// stateless revision; the others the initialize-based one.
func (s *Server) handle(ctx context.Context, req request) (any, *rpcError) {
	var p struct {
		Name      string         `json:"name"`
		Arguments map[string]any `json:"arguments"`
		Meta      map[string]any `json:"_meta"`
		Version   string         `json:"protocolVersion"`
		Client    map[string]any `json:"clientInfo"`
	}
	if len(req.Params) > 0 {
		_ = json.Unmarshal(req.Params, &p)
	}
	stateless := false
	if v, ok := p.Meta[metaVersion].(string); ok {
		stateless = true
		if !contains(supported, v) {
			return nil, &rpcError{-32022, "unsupported protocol version " + v, map[string]any{"supported": supported, "requested": v}}
		}
		if ci, ok := p.Meta[metaClient].(map[string]any); ok {
			s.client = fmt.Sprint(ci["name"])
		}
	}
	wrap := func(r map[string]any) map[string]any {
		if stateless {
			r["resultType"] = "complete"
			r["_meta"] = map[string]any{metaServer: s.serverInfo()}
		}
		return r
	}
	switch req.Method {
	case "server/discover":
		return wrap(map[string]any{"supportedVersions": supported, "capabilities": s.capabilities(),
			"serverInfo": s.serverInfo(), "instructions": instructions}), nil
	case "initialize":
		v := protoLegacy
		if contains(supported, p.Version) {
			v = p.Version
		}
		if p.Client != nil {
			s.client = fmt.Sprint(p.Client["name"])
		}
		return map[string]any{"protocolVersion": v, "capabilities": s.capabilities(), "serverInfo": s.serverInfo(), "instructions": instructions}, nil
	case "ping":
		return map[string]any{}, nil
	case "tools/list":
		r := map[string]any{"tools": tools}
		if stateless {
			r["ttlMs"] = 3600000
			r["cacheScope"] = "private"
		}
		return wrap(r), nil
	case "tools/call":
		for i := range tools {
			if tools[i].Name == p.Name {
				if p.Arguments == nil {
					p.Arguments = map[string]any{}
				}
				s.mu.Lock()
				res := s.runTool(ctx, &tools[i], p.Arguments)
				s.mu.Unlock()
				return wrap(res), nil
			}
		}
		return nil, &rpcError{-32602, "unknown tool " + p.Name, nil}
	}
	return nil, &rpcError{-32601, "method not found: " + req.Method, nil}
}

func contains(xs []string, x string) bool {
	for _, y := range xs {
		if y == x {
			return true
		}
	}
	return false
}

// Serve speaks MCP over r/w (stdio) until EOF.
func (s *Server) Serve(ctx context.Context, r io.Reader, w io.Writer) error {
	in := bufio.NewScanner(r)
	in.Buffer(make([]byte, 1<<20), 64<<20)
	enc := json.NewEncoder(w)
	for in.Scan() {
		line := strings.TrimSpace(in.Text())
		if line == "" {
			continue
		}
		var req request
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			_ = enc.Encode(response{JSONRPC: "2.0", ID: json.RawMessage("null"), Error: &rpcError{-32700, "parse error", nil}})
			continue
		}
		if len(req.ID) == 0 { // a notification
			continue
		}
		res, rerr := s.handle(ctx, req)
		if err := enc.Encode(response{JSONRPC: "2.0", ID: req.ID, Result: res, Error: rerr}); err != nil {
			return err
		}
	}
	if s.conn != nil {
		s.conn.Close(context.Background())
	}
	return in.Err()
}
