package mcp_test

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/bitsinfra/gnomon/cli/internal/mcp"
	"github.com/bitsinfra/gnomon/cli/internal/testdb"
)

type client struct {
	t   *testing.T
	in  io.WriteCloser
	out *bufio.Scanner
	id  int
}

func (c *client) call(method string, params any) map[string]any {
	c.t.Helper()
	c.id++
	req := map[string]any{"jsonrpc": "2.0", "id": c.id, "method": method}
	if params != nil {
		req["params"] = params
	}
	b, _ := json.Marshal(req)
	if _, err := fmt.Fprintf(c.in, "%s\n", b); err != nil {
		c.t.Fatal(err)
	}
	if !c.out.Scan() {
		c.t.Fatalf("no response to %s: %v", method, c.out.Err())
	}
	var resp map[string]any
	if err := json.Unmarshal(c.out.Bytes(), &resp); err != nil {
		c.t.Fatal(err)
	}
	if resp["error"] != nil {
		c.t.Fatalf("%s: %v", method, resp["error"])
	}
	return resp["result"].(map[string]any)
}

// tool calls a tool and returns (text, isError).
func (c *client) tool(name string, args map[string]any) (string, bool) {
	c.t.Helper()
	res := c.call("tools/call", map[string]any{"name": name, "arguments": args})
	content := res["content"].([]any)[0].(map[string]any)
	isErr, _ := res["isError"].(bool)
	return content["text"].(string), isErr
}

// The review flow: an agent branches, writes and requests a merge over MCP; a human
// reviews, merges, then undoes the merge. The agent's role cannot merge or write main, whatever
// SQL it sends.
func TestAgentFlow(t *testing.T) {
	dsn := testdb.New(t, t.Name())
	agent := fmt.Sprintf("cli_agent_%d", os.Getpid())
	testdb.Exec(t, dsn,
		"create table item (id int primary key, name text not null, qty int not null default 0)",
		"insert into item select g, 'item ' || g, 1 from generate_series(1, 5) g",
		"select gnomon.track('item')",
		"drop role if exists "+agent,
		"create role "+agent+" login",
		"grant select, insert, update, delete on item to "+agent,
		"select gnomon.confine('"+agent+"')")
	t.Cleanup(func() {
		testdb.Exec(t, dsn, "select gnomon.unconfine('"+agent+"')", "drop owned by "+agent)
		testdb.Exec(t, testdb.Base()+" dbname=postgres", "drop role if exists "+agent)
	})

	bin := filepath.Join(t.TempDir(), "gnomon")
	if out, err := exec.Command("go", "build", "-o", bin, "../../cmd/gnomon").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	cmd := exec.CommandContext(context.Background(), bin, "--dsn", testdb.WithUser(dsn, agent), "mcp", "--statement-timeout", "1s")
	in, _ := cmd.StdinPipe()
	outp, _ := cmd.StdoutPipe()
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { in.Close(); _ = cmd.Wait() }()
	c := &client{t: t, in: in, out: bufio.NewScanner(outp)}
	c.out.Buffer(make([]byte, 1<<20), 16<<20)

	init := c.call("initialize", map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{},
		"clientInfo": map[string]any{"name": "test", "version": "0"}})
	if init["protocolVersion"] == nil {
		t.Fatalf("initialize: %v", init)
	}
	fmt.Fprintln(in, `{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	if tools := c.call("tools/list", nil)["tools"].([]any); len(tools) < 6 {
		t.Fatalf("tools: %v", tools)
	}

	// the agent works on its own branch
	if txt, isErr := c.tool("create_branch", map[string]any{"name": "agent-1"}); isErr {
		t.Fatalf("create_branch: %s", txt)
	}
	if txt, isErr := c.tool("execute", map[string]any{"branch": "agent-1", "sql": "update item set name = 'by agent', qty = 7 where id = 2",
		"reason": "rename item 2 as asked"}); isErr {
		t.Fatalf("execute: %s", txt)
	}
	// blame shows the agent and its reason
	if txt, _ := c.tool("blame", map[string]any{"table": "item", "key": map[string]any{"id": 2}, "branch": "agent-1"}); !strings.Contains(txt, "rename item 2 as asked") || !strings.Contains(txt, "mcp:"+agent) {
		t.Fatalf("blame should show the agent and its reason: %s", txt)
	}
	// a query past the limit says so
	if txt, _ := c.tool("query", map[string]any{"sql": "select * from item", "limit": 2}); !strings.Contains(txt, `"truncated": true`) {
		t.Fatalf("a cut result must say so: %s", txt)
	}
	// a call over the timeout is cancelled
	if txt, isErr := c.tool("query", map[string]any{"sql": "select pg_sleep(5)"}); !isErr || !strings.Contains(txt, "57014") {
		t.Fatalf("a long call must be cancelled: %s", txt)
	}
	// two statements are refused
	if txt, isErr := c.tool("query", map[string]any{"sql": "select 1; select 2"}); !isErr {
		t.Fatalf("two statements must be refused: %s", txt)
	}
	if txt, _ := c.tool("describe", map[string]any{"branch": "agent-1"}); !strings.Contains(txt, `"tracked": true`) {
		t.Fatalf("describe: %s", txt)
	}
	if txt, _ := c.tool("query", map[string]any{"branch": "agent-1", "sql": "select name from item where id = 2"}); !strings.Contains(txt, "by agent") {
		t.Fatalf("query on branch: %s", txt)
	}
	if txt, _ := c.tool("query", map[string]any{"sql": "select name from item where id = 2"}); !strings.Contains(txt, "item 2") {
		t.Fatalf("main untouched: %s", txt)
	}
	if txt, _ := c.tool("diff", map[string]any{"branch": "agent-1"}); !strings.Contains(txt, "by agent") {
		t.Fatalf("diff: %s", txt)
	}

	// the database, not the tool list, stops everything else
	if txt, isErr := c.tool("execute", map[string]any{"branch": "main", "sql": "update item set qty = 0"}); !isErr {
		t.Fatalf("execute on main should be refused: %s", txt)
	}
	if txt, isErr := c.tool("execute", map[string]any{"branch": "agent-1", "sql": "select gnomon.merge('agent-1')"}); !isErr || !strings.Contains(txt, "42501") {
		t.Fatalf("agent must not be able to merge: %s", txt)
	}
	if txt, isErr := c.tool("execute", map[string]any{"branch": "agent-1", "sql": "update public.item set qty = 0 where id = 1"}); !isErr || !strings.Contains(txt, "permission denied") {
		t.Fatalf("schema-qualified write to main must be refused: %s", txt)
	}
	if txt, isErr := c.tool("execute", map[string]any{"branch": "agent-1", "sql": "select gnomon.undo_merge(1)"}); !isErr {
		t.Fatalf("agent must not be able to undo on main: %s", txt)
	}
	txt, isErr := c.tool("request_merge", map[string]any{"branch": "agent-1", "title": "rename item 2"})
	if isErr {
		t.Fatalf("request_merge: %s", txt)
	}
	if txt, _ := c.tool("merge_preview", map[string]any{"branch": "agent-1"}); !strings.Contains(txt, "update") {
		t.Fatalf("merge_preview: %s", txt)
	}

	// a human reviews, merges, then undoes the merge
	cr := testdb.Scalar(t, dsn, "select max(id) from gnomon.change_request")
	testdb.Exec(t, dsn, "select gnomon.review("+cr+", 'approve', 'ok')")
	mid := testdb.Scalar(t, dsn, "select gnomon.merge('agent-1')")
	if got := testdb.Scalar(t, dsn, "select name from item where id = 2"); got != "by agent" {
		t.Fatalf("after merge: %s", got)
	}
	if got := testdb.Scalar(t, dsn, "select status from gnomon.change_request where id = "+cr); got != "merged" {
		t.Fatalf("change request status: %s", got)
	}
	testdb.Exec(t, dsn, "select gnomon.undo_merge("+mid+")")
	if got := testdb.Scalar(t, dsn, "select name || '/' || qty from item where id = 2"); got != "item 2/1" {
		t.Fatalf("after undo: %s", got)
	}
}

// The stateless revision (2026-07-28): no initialize, the version in each request's _meta,
// server/discover, resultType on every result; over HTTP a bearer token maps to an agent role the
// database confines.
func TestStatelessHTTP(t *testing.T) {
	dsn := testdb.New(t, t.Name())
	srvLogin := fmt.Sprintf("cli_mcpsrv_%d", os.Getpid())
	testdb.Exec(t, dsn,
		"create table item (id int primary key, name text not null)",
		"insert into item select g, 'item ' || g from generate_series(1, 5) g",
		"select gnomon.track('item')",
		"drop role if exists "+srvLogin, "drop role if exists gnomon_agent_httpbot",
		"create role "+srvLogin+" login",
		"grant gnomon_runner to "+srvLogin)
	tok := testdb.Scalar(t, dsn, "select gnomon.agent_create('httpbot') ->> 'token'")
	testdb.Exec(t, dsn, "grant gnomon_agent_httpbot to "+srvLogin)
	t.Cleanup(func() {
		testdb.Exec(t, dsn, "select gnomon.unassign('gnomon_agent_httpbot')", "select gnomon.unconfine('gnomon_agent_httpbot')",
			"drop owned by gnomon_agent_httpbot, "+srvLogin)
		testdb.Exec(t, testdb.Base()+" dbname=postgres", "drop role if exists gnomon_agent_httpbot", "drop role if exists "+srvLogin)
	})
	h, err := mcp.NewHTTP(context.Background(), testdb.WithUser(dsn, srvLogin), "test")
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(h)
	defer srv.Close()
	rpc := func(token, method string, params map[string]any) (int, map[string]any) {
		if params == nil {
			params = map[string]any{}
		}
		params["_meta"] = map[string]any{"io.modelcontextprotocol/protocolVersion": "2026-07-28",
			"io.modelcontextprotocol/clientInfo": map[string]any{"name": "test"}}
		b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
		req, _ := http.NewRequest("POST", srv.URL, strings.NewReader(string(b)))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Mcp-Method", method)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var out map[string]any
		_ = json.NewDecoder(resp.Body).Decode(&out)
		return resp.StatusCode, out
	}
	if code, _ := rpc("", "tools/list", nil); code != http.StatusUnauthorized {
		t.Fatalf("no token: %d", code)
	}
	if code, _ := rpc("wrong", "tools/list", nil); code != http.StatusUnauthorized {
		t.Fatalf("a wrong token: %d", code)
	}
	_, d := rpc(tok, "server/discover", nil)
	r, _ := d["result"].(map[string]any)
	if r == nil || r["resultType"] != "complete" || !strings.Contains(fmt.Sprint(r["supportedVersions"]), "2026-07-28") {
		t.Fatalf("server/discover: %v", d)
	}
	_, l := rpc(tok, "tools/list", nil)
	if r, _ := l["result"].(map[string]any); r == nil || r["ttlMs"] == nil || r["cacheScope"] == nil {
		t.Fatalf("tools/list needs ttlMs and cacheScope: %v", l)
	}
	call := func(name string, args map[string]any) map[string]any {
		_, out := rpc(tok, "tools/call", map[string]any{"name": name, "arguments": args})
		r, _ := out["result"].(map[string]any)
		if r == nil {
			t.Fatalf("%s: %v", name, out)
		}
		return r
	}
	// its writes land on its assigned branch, as its role
	if r := call("execute", map[string]any{"branch": "httpbot/1", "sql": "update item set name = 'over http' where id = 1", "reason": "test"}); r["isError"] == true {
		t.Fatalf("execute over HTTP: %v", r)
	}
	if got := testdb.Scalar(t, dsn, "select role from gnomon.history('item', '1', 'httpbot/1') order by vkey desc limit 1"); got != "gnomon_agent_httpbot" {
		t.Fatalf("written as %q, not the agent's role", got)
	}
	if r := call("execute", map[string]any{"branch": "httpbot/1", "sql": "update public.item set name = 'x'"}); r["isError"] != true {
		t.Fatalf("the agent must not write main: %v", r)
	}
	// a call that names no branch works on the assigned branch, and describe says which
	if r := call("describe", map[string]any{}); !strings.Contains(fmt.Sprint(r["structuredContent"]), "branch:httpbot/1") {
		t.Fatalf("describe without a branch: %v", r["structuredContent"])
	}
	if r := call("execute", map[string]any{"sql": "update item set name = 'no branch named' where id = 2", "reason": "test"}); r["isError"] == true {
		t.Fatalf("execute without a branch: %v", r)
	}
	if r := call("diff", map[string]any{}); r["isError"] == true || !strings.Contains(fmt.Sprint(r["structuredContent"]), "no branch named") {
		t.Fatalf("diff without a branch: %v", r)
	}
	if got := testdb.Scalar(t, dsn, "select name from item where id = 2"); got != "item 2" {
		t.Fatalf("main changed: %q", got)
	}
	if got := testdb.Scalar(t, dsn, "select count(*) from gnomon.agent_call where agent = 'httpbot'"); got == "0" {
		t.Fatal("calls are recorded")
	}
	_, bad := rpc(tok, "tools/list", map[string]any{})
	_ = bad
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": map[string]any{"_meta": map[string]any{"io.modelcontextprotocol/protocolVersion": "1999-01-01"}}})
	req, _ := http.NewRequest("POST", srv.URL, strings.NewReader(string(b)))
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, _ := http.DefaultClient.Do(req)
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	resp.Body.Close()
	if e, _ := out["error"].(map[string]any); e == nil || fmt.Sprint(e["code"]) != "-32022" {
		t.Fatalf("an unsupported version: %v", out)
	}
}
