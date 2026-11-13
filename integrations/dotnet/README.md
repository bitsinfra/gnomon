# gnomon for .NET

Branches of a PostgreSQL database with gnomon from Npgsql and EF Core, and an xUnit fixture with
a scratch branch of one seeded database.

Tests: `GNOMON_TEST_CONNECTION="Host=/path/to/socket/dir;Port=5432;Username=postgres;Database=app" dotnet
test test/Gnomon.Tests` (options, error codes, the xUnit fixture on a real branch, and EF Core's
SaveChanges through the interceptor in both modes; without the variable only the first two run).

```csharp
// sessions that start on a branch (Npgsql's Options is libpq's options)
var cs = GnomonDb.ConnectionString("Host=db;Database=app", "feature");          // cModule: true with the C module

// or what the database says the branch needs (schema versions, masks)
var cs2 = GnomonDb.WithOptions(baseCs, await GnomonDb.ConnectionOptionsAsync(conn, "feature"));

// EF Core: the request's branch on each connection (back on main when EF closes it) ...
options.UseNpgsql(cs).AddInterceptors(new GnomonBranchInterceptor(() => branchOfRequest()));

// ... or on each transaction, behind pgbouncer in transaction mode. A command outside a
// transaction is then refused rather than run on main: EF Core 7+ runs a one-statement
// SaveChanges without a transaction unless told otherwise, and reads need one of their own.
options.UseNpgsql(cs).AddInterceptors(new GnomonBranchInterceptor(() => branchOfRequest(), BranchMode.Transaction));
db.Database.AutoTransactionBehavior = AutoTransactionBehavior.Always;
await using (var tx = await db.Database.BeginTransactionAsync()) { var n = await db.Orders.CountAsync(); }

// one transaction on a branch
await GnomonDb.WithBranchAsync(conn, "feature", async tx => { /* ... */ return 0; });

// errors: the stable slug
catch (PostgresException e) when (GnomonDb.Code(e) == "ddl_on_branch") { ... }
```

## xUnit

```csharp
public class SignupTests : IClassFixture<GnomonBranchFixture>
{
    readonly GnomonBranchFixture db;
    public SignupTests(GnomonBranchFixture db) => this.db = db;

    [Fact]
    public async Task Signup()
    {
        await using var c = await db.OpenAsync();   // on the class's scratch branch
    }
}
```

`GNOMON_TEST_CONNECTION` names the seeded database; `GNOMON_C_MODULE=1` when the server preloads
the C module; `GNOMON_KEEP=1` keeps the branches.
