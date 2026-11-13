// The conformance scenarios through Bun's built-in client (bun test; test/shell/bun_sdk.sh starts a
// server Bun can reach over TCP).
import { test } from "bun:test";
import { SQL } from "bun";
import { bunSql } from "../../src/bun.ts";
import { host, port } from "../env.ts";
import { defineScenarios } from "../scenarios.ts";

defineScenarios((name, fn) => test(name, fn, 60000), [
  {
    name: "bun", prefix: "bun",
    connect(db, user) {
      const sql = new SQL({ hostname: host, port, username: user, database: db, max: 4 });
      return { adapter: bunSql(sql as never), close: () => sql.close() };
    },
  },
]);
