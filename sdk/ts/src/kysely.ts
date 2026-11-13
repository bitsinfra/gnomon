// Kysely: statements go through db.executeQuery with a raw compiled query, transactions through
// db.transaction().execute, so a Kysely instance an application already has (its dialect, pool and
// plugins) serves the SDK. Pass kysely's CompiledQuery to build the queries with it; without it the
// adapter builds the same raw shape itself.
import type { Adapter, Queryable } from "./index.ts";

interface CompiledQueryLike { sql: string; parameters: readonly unknown[]; query: unknown }
interface KyselyLike {
  executeQuery(q: CompiledQueryLike): Promise<{ rows: Record<string, unknown>[]; numAffectedRows?: bigint; numChangedRows?: bigint }>;
  transaction(): { execute<T>(fn: (trx: KyselyLike) => Promise<T>): Promise<T> };
  destroy?(): Promise<void>;
}
interface CompiledQueryClass { raw(sql: string, parameters?: unknown[]): CompiledQueryLike }

export function kysely(db: KyselyLike, CompiledQuery?: CompiledQueryClass): Adapter {
  const compile = (text: string, params: unknown[]): CompiledQueryLike =>
    CompiledQuery ? CompiledQuery.raw(text, params)
      : { sql: text, parameters: params, query: { kind: "RawNode", sqlFragments: [text], parameters: [] } };
  const wrap = (x: KyselyLike): Queryable => ({
    async query(text, params = []) {
      const r = await x.executeQuery(compile(text, params as unknown[]));
      const rows = r.rows ?? [];
      const n = r.numAffectedRows ?? r.numChangedRows;
      return { rows, fields: rows.length ? Object.keys(rows[0]) : [], rowCount: n !== undefined ? Number(n) : rows.length };
    },
  });
  return {
    query: wrap(db).query,
    transaction: (fn) => db.transaction().execute((trx) => fn(wrap(trx))),
    async release() { await db.destroy?.(); },
  };
}
