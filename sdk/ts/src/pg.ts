// node-postgres adapter: a Pool or a Client. Statements of a run go by the extended protocol
// (queryMode: "extended"), so PostgreSQL itself refuses a second statement.
import type { Adapter, QueryResult, Queryable } from "./index.ts";

interface PgLike {
  query(cfg: { text: string; values?: unknown[]; queryMode?: string }): Promise<{ rows: Record<string, unknown>[]; fields?: { name: string }[]; rowCount: number | null }>;
}
interface PoolLike extends PgLike { connect(): Promise<PgLike & { release(): void }>; end?(): Promise<void> }

function wrap(c: PgLike): Queryable {
  return {
    async query(text, params = [], opts = {}) {
      const r = await c.query({ text, values: params, ...(opts.oneStatement ? { queryMode: "extended" } : {}) });
      return { rows: r.rows, fields: (r.fields ?? []).map((f) => f.name), rowCount: r.rowCount } satisfies QueryResult;
    },
  };
}

export function nodePostgres(pool: PoolLike | PgLike): Adapter {
  const isPool = typeof (pool as PoolLike).connect === "function" && (pool as { totalCount?: number }).totalCount !== undefined;
  // A Client is used one call at a time: concurrent calls (an agent framework running a step's
  // tool calls together) would otherwise interleave their envelopes in one transaction.
  let last: Promise<unknown> = Promise.resolve();
  const oneAtATime = <T>(f: () => Promise<T>): Promise<T> => {
    const p = last.then(f, f);
    last = p.catch(() => {});
    return p;
  };
  const transaction = async <T>(c: PgLike, fn: (q: Queryable) => Promise<T>): Promise<T> => {
    await c.query({ text: "begin" });
    try {
      const out = await fn(wrap(c));
      await c.query({ text: "commit" });
      return out;
    } catch (e) {
      await c.query({ text: "rollback" }).catch(() => {});
      throw e;
    }
  };
  return {
    query: isPool ? wrap(pool).query : (text, params, opts) => oneAtATime(() => wrap(pool).query(text, params, opts)),
    async transaction(fn) {
      if (!isPool) return oneAtATime(() => transaction(pool, fn));
      const c = await (pool as PoolLike).connect();
      try {
        return await transaction(c, fn);
      } finally {
        c.release();
      }
    },
    async release() { if (isPool) await (pool as PoolLike).end?.(); },
  };
}
