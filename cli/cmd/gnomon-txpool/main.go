// gnomon-txpool: a transaction-mode connection pooler for tests (the SDKs'
// conformance behind a pooler in transaction mode). It behaves as pgbouncer's pool_mode =
// transaction does: a client holds a server connection for one transaction at a time, servers are
// shared between clients with no session reset in between, and startup options are dropped
// (ignore_startup_parameters). Clients are trusted; servers are reached with the client's user
// and database.
//
//	gnomon-txpool -listen 127.0.0.1:54390 -server "host=/path/to/socket port=54329" -size 2
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"sync"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgproto3"
)

type server struct {
	conn net.Conn
	fe   *pgproto3.Frontend
	ps   map[string]string
}

type pool struct {
	base string
	size int
	mu   sync.Mutex
	idle map[string][]*server
	n    map[string]int
	wait map[string]*sync.Cond
}

func (p *pool) get(ctx context.Context, user, db string) (*server, error) {
	k := user + "\x00" + db
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.wait[k] == nil {
		p.wait[k] = sync.NewCond(&p.mu)
	}
	for {
		if l := p.idle[k]; len(l) > 0 {
			s := l[len(l)-1]
			p.idle[k] = l[:len(l)-1]
			return s, nil
		}
		if p.n[k] < p.size {
			p.n[k]++
			p.mu.Unlock()
			c, err := pgconn.Connect(ctx, fmt.Sprintf("%s user=%s dbname=%s", p.base, user, db))
			p.mu.Lock()
			if err != nil {
				p.n[k]--
				return nil, err
			}
			hj, err := c.Hijack()
			if err != nil {
				p.n[k]--
				return nil, err
			}
			return &server{conn: hj.Conn, fe: hj.Frontend, ps: hj.ParameterStatuses}, nil
		}
		p.wait[k].Wait()
	}
}

func (p *pool) put(user, db string, s *server, broken bool) {
	k := user + "\x00" + db
	p.mu.Lock()
	defer p.mu.Unlock()
	if broken {
		s.conn.Close()
		p.n[k]--
	} else {
		p.idle[k] = append(p.idle[k], s)
	}
	p.wait[k].Signal()
}

func main() {
	listen := flag.String("listen", "127.0.0.1:54390", "address to accept clients on")
	base := flag.String("server", "", "the server's connection settings without user and dbname")
	size := flag.Int("size", 2, "server connections per user and database")
	flag.Parse()
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatal(err)
	}
	p := &pool{base: *base, size: *size, idle: map[string][]*server{}, n: map[string]int{}, wait: map[string]*sync.Cond{}}
	log.Printf("gnomon-txpool: transaction pooling on %s (%d per user and database)", *listen, *size)
	for {
		c, err := ln.Accept()
		if err != nil {
			log.Fatal(err)
		}
		go client(p, c)
	}
}

func client(p *pool, c net.Conn) {
	defer c.Close()
	be := pgproto3.NewBackend(c, c)
	var user, db string
	for {
		m, err := be.ReceiveStartupMessage()
		if err != nil {
			return
		}
		switch sm := m.(type) {
		case *pgproto3.SSLRequest, *pgproto3.GSSEncRequest:
			if _, err := c.Write([]byte{'N'}); err != nil {
				return
			}
			continue
		case *pgproto3.CancelRequest:
			return
		case *pgproto3.StartupMessage:
			user = sm.Parameters["user"]
			db = sm.Parameters["database"]
			if db == "" {
				db = user
			}
		}
		break
	}
	ctx := context.Background()
	// the parameters a server reports, from one of the pool's connections
	s, err := p.get(ctx, user, db)
	if err != nil {
		be.Send(&pgproto3.ErrorResponse{Severity: "FATAL", Code: "08006", Message: err.Error()})
		be.Flush()
		return
	}
	be.Send(&pgproto3.AuthenticationOk{})
	for k, v := range s.ps {
		be.Send(&pgproto3.ParameterStatus{Name: k, Value: v})
	}
	be.Send(&pgproto3.BackendKeyData{ProcessID: 1, SecretKey: []byte{0, 0, 0, 1}})
	be.Send(&pgproto3.ReadyForQuery{TxStatus: 'I'})
	p.put(user, db, s, false)
	if be.Flush() != nil {
		return
	}
	var held *server
	var rfq chan byte  // the reader's ReadyForQuery statuses
	var cont chan bool // whether the reader goes on reading this server
	var copyIn chan struct{}
	release := func(broken bool) {
		if held != nil {
			p.put(user, db, held, broken)
			held = nil
		}
	}
	defer func() {
		if held != nil {
			release(true)
		}
	}()
	for {
		m, err := be.Receive()
		if err != nil {
			return
		}
		if _, ok := m.(*pgproto3.Terminate); ok {
			return // (mid-transaction, the deferred release closes the server)
		}
		if held == nil {
			if held, err = p.get(ctx, user, db); err != nil {
				be.Send(&pgproto3.ErrorResponse{Severity: "ERROR", Code: "08006", Message: err.Error()})
				be.Flush()
				return
			}
			rfq, cont, copyIn = make(chan byte), make(chan bool), make(chan struct{})
			go reader(be, held, rfq, cont, copyIn)
		}
		held.fe.Send(m)
		if err := held.fe.Flush(); err != nil {
			return
		}
		switch m.(type) {
		case *pgproto3.Query, *pgproto3.Sync:
		default:
			continue // Flush and the rest: the reader relays whatever the server says
		}
		for waiting := true; waiting; {
			select {
			case st, ok := <-rfq:
				if !ok {
					return // the server went away
				}
				if st == 'I' {
					cont <- false
					release(false)
				} else {
					cont <- true
				}
				waiting = false
			case <-copyIn:
				// COPY FROM STDIN: the client's data goes to the server until it is done
				for {
					cm, err := be.Receive()
					if err != nil {
						return
					}
					held.fe.Send(cm)
					if err := held.fe.Flush(); err != nil {
						return
					}
					_, done := cm.(*pgproto3.CopyDone)
					_, failed := cm.(*pgproto3.CopyFail)
					if done || failed {
						break
					}
				}
			}
		}
	}
}

// reader relays a held server's messages to the client; at each ReadyForQuery it reports the
// transaction status and waits to be told whether to go on (false: the server is released).
func reader(be *pgproto3.Backend, s *server, rfq chan<- byte, cont <-chan bool, copyIn chan<- struct{}) {
	for {
		m, err := s.fe.Receive()
		if err != nil {
			close(rfq)
			return
		}
		be.Send(m)
		switch r := m.(type) {
		case *pgproto3.ReadyForQuery:
			if be.Flush() != nil {
				close(rfq)
				return
			}
			rfq <- r.TxStatus
			if !<-cont {
				return
			}
			continue
		case *pgproto3.CopyInResponse:
			if be.Flush() != nil {
				close(rfq)
				return
			}
			copyIn <- struct{}{}
			continue
		}
		if be.Flush() != nil {
			close(rfq)
			return
		}
	}
}
