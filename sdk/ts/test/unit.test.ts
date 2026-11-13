import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { parseJSON, splitSQL, toGnomonError, SerializationError, UnsupportedOnBranchError, PermissionError, StatementTimeoutError, NotRoutedError } from "../src/index.ts";
import { normalizeDiff } from "../src/testing.ts";
import { toolSpecs } from "../src/tools.ts";
import { nodePostgres } from "../src/pg.ts";
import { root } from "./env.ts";

test("lossless JSON: big integers and decimals a float would change", () => {
  const v = parseJSON('{"a": 9007199254740993, "b": 1.5, "c": 0.10000000000000000555, "d": 12, "e": 1.50}') as Record<string, unknown>;
  assert.equal(v.a, 9007199254740993n);
  assert.equal(v.b, 1.5);
  assert.equal(v.c, "0.10000000000000000555");
  assert.equal(v.d, 12);
  assert.equal(v.e, "1.50");
  assert.equal((parseJSON('{"a": 9007199254740993}', "string") as Record<string, unknown>).a, "9007199254740993");
});

test("one statement per call", () => {
  assert.equal(splitSQL("select 1").length, 1);
  assert.equal(splitSQL("select 1;").length, 1);
  assert.equal(splitSQL("select ';' as x; -- trailing comment").length, 1);
  assert.equal(splitSQL("select $$a;b$$; select 2").length, 2);
  assert.equal(splitSQL("select 1; select 2").length, 2);
});

test("errors are typed by SQLSTATE and slug", () => {
  assert.ok(toGnomonError({ code: "40001", message: "x" }) instanceof SerializationError);
  assert.ok(toGnomonError({ code: "42P10", message: "there is no unique or exclusion constraint matching the ON CONFLICT specification" }) instanceof UnsupportedOnBranchError);
  assert.ok(toGnomonError({ code: "42501", message: "permission denied" }) instanceof PermissionError);
  assert.ok(toGnomonError({ code: "57014", message: "canceling statement" }) instanceof StatementTimeoutError);
  const e = toGnomonError({ code: "55000", message: "session is on branch", hint: "Call gnomon.use. [gnomon:not_routed]" });
  assert.ok(e instanceof NotRoutedError);
  assert.equal(e.code, "not_routed");
});

test("snapshot golden files (shared with the Python SDK)", () => {
  const dir = path.join(root, "sdk/spec/snapshot");
  for (const f of fs.readdirSync(dir)) {
    const g = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8"));
    assert.deepEqual(normalizeDiff(g.diff, { ignore: g.ignore, foreignKeys: g.foreign_keys }), g.expected, f);
  }
});

test("the tool descriptions are the specification's", () => {
  const spec = JSON.parse(fs.readFileSync(path.join(root, "sdk/spec/tools.json"), "utf8"));
  assert.deepEqual(toolSpecs, spec.tools);
});

test("a node-postgres Client runs one call at a time", async () => {
  // (agent frameworks run a step's tool calls together; on one connection their envelopes must not interleave)
  const log: string[] = [];
  let busy = false;
  const client = {
    async query(cfg: { text: string }) {
      if (busy) throw new Error(`interleaved at ${cfg.text}`);
      busy = true;
      await new Promise((r) => setTimeout(r, 2));
      log.push(cfg.text);
      busy = false;
      return { rows: [], fields: [], rowCount: 0 };
    },
  };
  const a = nodePostgres(client);
  await Promise.all([
    a.transaction(async (q) => { await q.query("s1"); await q.query("t1"); }),
    a.transaction(async (q) => { await q.query("s2"); throw new Error("fails"); }).catch(() => {}),
    a.query("q3"),
  ]);
  assert.deepEqual(log, ["begin", "s1", "t1", "commit", "begin", "s2", "rollback", "q3"]);
});
