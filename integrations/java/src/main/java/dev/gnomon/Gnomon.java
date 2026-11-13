package dev.gnomon;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import javax.sql.DataSource;

/**
 * Branches of a PostgreSQL database with the gnomon extension, from JDBC.
 *
 * <pre>
 *   String url = Gnomon.jdbcUrl("jdbc:postgresql://db/app", "feature", false);   // sessions start on a branch
 *   hikari.setConnectionInitSql(Gnomon.connectionInitSql("feature"));             // or per pooled connection
 *   Gnomon.withBranch(dataSource, "feature", c -&gt; { ...; return null; });        // one transaction (poolers)
 * </pre>
 *
 * Works with any JDBC driver; nothing here depends on one.
 */
public final class Gnomon {
  private Gnomon() {}

  /** A function over a connection that may throw SQLException. */
  @FunctionalInterface
  public interface SqlFunction<T> {
    T apply(Connection c) throws SQLException;
  }

  /** The routing schema of a user schema; scratch branches have their own (__s). */
  public static String routingSchema(String schema, boolean scratch) {
    return "gnomon_r_" + schema + (scratch ? "__s" : "");
  }

  /** The libpq-style options value that starts sessions on a branch. */
  public static String branchOptions(String branch, boolean cModule, String... schemas) {
    StringBuilder b = new StringBuilder("-c gnomon.branch=").append(branch);
    if (!cModule) {
      List<String> path = new ArrayList<>();
      for (String s : schemas.length == 0 ? new String[] {"public"} : schemas) {
        path.add(routingSchema(s, false));
        path.add(s);
      }
      b.append(" -c search_path=").append(String.join(",", path));
    }
    return b.toString();
  }

  /** A JDBC URL whose sessions start on a branch (pgjdbc takes options in the URL). */
  public static String jdbcUrl(String url, String branch, boolean cModule) {
    return withOptions(url, branchOptions(branch, cModule));
  }

  /** A JDBC URL with an options value the database computed (connectionOptions). */
  public static String withOptions(String url, String options) {
    String sep = url.contains("?") ? "&" : "?";
    return url + sep + "options=" + URLEncoder.encode(options, StandardCharsets.UTF_8).replace("+", "%20");
  }

  /** HikariCP's connectionInitSql: every pooled connection on the branch. */
  public static String connectionInitSql(String branch) {
    return "select gnomon.use('" + branch.replace("'", "''") + "')";
  }

  /** What the database says a branch needs (schema versions, masks): gnomon.connection_options. */
  public static String connectionOptions(Connection c, String branch, boolean cModule) throws SQLException {
    return value(c, "select gnomon.connection_options(?, ?)", branch, cModule);
  }

  /** Put a session on a branch (main leaves it); returns the search path. */
  public static String use(Connection c, String branch) throws SQLException {
    return value(c, "select gnomon.use(?)", branch);
  }

  /** Put the current transaction on a branch (gnomon.begin: it lasts that transaction only). */
  public static void begin(Connection c, String branch) throws SQLException {
    value(c, "select gnomon.begin(?)", branch);
  }

  /** Run fn in one transaction on a branch, committed when it returns. */
  public static <T> T withBranch(DataSource ds, String branch, SqlFunction<T> fn) throws SQLException {
    try (Connection c = ds.getConnection()) {
      boolean auto = c.getAutoCommit();
      c.setAutoCommit(false);
      try {
        begin(c, branch);
        T r = fn.apply(c);
        c.commit();
        return r;
      } catch (SQLException | RuntimeException e) {
        c.rollback();
        throw e;
      } finally {
        c.setAutoCommit(auto);
      }
    }
  }

  public static int createBranch(Connection c, String name, String parent, String kind) throws SQLException {
    return Integer.parseInt(value(c, "select gnomon.create_branch(?, ?, ?)::text", name, parent == null ? "main" : parent, kind == null ? "logged" : kind));
  }

  /** A scratch branch with a fresh name, for a test. */
  public static String createScratch(Connection c, String prefix, String parent) throws SQLException {
    String name = value(c, "select ? || '/' || substr(md5(random()::text), 1, 10)", prefix == null ? "test" : prefix);
    createBranch(c, name, parent, "scratch");
    return name;
  }

  public static void dropBranch(Connection c, String name) throws SQLException {
    value(c, "select gnomon.drop_branch(?, true)::text", name);
  }

  /** Merge a branch into its parent (or target); returns the merge's status. */
  public static String merge(Connection c, String source, String target) throws SQLException {
    String id = value(c, "select gnomon.merge(?, ?)::text", source, target);
    return value(c, "select status from gnomon.merge where id = ?::bigint", id);
  }

  private static final Pattern CODE = Pattern.compile("\\[gnomon:([a-z_0-9]+)\\]");

  /** The stable [gnomon:&lt;slug&gt;] of a gnomon error, or null. */
  public static String code(SQLException e) {
    for (Throwable t = e; t != null; t = t.getCause()) {
      if (t.getMessage() != null) {
        Matcher m = CODE.matcher(t.getMessage());
        if (m.find()) {
          return m.group(1);
        }
      }
    }
    return null;
  }

  /** What gnomon.explain_error says about an error on a branch, or null. */
  public static String explain(Connection c, SQLException e) throws SQLException {
    return value(c, "select gnomon.explain_error(?, ?)", e.getSQLState(), e.getMessage());
  }

  static String value(Connection c, String sql, Object... args) throws SQLException {
    try (PreparedStatement ps = c.prepareStatement(sql)) {
      for (int i = 0; i < args.length; i++) {
        ps.setObject(i + 1, args[i]);
      }
      try (ResultSet rs = ps.executeQuery()) {
        return rs.next() ? rs.getString(1) : null;
      }
    }
  }
}
