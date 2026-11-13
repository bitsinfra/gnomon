// The conformance suite: scenarios written as data in sdk/spec/conformance, run
// through each driver adapter. The Python SDK runs the same files; Bun runs them through its own
// client (bun.test.ts).
import { test } from "node:test";
import pg from "pg";
import postgres from "postgres";
import { nodePostgres } from "../src/pg.ts";
import { postgresJs } from "../src/postgres.ts";
import { kysely } from "../src/kysely.ts";
import { neon } from "../src/neon.ts";
import { Kysely, PostgresDialect, CompiledQuery } from "kysely";
import { host, port } from "./env.ts";
import { defineScenarios } from "./scenarios.ts";

const pool = (db: string, user: string) => new pg.Pool({ host, port, user, database: db, max: 4 });

// Kysely's interface over a node-postgres pool, as Kysely's PostgresDialect drives it (kysely itself
// is not a dependency of the SDK)
function kyselyOver(p: pg.Pool) {
  const over = (c: { query: (t: string, v: unknown[]) => Promise<pg.QueryResult> }): any => ({
    async executeQuery(cq: { sql: string; parameters: unknown[] }) {
      const r = await c.query(cq.sql, cq.parameters as unknown[]);
      return { rows: r.rows, numAffectedRows: ["INSERT", "UPDATE", "DELETE", "MERGE"].includes(r.command) ? BigInt(r.rowCount ?? 0) : undefined };
    },
    transaction: () => ({
      async execute(fn: (trx: unknown) => Promise<unknown>) {
        const cl = await p.connect();
        try {
          await cl.query("begin");
          const x = await fn(over(cl));
          await cl.query("commit");
          return x;
        } catch (e) {
          await cl.query("rollback").catch(() => {});
          throw e;
        } finally { cl.release(); }
      },
    }),
    destroy: () => p.end(),
  });
  return over(p);
}

// Neon's HTTP interface (query, and transaction over queries given in advance) over a pool
function neonHttpOver(p: pg.Pool) {
  const run = async (c: { query: (t: string, v: unknown[]) => Promise<pg.QueryResult> }, text: string, params: unknown[]) => {
    const r = await c.query(text, params);
    return { rows: r.rows, fields: r.fields, rowCount: r.rowCount };
  };
  return {
    query(text: string, params: unknown[] = []) {
      return { text, params, then: (a: any, b: any) => run(p, text, params).then(a, b) };
    },
    async transaction(queries: any[]) {
      const cl = await p.connect();
      try {
        await cl.query("begin");
        const out = [];
        for (const q of queries) out.push(await run(cl, q.text, q.params));
        await cl.query("commit");
        return out;
      } catch (e) {
        await cl.query("rollback").catch(() => {});
        throw e;
      } finally { cl.release(); }
    },
  };
}

defineScenarios(test, [
  { name: "pg", prefix: "pg", connect(db, user) { const p = pool(db, user); return { adapter: nodePostgres(p), close: () => p.end() }; } },
  {
    name: "postgres.js", prefix: "pjs",
    connect(db, user) {
      // behind a transaction pooler named prepared statements do not survive (as with pgbouncer)
      const s = postgres({ host, port, username: user, database: db, max: 4, onnotice: () => {}, prepare: !process.env.GNOMON_SDK_POOLED });
      return { adapter: postgresJs(s as never), close: () => s.end() };
    },
  },
  { name: "kysely", prefix: "ky", connect(db, user) { const p = pool(db, user); return { adapter: kysely(kyselyOver(p)), close: () => p.end() }; } },
  {
    // Kysely itself, with its PostgresDialect over a node-postgres pool
    name: "kysely (real)", prefix: "kr",
    connect(db, user) {
      const k = new Kysely<any>({ dialect: new PostgresDialect({ pool: pool(db, user) }) });
      return { adapter: kysely(k as never, CompiledQuery), close: () => k.destroy() };
    },
  },
  { name: "neon-http", prefix: "nh", connect(db, user) { const p = pool(db, user); return { adapter: neon({ http: neonHttpOver(p) as never }), close: () => p.end() }; } },
  { name: "neon-ws", prefix: "nw", connect(db, user) { const p = pool(db, user); return { adapter: neon({ pool: p as never }), close: () => p.end() }; } },
]);
