package web

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/bitsinfra/gnomon/cli/internal/testdb"
)

// The review app acts as the person: the database's rules apply to them, not to the server.
func TestReviewApp(t *testing.T) {
	dsn := testdb.New(t, t.Name())
	p := fmt.Sprintf("_%d", os.Getpid())
	author, reviewer, agent := "web_author"+p, "web_reviewer"+p, "web_agent"+p
	testdb.Exec(t, dsn,
		"create table acct (id int primary key, owner text not null, bal int not null)",
		"insert into acct select g, 'o' || g, 100 from generate_series(1, 10) g",
		"select gnomon.track('acct')",
		"drop role if exists "+author, "drop role if exists "+reviewer, "drop role if exists "+agent,
		"create role "+author+" login", "create role "+reviewer+" login", "create role "+agent+" login",
		"grant gnomon_merger to "+reviewer,
		"grant select, insert, update, delete on acct to "+author+", "+reviewer+", "+agent,
		"select gnomon.create_branch('agent-work')",
		"select gnomon.confine('"+agent+"', array['agent-work'])")
	t.Cleanup(func() {
		testdb.Exec(t, dsn, "select gnomon.unconfine('"+agent+"')")
		testdb.Exec(t, dsn, "drop owned by "+author+", "+reviewer+", "+agent)
		testdb.Exec(t, testdb.Base()+" dbname=postgres", "drop role if exists "+author, "drop role if exists "+reviewer, "drop role if exists "+agent)
	})
	app, err := New(context.Background(), Config{DSN: dsn, Auth: "header:X-User", Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app)
	defer srv.Close()
	noRedirect := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

	get := func(who, path string) (int, string) {
		req, _ := http.NewRequest("GET", srv.URL+path, nil)
		if who != "" {
			req.Header.Set("X-User", who)
		}
		resp, err := noRedirect.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b)
	}
	csrfRe := regexp.MustCompile(`name="csrf" value="([0-9a-f]+)"`)
	csrf := func(who string) string {
		_, body := get(who, "/branch?name=agent-work")
		m := csrfRe.FindStringSubmatch(body)
		if m == nil {
			t.Fatalf("no CSRF token for %s", who)
		}
		return m[1]
	}
	post := func(who, path string, form url.Values) (int, string) {
		req, _ := http.NewRequest("POST", srv.URL+path, strings.NewReader(form.Encode()))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("X-User", who)
		resp, err := noRedirect.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, resp.Header.Get("Location") + string(b)
	}

	if code, _ := get("", "/"); code != http.StatusUnauthorized {
		t.Fatalf("no identity: %d", code)
	}
	// the agent writes its branch (through the database, as itself)
	testdb.Exec(t, testdb.WithUser(dsn, agent), "select gnomon.use('agent-work'); update acct set bal = 1 where id = 3")
	if code, body := get(author, "/branch?name=agent-work"); code != 200 || !strings.Contains(body, "public.acct") && !strings.Contains(body, ">acct<") {
		t.Fatalf("branch page: %d %s", code, body)
	}
	// writes need the CSRF token
	if code, _ := post(author, "/do/open-cr", url.Values{"branch": {"agent-work"}, "title": {"no token"}}); code != http.StatusForbidden {
		t.Fatalf("a write without a CSRF token: %d", code)
	}
	// a read endpoint cannot write
	if code, _ := get(author, "/do/merge?branch=agent-work"); code != http.StatusMethodNotAllowed {
		t.Fatalf("GET on a write: %d", code)
	}
	_, loc := post(author, "/do/open-cr", url.Values{"csrf": {csrf(author)}, "branch": {"agent-work"}, "title": {"set bal of 3"}})
	cr := testdb.Scalar(t, dsn, "select max(id) from gnomon.change_request")
	if !strings.Contains(loc, "/cr/"+cr) {
		t.Fatalf("open change request: %s", loc)
	}
	if got := testdb.Scalar(t, dsn, "select opened_by from gnomon.change_request where id = "+cr); got != author {
		t.Fatalf("opened as %s, not the person", got)
	}
	// an author cannot approve their own request
	_, loc = post(author, "/do/review", url.Values{"csrf": {csrf(author)}, "cr": {cr}, "verdict": {"approve"}})
	if !strings.Contains(loc, "refused") || testdb.Scalar(t, dsn, "select count(*) from gnomon.review where cr = "+cr) != "0" {
		t.Fatalf("the author approved their own request: %s", loc)
	}
	// a confined role cannot approve or merge through the app
	_, loc = post(agent, "/do/review", url.Values{"csrf": {csrf(agent)}, "cr": {cr}, "verdict": {"approve"}})
	if !strings.Contains(loc, "refused") {
		t.Fatalf("a confined role approved: %s", loc)
	}
	_, loc = post(agent, "/do/merge", url.Values{"csrf": {csrf(agent)}, "branch": {"agent-work"}})
	if !strings.Contains(loc, "refused") || testdb.Scalar(t, dsn, "select bal from acct where id = 3") != "100" {
		t.Fatalf("a confined role merged: %s", loc)
	}
	// the reviewer approves and merges, then the undo preview shows what an undo would do
	_, loc = post(reviewer, "/do/review", url.Values{"csrf": {csrf(reviewer)}, "cr": {cr}, "verdict": {"approve"}, "body": {"ok"}})
	if strings.Contains(loc, "refused") {
		t.Fatalf("approve: %s", loc)
	}
	_, loc = post(reviewer, "/do/merge", url.Values{"csrf": {csrf(reviewer)}, "branch": {"agent-work"}, "close": {"on"}})
	if strings.Contains(loc, "refused") || testdb.Scalar(t, dsn, "select bal from acct where id = 3") != "1" {
		t.Fatalf("merge: %s", loc)
	}
	mid := testdb.Scalar(t, dsn, "select max(id) from gnomon.merge")
	code, body := get(reviewer, "/api/v1/undo-preview?merge="+mid)
	var prev map[string]any
	_ = json.Unmarshal([]byte(body), &prev)
	if code != 200 || prev["would_revert"] == nil || testdb.Scalar(t, dsn, "select bal from acct where id = 3") != "1" {
		t.Fatalf("undo preview (and it must not undo): %d %s", code, body)
	}
	// pages and the API
	for _, path := range []string{"/", "/cr", "/cr/" + cr, "/log", "/row?table=acct&key=" + url.QueryEscape(`{"id": 3}`), "/time?table=acct",
		"/graph?table=acct&key=" + url.QueryEscape(`{"id": 3}`), "/schema", "/schema?branch=agent-work", "/preview?branch=agent-work"} {
		if code, body := get(reviewer, path); code != 200 || strings.Contains(body, `class="err"`) {
			t.Fatalf("%s: %d %s", path, code, body)
		}
	}
	// saved graph views: saved from the page, listed for whoever may read the table, opened, dropped
	_, loc = post(author, "/do/graph-view", url.Values{"csrf": {csrf(author)}, "name": {"acct 3"}, "table": {"acct"}, "key": {`{"id": 3}`}, "depth": {"2"}, "branch": {"agent-work"}})
	if strings.Contains(loc, "refused") {
		t.Fatalf("saving a graph view: %s", loc)
	}
	if code, body := get(reviewer, "/graph"); code != 200 || !strings.Contains(body, ">acct 3</a>") || !strings.Contains(body, "depth=2") {
		t.Fatalf("saved view on the graph page: %d", code)
	}
	if code, body := get(reviewer, "/api/v1/graph-views"); code != 200 || !strings.Contains(body, `"acct 3"`) {
		t.Fatalf("graph views API: %d %s", code, body)
	}
	if _, loc = post(reviewer, "/do/graph-view-drop", url.Values{"csrf": {csrf(reviewer)}, "name": {"acct 3"}}); !strings.Contains(loc, "refused") {
		t.Fatalf("another role dropped a graph view: %s", loc)
	}
	if _, loc = post(author, "/do/graph-view-drop", url.Values{"csrf": {csrf(author)}, "name": {"acct 3"}}); strings.Contains(loc, "refused") {
		t.Fatalf("dropping a graph view: %s", loc)
	}
	if code, body := get(reviewer, "/api/v1/request?id="+cr); code != 200 || !strings.Contains(body, `"merged"`) {
		t.Fatalf("api request: %d %s", code, body)
	}
	if code, body := get("", "/metrics"); code != 200 || !strings.Contains(body, "gnomon_tick_lag_seconds") {
		t.Fatalf("metrics: %d %s", code, body)
	}
}

// Every link the pages print opens without an error, for a branch whose name has a slash (an
// agent's branches do) and rows whose keys are JSON; and a reviewer who is not a superuser settles
// a merge conflict through the app.
func TestReviewAppLinks(t *testing.T) {
	dsn := testdb.New(t, t.Name())
	reviewer := fmt.Sprintf("web_links_%d", os.Getpid())
	testdb.Exec(t, dsn,
		"create table acct (id int primary key, bal int not null)",
		"insert into acct select g, 100 from generate_series(1, 5) g",
		"select gnomon.track('acct')",
		"drop role if exists "+reviewer, "create role "+reviewer+" login",
		"grant gnomon_merger to "+reviewer,
		"grant select, insert, update, delete on acct to "+reviewer,
		"select gnomon.create_branch('bot/1')",
		"select gnomon.use('bot/1'); update acct set bal = 1 where id = 3",
		"select gnomon.open_change_request('bot/1', 'set bal of 3')",
		"select gnomon.use('main'); update acct set bal = 2 where id = 3")
	t.Cleanup(func() {
		testdb.Exec(t, dsn, "drop owned by "+reviewer)
		testdb.Exec(t, testdb.Base()+" dbname=postgres", "drop role if exists "+reviewer)
	})
	app, err := New(context.Background(), Config{DSN: dsn, Auth: "header:X-User", Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(app)
	defer srv.Close()
	get := func(path string) (int, string) {
		req, _ := http.NewRequest("GET", srv.URL+path, nil)
		req.Header.Set("X-User", reviewer)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b)
	}
	hrefRe := regexp.MustCompile(`href="(/[^"]*)"`)
	cr := testdb.Scalar(t, dsn, "select max(id) from gnomon.change_request")
	seen := map[string]bool{}
	for _, page := range []string{"/", "/cr", "/cr/" + cr, "/branch?name=" + url.QueryEscape("bot/1")} {
		code, body := get(page)
		if code != 200 || strings.Contains(body, `class="err"`) {
			t.Fatalf("%s: %d %s", page, code, body)
		}
		for _, m := range hrefRe.FindAllStringSubmatch(body, -1) {
			link := strings.ReplaceAll(m[1], "&amp;", "&")
			if seen[link] || strings.HasPrefix(link, "/do/") || strings.HasPrefix(link, "/logout") {
				continue
			}
			seen[link] = true
			if code, body := get(link); code != 200 || strings.Contains(body, `class="err"`) {
				t.Errorf("link %s on %s: %d %s", link, page, code, regexp.MustCompile(`(?s)<div class="err">(.*?)</div>`).FindString(body))
			}
		}
	}
	if !seen["/row?table=acct&key=%7b%22id%22%3a3%7d&branch=bot%2f1"] && !seen["/row?table=acct&key=%7B%22id%22%3A3%7D&branch=bot%2F1"] {
		t.Errorf("no row link for acct 3 on bot/1 among %v", seen)
	}

	// the merge stops on the conflict main made; the reviewer settles it here and resumes
	testdb.Exec(t, testdb.WithUser(dsn, reviewer), "select gnomon.review("+cr+", 'approve', 'ok')")
	mid := testdb.Scalar(t, testdb.WithUser(dsn, reviewer), "select gnomon.merge('bot/1')")
	if st := testdb.Scalar(t, dsn, "select status from gnomon.merge where id = "+mid); st != "conflicts" {
		t.Fatalf("merge %s: %s, not conflicts", mid, st)
	}
	_, body := get("/preview?branch=" + url.QueryEscape("bot/1"))
	token := regexp.MustCompile(`name="csrf" value="([0-9a-f]+)"`).FindStringSubmatch(body)
	if token == nil {
		t.Fatal("no CSRF token on the preview page")
	}
	conflict := testdb.Scalar(t, dsn, "select min(id) from gnomon.conflict where merge_id = "+mid)
	form := url.Values{"csrf": {token[1]}, "id": {conflict}, "choice": {"theirs"}}
	req, _ := http.NewRequest("POST", srv.URL+"/do/resolve", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("X-User", reviewer)
	client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if got := testdb.Scalar(t, dsn, "select coalesce(resolution, '') || ' by ' || coalesce(resolved_by, '') from gnomon.conflict where id = "+conflict); got != "theirs by "+reviewer {
		t.Fatalf("resolved through the app: %q (%s)", got, resp.Header.Get("Location"))
	}
	testdb.Exec(t, testdb.WithUser(dsn, reviewer), "select gnomon.merge('bot/1', resume => "+mid+")")
	if got := testdb.Scalar(t, dsn, "select bal from acct where id = 3"); got != "1" {
		t.Fatalf("after the resolved merge, bal %s", got)
	}
}
