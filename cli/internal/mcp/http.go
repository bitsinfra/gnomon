package mcp

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"

	"github.com/bitsinfra/gnomon/cli/internal/gn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// HTTP is the stateless Streamable HTTP transport: each POST is one JSON-RPC
// request, independent of every other. A bearer token maps to an agent (gnomon.agent_auth) and
// every call runs as that agent's role (SET LOCAL ROLE), so the database confines it, not this
// server. The server logs in as a role that is a member of gnomon_runner (for the token lookup)
// and of each agent role; never as a superuser. TLS is terminated by a proxy in front of it.
type HTTP struct {
	Pool          *pgxpool.Pool
	Version       string
	RequireReason bool
	Base          Server // timeouts and caps for every agent

	mu     sync.Mutex
	agents map[string]*Server
}

func (h *HTTP) agent(name, role string) *Server {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.agents == nil {
		h.agents = map[string]*Server{}
	}
	s, ok := h.agents[name]
	if !ok {
		s = &Server{Version: h.Version, Agent: name, Role: role, RequireReason: h.RequireReason,
			StatementTimeout: h.Base.StatementTimeout, LockTimeout: h.Base.LockTimeout, IdleTimeout: h.Base.IdleTimeout,
			MaxRows: h.Base.MaxRows, MaxBytes: h.Base.MaxBytes}
		h.agents[name] = s
	}
	return s
}

func writeRPC(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func (h *HTTP) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		http.Error(w, "POST a JSON-RPC request", http.StatusMethodNotAllowed)
		return
	}
	tok := strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	if tok == "" || tok == r.Header.Get("Authorization") {
		w.Header().Set("WWW-Authenticate", `Bearer realm="gnomon"`)
		http.Error(w, "a bearer token is required (gnomon agent create prints one)", http.StatusUnauthorized)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 8<<20))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	var req request
	if err := json.Unmarshal(body, &req); err != nil {
		writeRPC(w, http.StatusBadRequest, response{JSONRPC: "2.0", ID: json.RawMessage("null"), Error: &rpcError{-32700, "parse error", nil}})
		return
	}
	// the standard request headers must agree with the body (2026-07-28)
	if m := r.Header.Get("Mcp-Method"); m != "" && m != req.Method {
		writeRPC(w, http.StatusBadRequest, response{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{-32020, "Mcp-Method does not match the request", nil}})
		return
	}
	if n := r.Header.Get("Mcp-Name"); n != "" && req.Method == "tools/call" {
		var p struct {
			Name string `json:"name"`
		}
		_ = json.Unmarshal(req.Params, &p)
		if p.Name != n {
			writeRPC(w, http.StatusBadRequest, response{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{-32020, "Mcp-Name does not match the tool", nil}})
			return
		}
	}
	if len(req.ID) == 0 {
		w.WriteHeader(http.StatusAccepted)
		return
	}
	ctx := r.Context()
	conn, err := h.Pool.Acquire(ctx)
	if err != nil {
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
		return
	}
	defer conn.Release()
	var name, role string
	var branch *string
	if err := conn.QueryRow(ctx, "select name, role::text, branch from gnomon.agent_auth($1)", tok).Scan(&name, &role, &branch); err != nil {
		w.Header().Set("WWW-Authenticate", `Bearer realm="gnomon", error="invalid_token"`)
		http.Error(w, "unknown or stopped agent token", http.StatusUnauthorized)
		return
	}
	s := h.agent(name, role)
	s.mu.Lock()
	s.conn = conn.Conn()
	if run := r.Header.Get("Mcp-Run"); run != "" {
		s.Run = run
	}
	s.mu.Unlock()
	res, rerr := s.handleHTTP(ctx, req)
	s.mu.Lock()
	s.conn = nil
	s.mu.Unlock()
	writeRPC(w, http.StatusOK, response{JSONRPC: "2.0", ID: req.ID, Result: res, Error: rerr})
}

// handleHTTP is handle without holding the connection between requests.
func (s *Server) handleHTTP(ctx context.Context, req request) (any, *rpcError) {
	return s.handle(ctx, req)
}

// NewHTTP connects the transport's pool.
func NewHTTP(ctx context.Context, dsn, version string) (*HTTP, error) {
	if dsn == "" {
		dsn = gn.DefaultDSN()
	}
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	cfg.ConnConfig.RuntimeParams["application_name"] = "gnomon-mcp-http"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	return &HTTP{Pool: pool, Version: version}, nil
}
