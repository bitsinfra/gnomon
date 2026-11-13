package dev.gnomon.junit;

import dev.gnomon.Gnomon;
import java.sql.Connection;
import java.sql.DriverManager;
import org.junit.jupiter.api.extension.AfterEachCallback;
import org.junit.jupiter.api.extension.BeforeEachCallback;
import org.junit.jupiter.api.extension.ExtensionContext;
import org.junit.jupiter.api.extension.ParameterContext;
import org.junit.jupiter.api.extension.ParameterResolver;

/**
 * JUnit 5: each test gets a connection on its own scratch branch of one seeded database, dropped
 * afterwards (GNOMON_KEEP=1 keeps it). The database: the gnomon.test.url system property or the
 * GNOMON_TEST_URL environment variable (a JDBC URL).
 *
 * <pre>
 *   &#64;ExtendWith(GnomonBranchExtension.class)
 *   class SignupTest {
 *     &#64;Test void signup(Connection c) throws Exception { c.createStatement().execute("insert ..."); }
 *   }
 * </pre>
 */
public final class GnomonBranchExtension implements BeforeEachCallback, AfterEachCallback, ParameterResolver {
  private static final ExtensionContext.Namespace NS = ExtensionContext.Namespace.create(GnomonBranchExtension.class);

  /** How the extension opens connections (tests replace it). */
  public interface Opener {
    Connection open() throws Exception;
  }

  /** The default: DriverManager on gnomon.test.url or GNOMON_TEST_URL. */
  public static final Opener DEFAULT_OPENER = () -> {
    String url = System.getProperty("gnomon.test.url", System.getenv("GNOMON_TEST_URL"));
    if (url == null) {
      throw new IllegalStateException("set -Dgnomon.test.url or GNOMON_TEST_URL to a JDBC URL of a seeded database with gnomon");
    }
    return DriverManager.getConnection(url);
  };

  public static Opener opener = DEFAULT_OPENER;

  @Override
  public void beforeEach(ExtensionContext ctx) throws Exception {
    Connection c = opener.open();
    String branch = Gnomon.createScratch(c, "junit", "main");
    Gnomon.use(c, branch);
    ctx.getStore(NS).put("conn", c);
    ctx.getStore(NS).put("branch", branch);
  }

  @Override
  public void afterEach(ExtensionContext ctx) throws Exception {
    Connection c = ctx.getStore(NS).remove("conn", Connection.class);
    String branch = ctx.getStore(NS).remove("branch", String.class);
    if (c == null) {
      return;
    }
    try {
      if (!"1".equals(System.getenv("GNOMON_KEEP"))) {
        Gnomon.use(c, "main");
        Gnomon.dropBranch(c, branch);
      }
    } finally {
      c.close();
    }
  }

  @Override
  public boolean supportsParameter(ParameterContext p, ExtensionContext ctx) {
    return p.getParameter().getType() == Connection.class;
  }

  @Override
  public Object resolveParameter(ParameterContext p, ExtensionContext ctx) {
    return ctx.getStore(NS).get("conn", Connection.class);
  }
}
