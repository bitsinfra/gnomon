package dev.gnomon;

import java.lang.reflect.Proxy;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.function.Function;

/** A JDBC connection that records what it is asked and answers from a function (no driver needed). */
final class FakeDb {
  final List<String> log = new ArrayList<>();
  final Function<String, String> answer;

  FakeDb(Function<String, String> answer) {
    this.answer = answer;
  }

  Connection connection() {
    boolean[] auto = {true};
    return (Connection) Proxy.newProxyInstance(Connection.class.getClassLoader(), new Class<?>[] {Connection.class}, (p, m, a) -> {
      switch (m.getName()) {
        case "prepareStatement":
          return statement((String) a[0]);
        case "createStatement":
          log.add("statement");
          return null;
        case "getAutoCommit":
          return auto[0];
        case "setAutoCommit":
          auto[0] = (Boolean) a[0];
          log.add("autocommit " + a[0]);
          return null;
        case "commit": case "rollback": case "close":
          log.add(m.getName());
          return null;
        case "isClosed":
          return false;
        default:
          throw new UnsupportedOperationException(m.getName());
      }
    });
  }

  private PreparedStatement statement(String sql) {
    Object[] args = new Object[8];
    return (PreparedStatement) Proxy.newProxyInstance(PreparedStatement.class.getClassLoader(), new Class<?>[] {PreparedStatement.class}, (p, m, a) -> {
      switch (m.getName()) {
        case "setObject":
          args[(Integer) a[0] - 1] = a[1];
          return null;
        case "executeQuery":
          String call = sql + " " + Arrays.toString(Arrays.stream(args).filter(x -> x != null).toArray());
          log.add(call);
          return result(answer.apply(call));
        case "close":
          return null;
        default:
          throw new UnsupportedOperationException(m.getName());
      }
    });
  }

  private static ResultSet result(String value) {
    boolean[] read = {false};
    return (ResultSet) Proxy.newProxyInstance(ResultSet.class.getClassLoader(), new Class<?>[] {ResultSet.class}, (p, m, a) -> {
      switch (m.getName()) {
        case "next":
          boolean r = !read[0];
          read[0] = true;
          return r;
        case "getString":
          return value;
        case "close":
          return null;
        default:
          throw new UnsupportedOperationException(m.getName());
      }
    });
  }
}
