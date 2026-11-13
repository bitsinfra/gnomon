using System.Data.Common;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;

namespace Gnomon.EntityFrameworkCore;

/// <summary>How a DbContext is put on a branch.</summary>
public enum BranchMode
{
    /// <summary>gnomon.use when a connection opens, and back to main when it closes (direct connections, session poolers).</summary>
    Session,
    /// <summary>gnomon.begin when a transaction starts, no session state (pgbouncer in transaction mode).</summary>
    Transaction,
}

/// <summary>
/// Puts a DbContext on the branch a function names (a request's branch, a tenant's sandbox):
/// <code>
///   options.UseNpgsql(cs).AddInterceptors(new GnomonBranchInterceptor(() =&gt; http.Request.Headers["X-Branch"]));
/// </code>
/// In Transaction mode only a transaction is routed (gnomon.begin when it starts), so a command
/// outside one on a branch is refused rather than run on main: set
/// <c>Database.AutoTransactionBehavior = AutoTransactionBehavior.Always</c> (EF Core 7 and later
/// run a single-statement SaveChanges without a transaction otherwise) and read inside
/// <c>Database.BeginTransaction()</c>, or use Session mode where no transaction pooler is in between.
/// </summary>
public sealed class GnomonBranchInterceptor : IDbConnectionInterceptor, IDbTransactionInterceptor, IDbCommandInterceptor
{
    readonly Func<string?> branch;
    readonly BranchMode mode;

    public GnomonBranchInterceptor(Func<string?> branch, BranchMode mode = BranchMode.Session)
    {
        this.branch = branch;
        this.mode = mode;
    }

    public GnomonBranchInterceptor(string branch, BranchMode mode = BranchMode.Session) : this(() => branch, mode) { }

    string Current() => string.IsNullOrEmpty(branch()) ? "main" : branch()!;

    public void ConnectionOpened(DbConnection connection, ConnectionEndEventData eventData)
    {
        if (mode == BranchMode.Session) GnomonDb.Use(connection, Current());
    }

    public async Task ConnectionOpenedAsync(DbConnection connection, ConnectionEndEventData eventData, CancellationToken ct = default)
    {
        if (mode == BranchMode.Session) await GnomonDb.UseAsync(connection, Current(), ct);
    }

    // a pooled connection goes back to the pool on main: the pool hands it to code that did not
    // ask for the branch (Npgsql does not reset gnomon's settings itself)
    public InterceptionResult ConnectionClosing(DbConnection connection, ConnectionEventData eventData, InterceptionResult result)
    {
        if (mode == BranchMode.Session && connection.State == System.Data.ConnectionState.Open) GnomonDb.Use(connection, "main");
        return result;
    }

    public async ValueTask<InterceptionResult> ConnectionClosingAsync(DbConnection connection, ConnectionEventData eventData, InterceptionResult result)
    {
        if (mode == BranchMode.Session && connection.State == System.Data.ConnectionState.Open) await GnomonDb.UseAsync(connection, "main");
        return result;
    }

    void Check(DbCommand command)
    {
        if (mode == BranchMode.Transaction && command.Transaction is null && Current() != "main")
            throw new InvalidOperationException(
                $"GnomonBranchInterceptor in Transaction mode routes transactions only: run this command in one (Database.BeginTransaction, " +
                $"or AutoTransactionBehavior.Always for SaveChanges), or use Session mode [branch {Current()}]");
    }

    public InterceptionResult<DbDataReader> ReaderExecuting(DbCommand command, CommandEventData eventData, InterceptionResult<DbDataReader> result)
    { Check(command); return result; }

    public ValueTask<InterceptionResult<DbDataReader>> ReaderExecutingAsync(DbCommand command, CommandEventData eventData, InterceptionResult<DbDataReader> result, CancellationToken ct = default)
    { Check(command); return ValueTask.FromResult(result); }

    public InterceptionResult<int> NonQueryExecuting(DbCommand command, CommandEventData eventData, InterceptionResult<int> result)
    { Check(command); return result; }

    public ValueTask<InterceptionResult<int>> NonQueryExecutingAsync(DbCommand command, CommandEventData eventData, InterceptionResult<int> result, CancellationToken ct = default)
    { Check(command); return ValueTask.FromResult(result); }

    public InterceptionResult<object> ScalarExecuting(DbCommand command, CommandEventData eventData, InterceptionResult<object> result)
    { Check(command); return result; }

    public ValueTask<InterceptionResult<object>> ScalarExecutingAsync(DbCommand command, CommandEventData eventData, InterceptionResult<object> result, CancellationToken ct = default)
    { Check(command); return ValueTask.FromResult(result); }

    public DbTransaction TransactionStarted(DbConnection connection, TransactionEndEventData eventData, DbTransaction result)
    {
        if (mode == BranchMode.Transaction && Current() != "main")
            GnomonDb.Begin(connection, Current(), result);
        return result;
    }

    public async ValueTask<DbTransaction> TransactionStartedAsync(DbConnection connection, TransactionEndEventData eventData, DbTransaction result, CancellationToken ct = default)
    {
        if (mode == BranchMode.Transaction && Current() != "main")
            await GnomonDb.BeginAsync(connection, Current(), result, ct);
        return result;
    }
}
