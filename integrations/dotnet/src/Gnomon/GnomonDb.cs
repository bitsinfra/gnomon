using System.Data.Common;
using System.Text.RegularExpressions;
using Npgsql;

namespace Gnomon;

/// <summary>
/// Branches of a PostgreSQL database with gnomon. The connection helpers take any
/// DbConnection; the connection string helpers are Npgsql's (its Options keyword is libpq's).
/// </summary>
public static class GnomonDb
{
    /// <summary>The routing schema of a user schema; scratch branches have their own.</summary>
    public static string RoutingSchema(string schema, bool scratch = false) =>
        "gnomon_r_" + schema + (scratch ? "__s" : "");

    /// <summary>The options value that starts sessions on a branch.</summary>
    public static string BranchOptions(string branch, bool cModule = false, params string[] schemas)
    {
        var o = "-c gnomon.branch=" + branch;
        if (cModule) return o;
        var path = (schemas.Length == 0 ? new[] { "public" } : schemas)
            .SelectMany(s => new[] { RoutingSchema(s), s });
        return o + " -c search_path=" + string.Join(",", path);
    }

    /// <summary>An Npgsql connection string whose sessions start on a branch.</summary>
    public static string ConnectionString(string connectionString, string branch, bool cModule = false) =>
        WithOptions(connectionString, BranchOptions(branch, cModule));

    /// <summary>A connection string with an options value the database computed (ConnectionOptionsAsync).</summary>
    public static string WithOptions(string connectionString, string options)
    {
        var b = new NpgsqlConnectionStringBuilder(connectionString);
        b.Options = string.IsNullOrEmpty(b.Options) ? options : b.Options + " " + options;
        return b.ConnectionString;
    }

    /// <summary>What a branch's sessions need (schema versions and masks included).</summary>
    public static Task<string?> ConnectionOptionsAsync(DbConnection c, string branch, bool cModule = false, CancellationToken ct = default) =>
        ValueAsync(c, null, "select gnomon.connection_options($1, $2)", ct, branch, cModule);

    /// <summary>Put a session on a branch ("main" leaves it).</summary>
    public static Task<string?> UseAsync(DbConnection c, string branch, CancellationToken ct = default) =>
        ValueAsync(c, null, "select gnomon.use($1)", ct, branch);

    /// <summary>Put a session on a branch, synchronously (EF Core's synchronous interceptors).</summary>
    public static string? Use(DbConnection c, string branch) => Value(c, null, "select gnomon.use($1)", branch);

    /// <summary>Put the current transaction on a branch, synchronously.</summary>
    public static void Begin(DbConnection c, string branch, DbTransaction? tx) => Value(c, tx, "select gnomon.begin($1)", branch);

    /// <summary>Put the current transaction on a branch.</summary>
    public static Task BeginAsync(DbConnection c, string branch, DbTransaction? tx, CancellationToken ct = default) =>
        ValueAsync(c, tx, "select gnomon.begin($1)", ct, branch);

    /// <summary>Run fn in one transaction on a branch, committed when it returns (poolers in transaction mode).</summary>
    public static async Task<T> WithBranchAsync<T>(DbConnection c, string branch, Func<DbTransaction, Task<T>> fn, CancellationToken ct = default)
    {
        await using var tx = await c.BeginTransactionAsync(ct);
        await BeginAsync(c, branch, tx, ct);
        var r = await fn(tx);
        await tx.CommitAsync(ct);
        return r;
    }

    public static async Task<int> CreateBranchAsync(DbConnection c, string name, string parent = "main", string kind = "logged", CancellationToken ct = default) =>
        int.Parse((await ValueAsync(c, null, "select gnomon.create_branch($1, $2, $3)::text", ct, name, parent, kind))!);

    /// <summary>A scratch branch with a fresh name, for a test.</summary>
    public static async Task<string> CreateScratchAsync(DbConnection c, string prefix = "test", string parent = "main", CancellationToken ct = default)
    {
        var name = (await ValueAsync(c, null, "select $1 || '/' || substr(md5(random()::text), 1, 10)", ct, prefix))!;
        await CreateBranchAsync(c, name, parent, "scratch", ct);
        return name;
    }

    public static Task DropBranchAsync(DbConnection c, string name, CancellationToken ct = default) =>
        ValueAsync(c, null, "select gnomon.drop_branch($1, true)::text", ct, name);

    /// <summary>Merge a branch into its parent (or target); returns the merge's status.</summary>
    public static async Task<string?> MergeAsync(DbConnection c, string source, string? target = null, CancellationToken ct = default)
    {
        var id = await ValueAsync(c, null, "select gnomon.merge($1, $2)::text", ct, source, target);
        return await ValueAsync(c, null, "select status from gnomon.merge where id = $1::bigint", ct, id);
    }

    static readonly Regex Slug = new(@"\[gnomon:([a-z_0-9]+)\]", RegexOptions.Compiled);

    /// <summary>The stable [gnomon:&lt;slug&gt;] of an error, or null.</summary>
    public static string? Code(Exception e)
    {
        for (var x = e; x != null; x = x.InnerException)
        {
            var text = x is PostgresException p ? p.MessageText + " " + p.Detail : x.Message;
            var m = Slug.Match(text ?? "");
            if (m.Success) return m.Groups[1].Value;
        }
        return null;
    }

    /// <summary>What gnomon.explain_error says about an error, or null.</summary>
    public static Task<string?> ExplainAsync(DbConnection c, PostgresException e, CancellationToken ct = default) =>
        ValueAsync(c, null, "select gnomon.explain_error($1, $2)", ct, e.SqlState, e.MessageText);

    internal static async Task<string?> ValueAsync(DbConnection c, DbTransaction? tx, string sql, CancellationToken ct, params object?[] args)
    {
        await using var cmd = c.CreateCommand();
        cmd.CommandText = sql;
        cmd.Transaction = tx;
        foreach (var a in args)
        {
            var p = cmd.CreateParameter();
            p.Value = a ?? DBNull.Value;
            cmd.Parameters.Add(p);
        }
        var r = await cmd.ExecuteScalarAsync(ct);
        return r is null or DBNull ? null : r.ToString();
    }

    internal static string? Value(DbConnection c, DbTransaction? tx, string sql, params object?[] args)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = sql;
        cmd.Transaction = tx;
        foreach (var a in args)
        {
            var p = cmd.CreateParameter();
            p.Value = a ?? DBNull.Value;
            cmd.Parameters.Add(p);
        }
        var r = cmd.ExecuteScalar();
        return r is null or DBNull ? null : r.ToString();
    }
}
