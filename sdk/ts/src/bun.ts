// Bun's built-in client (import { SQL } from "bun"): sql.unsafe(text, params), sql.begin(fn). Its
// results are arrays of rows with count and command; it reports no column list, so fields come
// from the first row. (Behind a transaction pooler, create it with prepare: false.)
import type { Adapter, Queryable } from "./index.ts";

interface BunSql {
  unsafe(q: string, params?: unknown[]): Promise<Record<string, unknown>[] & { count?: number | null; command?: string }>;
  begin<T>(fn: (sql: BunSql) => Promise<T>): Promise<T>;
  close?(): Promise<void>;
  end?(): Promise<void>;
}

function wrap(sql: BunSql): Queryable {
  return {
    async query(text, params = []) {
      const r = await sql.unsafe(text, params as unknown[]);
      const rows = [...r].map((x) => ({ ...x }));
      return { rows, fields: rows.length ? Object.keys(rows[0]) : [], rowCount: r.count ?? rows.length };
    },
  };
}

export function bunSql(sql: BunSql): Adapter {
  return {
    query: wrap(sql).query,
    transaction: (fn) => sql.begin((tx) => fn(wrap(tx))),
    async release() { await (sql.close ?? sql.end)?.call(sql); },
  };
}
