# gnomon for Java

Branches of a PostgreSQL database with gnomon from JDBC, and a JUnit 5 extension that gives
each test its own scratch branch of one seeded database. It uses only `java.sql`, so it works
with any driver (pgjdbc, the Hikari pool, jOOQ, Hibernate over JDBC), and from Kotlin as it is.

```java
// sessions that start on a branch (pgjdbc reads options from the URL)
String url = Gnomon.jdbcUrl("jdbc:postgresql://db/app", "feature", false); // true with the C module

// or ask the database what a branch needs (schema versions, masks)
String opts = Gnomon.connectionOptions(conn, "feature", false);
String url2 = Gnomon.withOptions("jdbc:postgresql://db/app", opts);

// every connection of a Hikari pool on a branch
hikari.setConnectionInitSql(Gnomon.connectionInitSql("feature"));

// a request's branch, chosen per thread (gnomon.use on each connection handed out)
DataSource ds = new BranchDataSource(hikari);
BranchDataSource.on("feature", () -> repo.save(order));

// Spring behind a transaction pooler (pgbouncer pool_mode=transaction): gnomon.begin before the
// first statement of each transaction, no session state; @Transactional works unchanged
@Bean DataSource dataSource(HikariDataSource hikari) {
  return new BranchDataSource(hikari, BranchDataSource.Mode.TRANSACTION);
}
// a servlet filter or HandlerInterceptor wraps the request: BranchDataSource.on(branch, chain::doFilter)

// one transaction on a branch, by hand
Gnomon.withBranch(ds, "feature", c -> { /* ... */ return null; });

// errors: the stable slug, and what the database says about it
catch (SQLException e) { if ("ddl_on_branch".equals(Gnomon.code(e))) ... Gnomon.explain(conn, e); }
```

## JUnit 5

```java
@ExtendWith(GnomonBranchExtension.class)
class SignupTest {
  @Test void signup(Connection c) throws Exception {
    c.createStatement().execute("insert into users(email) values ('a@example.com')");
  }
}
```

Run the tests with `-Dgnomon.test.url=jdbc:postgresql://localhost/app_test?user=app` (or
`GNOMON_TEST_URL`) and a JDBC driver on the test classpath. Each test runs on a scratch branch of
main, dropped afterwards; `GNOMON_KEEP=1` keeps them for a look.

## Tests

`./test.sh` compiles and runs the tests with `javac` and the JUnit jars in the local Maven
repository; `mvn test` does the same. They use a fake JDBC connection, so they need no database.
