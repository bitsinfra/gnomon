// Neon's serverless driver (@neondatabase/serverless). Its WebSocket Pool is node-postgres's API,
// so with a pool every statement and transaction goes through it as with pg. Over HTTP alone
// (neon(url)) a transaction is one request holding statements known in advance: the envelope fits
// (gnomon.begin, the attribution note and the timeouts are sent with the statement they wrap, so
// run.sql and the other single-statement calls work); run.transaction(fn) with several statements
// needs the pool, and says so.
import { GnomonError } from "./errors.ts";
import type { Adapter, Queryable, QueryResult } from "./index.ts";
import { nodePostgres } from "./pg.ts";

interface NeonFull { rows: Record<string, unknown>[]; fields?: { name: string }[]; rowCount?: number | null }
interface NeonHttp {
  query(text: string, params?: unknown[], opts?: { fullResults?: boolean }): PromiseLike<NeonFull> & object;
  transaction(queries: unknown[], opts?: { fullResults?: boolean }): Promise<NeonFull[]>;
}

// what the SDK sends before the statement of an envelope: results nobody reads
const PREAMBLE = /^\s*select\s+(gnomon\.begin\(|gnomon\.note\(|set_config\('statement_timeout')/i;

const result = (r: NeonFull): QueryResult => ({ rows: r.rows, fields: (r.fields ?? []).map((f) => f.name), rowCount: r.rowCount ?? r.rows.length });

export function neon(opts: { http?: NeonHttp; pool?: Parameters<typeof nodePostgres>[0] }): Adapter {
  if (opts.pool) {
    const p = nodePostgres(opts.pool);
    if (!opts.http) return p;
    const http = opts.http;
    return { ...p, async query(text, params = []) { return result(await http.query(text, params as unknown[], { fullResults: true })); } };
  }
  const http = opts.http;
  if (!http) throw new GnomonError("neon() needs http (neon(url)) or pool (new Pool())", { code: "neon_adapter" });
  return {
    async query(text, params = []) { return result(await http.query(text, params as unknown[], { fullResults: true })); },
    async transaction(fn) {
      const pending: unknown[] = [];
      let sent = false;
      const q: Queryable = {
        async query(text, params = []) {
          if (sent) {
            throw new GnomonError("Neon over HTTP runs one statement per transaction: give neon() a WebSocket pool for run.transaction() with several",
              { code: "neon_http_one_statement" });
          }
          pending.push(http.query(text, params as unknown[]));
          if (PREAMBLE.test(text)) return { rows: [], fields: [], rowCount: 0 };
          sent = true;
          const rs = await http.transaction(pending, { fullResults: true });
          return result(rs[rs.length - 1]);
        },
      };
      return fn(q);
    },
  };
}
