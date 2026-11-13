using Gnomon;
using Gnomon.EntityFrameworkCore;
using Gnomon.Xunit;
using Microsoft.EntityFrameworkCore;
using Npgsql;
using Xunit;

public class OptionsTests
{
    [Fact]
    public void BranchOptions()
    {
        Assert.Equal("-c gnomon.branch=f", GnomonDb.BranchOptions("f", cModule: true));
        Assert.Equal("-c gnomon.branch=f -c search_path=gnomon_r_public,public", GnomonDb.BranchOptions("f"));
        Assert.Equal("gnomon_r_app__s", GnomonDb.RoutingSchema("app", true));
    }

    [Fact]
    public void ConnectionString()
    {
        var cs = GnomonDb.ConnectionString("Host=db;Database=app", "f", cModule: true);
        Assert.Equal("-c gnomon.branch=f", new NpgsqlConnectionStringBuilder(cs).Options);
    }

    [Fact]
    public void Code()
    {
        Assert.Equal("ddl_on_branch", GnomonDb.Code(new Exception("refused [gnomon:ddl_on_branch]")));
        Assert.Null(GnomonDb.Code(new Exception("plain")));
    }
}

/// <summary>Runs only with GNOMON_TEST_CONNECTION set: a real branch, a write, a merge.</summary>
public class BranchTests
{
    static string? Cs => Environment.GetEnvironmentVariable("GNOMON_TEST_CONNECTION");

    [Fact]
    public async Task FixtureBranch()
    {
        if (Cs is null) return;
        var f = new GnomonBranchFixture(Cs);
        await f.InitializeAsync();
        try
        {
            await using var c = await f.OpenAsync();
            await using var cmd = new NpgsqlCommand("select current_setting('gnomon.branch')", c);
            Assert.Equal(f.Branch, (string?)await cmd.ExecuteScalarAsync());
        }
        finally
        {
            await f.DisposeAsync();
        }
    }
}

public class Item
{
    public int Id { get; set; }
    public string Name { get; set; } = "";
}

public class ItemContext : DbContext
{
    public ItemContext(DbContextOptions<ItemContext> o) : base(o) { }
    public DbSet<Item> Items => Set<Item>();
    protected override void OnModelCreating(ModelBuilder b)
    {
        b.Entity<Item>().ToTable("ef_item");
        b.Entity<Item>().Property(x => x.Id).HasColumnName("id").ValueGeneratedNever();
        b.Entity<Item>().Property(x => x.Name).HasColumnName("name");
    }
}

/// <summary>EF Core through the interceptor, both modes, against GNOMON_TEST_CONNECTION.</summary>
public class InterceptorTests
{
    static string? Cs => Environment.GetEnvironmentVariable("GNOMON_TEST_CONNECTION");

    static async Task<long> Count(string? branch)
    {
        await using var c = new NpgsqlConnection(Cs);
        await c.OpenAsync();
        if (branch is null)
        {
            await using var q = new NpgsqlCommand("select count(*) from ef_item", c);
            return (long)(await q.ExecuteScalarAsync())!;
        }
        return await GnomonDb.WithBranchAsync(c, branch, async tx =>
        {
            await using var q = new NpgsqlCommand("select count(*) from ef_item", c, (NpgsqlTransaction)tx);
            return (long)(await q.ExecuteScalarAsync())!;
        });
    }

    [Fact]
    public async Task SaveChangesLandsOnTheBranch()
    {
        if (Cs is null) return;
        await using (var c = new NpgsqlConnection(Cs))
        {
            await c.OpenAsync();
            await using var setup = new NpgsqlCommand(
                "drop table if exists ef_item; create table ef_item (id int primary key, name text not null); " +
                "select gnomon.track('ef_item'); select gnomon.create_branch('ef-branch')", c);
            await setup.ExecuteNonQueryAsync();
        }
        try
        {
            var id = 0;
            foreach (var mode in new[] { BranchMode.Session, BranchMode.Transaction })
            {
                var opts = new DbContextOptionsBuilder<ItemContext>().UseNpgsql(Cs)
                    .AddInterceptors(new GnomonBranchInterceptor("ef-branch", mode)).Options;
                await using var ctx = new ItemContext(opts);
                if (mode == BranchMode.Transaction) ctx.Database.AutoTransactionBehavior = AutoTransactionBehavior.Always;
                ctx.Items.Add(new Item { Id = ++id, Name = mode.ToString() });
                await ctx.SaveChangesAsync();
                if (mode == BranchMode.Session)
                {
                    Assert.Equal(1, await ctx.Items.CountAsync(x => x.Id == id));   // the session is on the branch
                }
                else
                {
                    // per transaction: a command outside one is refused, inside one it is on the branch
                    await Assert.ThrowsAsync<InvalidOperationException>(() => ctx.Items.CountAsync(x => x.Id == id));
                    await using var tx = await ctx.Database.BeginTransactionAsync();
                    Assert.Equal(1, await ctx.Items.CountAsync(x => x.Id == id));
                }
            }
            Assert.Equal(0, await Count(null));          // main untouched
            Assert.Equal(2, await Count("ef-branch"));   // both writes on the branch
        }
        finally
        {
            await using var c = new NpgsqlConnection(Cs);
            await c.OpenAsync();
            await using var drop = new NpgsqlCommand("select gnomon.drop_branch('ef-branch', true); select gnomon.untrack('ef_item'); drop table ef_item", c);
            await drop.ExecuteNonQueryAsync();
        }
    }
}

