# gnomon for Go

`github.com/bitsinfra/gnomon/integrations/go`: put a Go application, or each of its tests, on a
branch of a PostgreSQL database with the gnomon extension. Built on pgx v5.

## Install

```bash
go get github.com/bitsinfra/gnomon/integrations/go@v1.0.2
```

```go
import gnomon "github.com/bitsinfra/gnomon/integrations/go"
import "github.com/bitsinfra/gnomon/integrations/go/gnomontest"   // in tests
```

Go 1.25 or later.

## On a branch

```go
cfg, _ := pgxpool.ParseConfig(dsn)
cfg.AfterConnect = gnomon.AfterConnect("feature")            // every connection on the branch
pool, _ := pgxpool.NewWithConfig(ctx, cfg)

err := gnomon.WithBranch(ctx, pool, "feature", func(tx pgx.Tx) error {   // one transaction (poolers)
    _, err := tx.Exec(ctx, "update accounts set ...")
    return err
})
db, _ := gnomon.OpenDB(dsn, "feature")                       // database/sql
```

`BranchOptions` builds a libpq `options` value; `ConnectionOptions` asks the database (it knows
scratch branches, mask profiles and schema versions). `Use`, `CreateBranch`, `DropBranch`, `Merge`;
`Code(err)` is the stable `[gnomon:<slug>]` of an error, `Explain(ctx, q, err)` what
`gnomon.explain_error` says about it.

## Tests on branches

Each test runs on its own scratch branch of one seeded database:

```go
func TestSignup(t *testing.T) {
    conn := gnomontest.Branch(t, os.Getenv("GNOMON_TEST_DSN"))   // dropped when the test ends
    ...
}
```

`go test ./...` here runs against the repository's dev cluster (`tools/devcluster.sh start`), or
the server `GNOMON_TEST_SERVER` names.
