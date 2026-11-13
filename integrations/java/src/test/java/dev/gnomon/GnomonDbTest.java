package dev.gnomon;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.gnomon.junit.GnomonBranchExtension;
import java.io.PrintWriter;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.logging.Logger;
import javax.sql.DataSource;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

/** Against a real database (gnomon.test.url or GNOMON_TEST_URL, with a JDBC driver); skipped otherwise. */
class GnomonDbTest {
  static String url() {
    return System.getProperty("gnomon.test.url", System.getenv("GNOMON_TEST_URL"));
  }

  static void exec(Connection c, String sql) throws SQLException {
    try (Statement s = c.createStatement()) {
      s.execute(sql);
    }
  }

  static long count(Connection c) throws SQLException {
    try (Statement s = c.createStatement(); ResultSet r = s.executeQuery("select count(*) from jv_item")) {
      r.next();
      return r.getLong(1);
    }
  }

  static DataSource ds() {
    return new DataSource() {
      public Connection getConnection() throws SQLException { return DriverManager.getConnection(url()); }
      public Connection getConnection(String u, String p) throws SQLException { return getConnection(); }
      public PrintWriter getLogWriter() { return null; }
      public void setLogWriter(PrintWriter out) {}
      public void setLoginTimeout(int s) {}
      public int getLoginTimeout() { return 0; }
      public Logger getParentLogger() { return null; }
      public <T> T unwrap(Class<T> i) { return null; }
      public boolean isWrapperFor(Class<?> i) { return false; }
    };
  }

  @Test
  void aRealBranch() throws Exception {
    Assumptions.assumeTrue(url() != null, "no gnomon.test.url");
    try (Connection c = DriverManager.getConnection(url())) {
      exec(c, "drop table if exists jv_item; create table jv_item (id int primary key, name text); select gnomon.track('jv_item')");
      String b = Gnomon.createScratch(c, "jv", "main");
      try {
        Gnomon.use(c, b);
        exec(c, "insert into jv_item values (1, 'session')");
        assertEquals(1, count(c));
        SQLException e = assertThrows(SQLException.class, () -> exec(c, "alter table jv_item add column z int"));
        assertEquals("ddl_on_branch", Gnomon.code(e), "plain DDL on a branch session, by its code");
        Gnomon.use(c, "main");
        assertEquals(0, count(c), "main does not see it");

        Gnomon.withBranch(ds(), b, x -> { exec(x, "insert into jv_item values (2, 'withBranch')"); return null; });
        BranchDataSource tds = new BranchDataSource(ds(), BranchDataSource.Mode.TRANSACTION);
        BranchDataSource.on(b, () -> {
          try (Connection x = tds.getConnection()) {
            x.setAutoCommit(false);
            exec(x, "insert into jv_item values (3, 'transaction mode')");
            x.commit();
          }
          return null;
        });
        assertEquals(0, count(c), "main still sees none");
        String opts = Gnomon.connectionOptions(c, b, false);
        try (Connection y = DriverManager.getConnection(Gnomon.withOptions(url(), opts))) {
          assertEquals(3, count(y), "a connection from the branch's options sees all three");
        }
      } finally {
        Gnomon.dropBranch(c, b);
        exec(c, "select gnomon.untrack('jv_item'); drop table jv_item");
      }
    }
  }

  @ExtendWith(GnomonBranchExtension.class)
  static class OnScratch {
    @Test
    void writes(Connection c) throws Exception {
      String b = Gnomon.value(c, "select current_setting('gnomon.branch')");
      assertTrue(b.startsWith("junit/"), b);
    }
  }

  @Test
  void theExtensionOnARealDatabase() {
    Assumptions.assumeTrue(url() != null, "no gnomon.test.url");
    var s = new org.junit.platform.launcher.listeners.SummaryGeneratingListener();
    org.junit.platform.launcher.core.LauncherFactory.create().execute(
        org.junit.platform.launcher.core.LauncherDiscoveryRequestBuilder.request()
            .selectors(org.junit.platform.engine.discovery.DiscoverySelectors.selectClass(OnScratch.class)).build(), s);
    s.getSummary().getFailures().forEach(f -> f.getException().printStackTrace());
    assertEquals(1, s.getSummary().getTestsSucceededCount());
  }
}
