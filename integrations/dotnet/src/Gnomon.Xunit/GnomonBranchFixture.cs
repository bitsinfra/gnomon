using Npgsql;
using Xunit;

namespace Gnomon.Xunit;

/// <summary>
/// A scratch branch of one seeded database for a test class (IClassFixture) or for each test
/// (create one in the test's constructor and dispose it). The database: GNOMON_TEST_CONNECTION,
/// an Npgsql connection string. The branch is dropped when the fixture is disposed
/// (GNOMON_KEEP=1 keeps it).
/// <code>
///   public class SignupTests : IClassFixture&lt;GnomonBranchFixture&gt; {
///     readonly GnomonBranchFixture db;
///     public SignupTests(GnomonBranchFixture db) =&gt; this.db = db;
///     [Fact] public async Task Signup() { await using var c = await db.OpenAsync(); ... }
///   }
/// </code>
/// </summary>
public class GnomonBranchFixture : IAsyncLifetime
{
    readonly string baseConnectionString;
    readonly bool cModule;

    public GnomonBranchFixture() : this(
        Environment.GetEnvironmentVariable("GNOMON_TEST_CONNECTION")
            ?? throw new InvalidOperationException("set GNOMON_TEST_CONNECTION to a seeded database with gnomon"),
        Environment.GetEnvironmentVariable("GNOMON_C_MODULE") == "1") { }

    public GnomonBranchFixture(string connectionString, bool cModule = false)
    {
        baseConnectionString = connectionString;
        this.cModule = cModule;
    }

    /// <summary>The scratch branch's name.</summary>
    public string Branch { get; private set; } = "";

    /// <summary>A connection string whose sessions start on the branch (the branch's own options).</summary>
    public string ConnectionString { get; private set; } = "";

    public async Task InitializeAsync()
    {
        await using var c = new NpgsqlConnection(baseConnectionString);
        await c.OpenAsync();
        Branch = await GnomonDb.CreateScratchAsync(c, "xunit");
        var opts = await GnomonDb.ConnectionOptionsAsync(c, Branch, cModule);
        ConnectionString = GnomonDb.WithOptions(baseConnectionString, opts!);
    }

    /// <summary>An open connection on the branch.</summary>
    public async Task<NpgsqlConnection> OpenAsync()
    {
        var c = new NpgsqlConnection(ConnectionString);
        await c.OpenAsync();
        return c;
    }

    public async Task DisposeAsync()
    {
        if (Branch == "" || Environment.GetEnvironmentVariable("GNOMON_KEEP") == "1") return;
        NpgsqlConnection.ClearAllPools();
        await using var c = new NpgsqlConnection(baseConnectionString);
        await c.OpenAsync();
        await GnomonDb.DropBranchAsync(c, Branch);
    }
}
