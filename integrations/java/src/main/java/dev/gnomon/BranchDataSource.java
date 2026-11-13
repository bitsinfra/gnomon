package dev.gnomon;

import java.io.PrintWriter;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Proxy;
import java.sql.Connection;
import java.sql.SQLException;
import java.sql.SQLFeatureNotSupportedException;
import java.util.logging.Logger;
import javax.sql.DataSource;

/**
 * A DataSource whose connections are on the branch the current thread names (a request's branch,
 * the way Spring's routing data source picks a database): BranchDataSource.on("feature", () -&gt; ...).
 *
 * <p>Two modes. SESSION puts each connection handed out on the branch with gnomon.use (main when
 * the thread names none). TRANSACTION, for poolers in transaction mode (pgbouncer), runs
 * gnomon.begin at the start of each transaction instead, before its first statement, and never
 * sets session state that a shared server connection would carry to another client: Spring's
 * DataSourceTransactionManager and @Transactional work unchanged. In that mode a statement outside
 * a transaction on a branch is refused, since nothing would route it.
 */
public final class BranchDataSource implements DataSource {
  public enum Mode { SESSION, TRANSACTION }

  private static final ThreadLocal<String> CURRENT = new ThreadLocal<>();
  private final DataSource delegate;
  private final Mode mode;

  public BranchDataSource(DataSource delegate) {
    this(delegate, Mode.SESSION);
  }

  public BranchDataSource(DataSource delegate, Mode mode) {
    this.delegate = delegate;
    this.mode = mode;
  }

  /** Run body with the current thread on a branch. */
  public static <T> T on(String branch, java.util.concurrent.Callable<T> body) throws Exception {
    String prev = CURRENT.get();
    CURRENT.set(branch);
    try {
      return body.call();
    } finally {
      if (prev == null) {
        CURRENT.remove();
      } else {
        CURRENT.set(prev);
      }
    }
  }

  public static String current() {
    String b = CURRENT.get();
    return b == null ? "main" : b;
  }

  @Override
  public Connection getConnection() throws SQLException {
    return route(delegate.getConnection());
  }

  @Override
  public Connection getConnection(String user, String password) throws SQLException {
    return route(delegate.getConnection(user, password));
  }

  private Connection route(Connection c) throws SQLException {
    if (mode == Mode.TRANSACTION) {
      return perTransaction(c, current());
    }
    try {
      Gnomon.use(c, current());
      return c;
    } catch (SQLException e) {
      c.close();
      throw e;
    }
  }

  /** A connection that runs gnomon.begin before the first statement of each transaction. */
  static Connection perTransaction(Connection c, String branch) {
    if ("main".equals(branch)) {
      return c;
    }
    boolean[] pending = {true}; // the next statement starts a transaction that needs gnomon.begin
    return (Connection) Proxy.newProxyInstance(Connection.class.getClassLoader(), new Class<?>[] {Connection.class}, (p, m, a) -> {
      String n = m.getName();
      if (n.equals("createStatement") || n.equals("prepareStatement") || n.equals("prepareCall")) {
        if (c.getAutoCommit()) {
          throw new SQLException("BranchDataSource in TRANSACTION mode routes transactions only: run this statement in a transaction (@Transactional), or use SESSION mode without a pooler [branch " + branch + "]", "25000");
        }
        if (pending[0]) {
          Gnomon.begin(c, branch);
          pending[0] = false;
        }
      }
      try {
        Object r = m.invoke(c, a);
        if (n.equals("commit") || n.equals("rollback") || n.equals("setAutoCommit")) {
          pending[0] = true;
        }
        return r;
      } catch (InvocationTargetException e) {
        throw e.getCause();
      }
    });
  }

  @Override public PrintWriter getLogWriter() throws SQLException { return delegate.getLogWriter(); }
  @Override public void setLogWriter(PrintWriter out) throws SQLException { delegate.setLogWriter(out); }
  @Override public void setLoginTimeout(int seconds) throws SQLException { delegate.setLoginTimeout(seconds); }
  @Override public int getLoginTimeout() throws SQLException { return delegate.getLoginTimeout(); }
  @Override public Logger getParentLogger() throws SQLFeatureNotSupportedException { return delegate.getParentLogger(); }
  @Override public <T> T unwrap(Class<T> iface) throws SQLException { return delegate.unwrap(iface); }
  @Override public boolean isWrapperFor(Class<?> iface) throws SQLException { return delegate.isWrapperFor(iface); }
}
