// postgres.js adapter. (postgres.js has no switch for the extended protocol without parameters;
// the SDK's own splitter refuses a second statement.)
import type { Adapter, Queryable } from "./index.ts";

interface Sql {
  unsafe(q: string, params?: unknown[]): Promise<Record<string, unknown>[] & { count?: number; columns?: { name: string }[] }>;
  begin<T>(fn: (sql: Sql) => Promise<T>): Promise<T>;
  end?(): Promise<void>;
}

function wrap(sql: Sql): Queryable {
  return {
    async query(text, params = []) {
      const r = await sql.unsafe(text, params as never[]);
      return { rows: [...r], fields: (r.columns ?? []).map((c) => c.name), rowCount: r.count ?? r.length };
    },
  };
}

export function postgresJs(sql: Sql): Adapter {
  return {
    query: wrap(sql).query,
    transaction: (fn) => sql.begin((tx) => fn(wrap(tx))) as never,
    async release() { await sql.end?.(); },
  };
}
