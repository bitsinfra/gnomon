package dev.gnomon;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.gnomon.junit.GnomonBranchExtension;
import java.io.PrintWriter;
import java.sql.Connection;
import java.sql.SQLException;
import java.util.List;
import java.util.logging.Logger;
import javax.sql.DataSource;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.junit.platform.launcher.Launcher;
import org.junit.platform.launcher.core.LauncherFactory;
import org.junit.platform.launcher.listeners.SummaryGeneratingListener;
import org.junit.platform.launcher.listeners.TestExecutionSummary;

import static org.junit.platform.engine.discovery.DiscoverySelectors.selectClass;
import static org.junit.platform.launcher.core.LauncherDiscoveryRequestBuilder.request;

class GnomonTest {
  @Test
  void branchOptions() {
    assertEquals("-c gnomon.branch=feature", Gnomon.branchOptions("feature", true));
    assertEquals("-c gnomon.branch=feature -c search_path=gnomon_r_public,public", Gnomon.branchOptions("feature", false));
    assertEquals("-c gnomon.branch=f -c search_path=gnomon_r_app,app,gnomon_r_public,public", Gnomon.branchOptions("f", false, "app", "public"));
    assertEquals("gnomon_r_app__s", Gnomon.routingSchema("app", true));
  }

  @Test
  void urls() {
    assertEquals("jdbc:postgresql://db/app?options=-c%20gnomon.branch%3Dfeature", Gnomon.jdbcUrl("jdbc:postgresql://db/app", "feature", true));
    assertEquals("jdbc:postgresql://db/app?ssl=true&options=-c%20gnomon.branch%3Dx", Gnomon.jdbcUrl("jdbc:postgresql://db/app?ssl=true", "x", true));
    assertEquals("select gnomon.use('it''s')", Gnomon.connectionInitSql("it's"));
  }

  @Test
  void errorCodes() {
    SQLException e = new SQLException("cannot run ALTER TABLE on a branch session [gnomon:ddl_on_branch]", "0A000");
    assertEquals("ddl_on_branch", Gnomon.code(e));
    assertEquals("ddl_on_branch", Gnomon.code(new SQLException("wrapped", new SQLException("x [gnomon:ddl_on_branch]"))));
    assertNull(Gnomon.code(new SQLException("plain")));
  }

  @Test
  void callsAndMerge() throws SQLException {
    FakeDb db = new FakeDb(sql -> sql.startsWith("select gnomon.merge") ? "42" : sql.startsWith("select status") ? "merged" : "ok");
    Connection c = db.connection();
    assertEquals("ok", Gnomon.use(c, "feature"));
    assertEquals("merged", Gnomon.merge(c, "feature", null));
    assertEquals(List.of("select gnomon.use(?) [feature]", "select gnomon.merge(?, ?)::text [feature]", "select status from gnomon.merge where id = ?::bigint [42]"), db.log);
  }

  static DataSource ds(FakeDb db) {
    return new DataSource() {
      public Connection getConnection() { return db.connection(); }
      public Connection getConnection(String u, String p) { return db.connection(); }
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
  void withBranchCommitsOrRollsBack() throws SQLException {
    FakeDb db = new FakeDb(sql -> "");
    assertEquals(Integer.valueOf(7), Gnomon.<Integer>withBranch(ds(db), "feature", c -> 7));
    assertEquals(List.of("autocommit false", "select gnomon.begin(?) [feature]", "commit", "autocommit true", "close"), db.log);
    db.log.clear();
    assertThrows(SQLException.class, () -> Gnomon.withBranch(ds(db), "feature", c -> { throw new SQLException("boom"); }));
    assertEquals(List.of("autocommit false", "select gnomon.begin(?) [feature]", "rollback", "autocommit true", "close"), db.log);
  }

  @Test
  void branchDataSource() throws Exception {
    FakeDb db = new FakeDb(sql -> "");
    BranchDataSource bds = new BranchDataSource(ds(db));
    bds.getConnection();
    BranchDataSource.on("feature", () -> bds.getConnection());
    assertEquals("main", BranchDataSource.current());
    assertEquals(List.of("select gnomon.use(?) [main]", "select gnomon.use(?) [feature]"), db.log);
  }

  @Test
  void transactionModeBeginsEachTransaction() throws Exception {
    FakeDb db = new FakeDb(sql -> "");
    BranchDataSource bds = new BranchDataSource(ds(db), BranchDataSource.Mode.TRANSACTION);
    BranchDataSource.on("feature", () -> {
      Connection c = bds.getConnection();
      SQLException e = assertThrows(SQLException.class, c::createStatement);
      assertEquals("25000", e.getSQLState());
      c.setAutoCommit(false);
      c.createStatement();
      c.createStatement();
      c.commit();
      c.createStatement();
      c.rollback();
      return null;
    });
    assertEquals(List.of("autocommit false", "select gnomon.begin(?) [feature]", "statement", "statement", "commit",
        "select gnomon.begin(?) [feature]", "statement", "rollback"), db.log);
    db.log.clear();
    bds.getConnection().createStatement(); // main: nothing to route
    assertEquals(List.of("statement"), db.log);
  }

  static final FakeDb EXT = new FakeDb(sql -> sql.contains("md5(random()") ? "junit/abc" : "1");

  @ExtendWith(GnomonBranchExtension.class)
  static class Sample {
    @Test
    void usesBranch(Connection c) {
      assertTrue(EXT.log.contains("select gnomon.use(?) [junit/abc]"));
    }
  }

  @Test
  void extensionGivesEachTestAScratchBranch() {
    GnomonBranchExtension.opener = EXT::connection;
    Launcher l = LauncherFactory.create();
    SummaryGeneratingListener s = new SummaryGeneratingListener();
    try {
      l.execute(request().selectors(selectClass(Sample.class)).build(), s);
    } finally {
      GnomonBranchExtension.opener = GnomonBranchExtension.DEFAULT_OPENER;
    }
    TestExecutionSummary sum = s.getSummary();
    sum.getFailures().forEach(f -> f.getException().printStackTrace());
    assertEquals(1, sum.getTestsSucceededCount());
    assertEquals(List.of(
        "select ? || '/' || substr(md5(random()::text), 1, 10) [junit]",
        "select gnomon.create_branch(?, ?, ?)::text [junit/abc, main, scratch]",
        "select gnomon.use(?) [junit/abc]",
        "select gnomon.use(?) [main]",
        "select gnomon.drop_branch(?, true)::text [junit/abc]",
        "close"), EXT.log);
  }
}
