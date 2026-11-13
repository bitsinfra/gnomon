// The testing layer: a branch per test, and a diff normalized for a stored snapshot
// (spec: Snapshots). The same rules and golden files as the Python SDK (sdk/spec/snapshot).
import { stableJSON } from "./json.ts";
import type { AnyDB, Change, Gnomon } from "./index.ts";

export interface ForeignKey { table: string; columns: string[]; references: string; referenced_columns: string[] }

function cmpKey(a: Record<string, unknown>, b: Record<string, unknown>): number {
  const ka = Object.keys(a).sort();
  for (const k of ka) {
    const x = a[k], y = b[k];
    if (typeof x === "number" && typeof y === "number") { if (x !== y) return x - y; continue; }
    if (typeof x === "bigint" || typeof y === "bigint") { const d = BigInt(x as never) - BigInt(y as never); if (d) return d < 0n ? -1 : 1; continue; }
    const sx = String(x), sy = String(y);
    if (sx !== sy) return sx < sy ? -1 : 1;
  }
  return 0;
}

const short = (t: string) => t.split(".").pop()!;

/** Normalize a diff for a snapshot: placeholders for keys, foreign keys followed, columns ignored. */
export function normalizeDiff(diff: Change[] | Record<string, unknown>[], opts: { ignore?: string[]; foreignKeys?: ForeignKey[] } = {}): string[] {
  const rows = (diff as Record<string, unknown>[]).map((d) => ({
    table: String(d.table), key: d.key as Record<string, unknown>, kind: String(d.kind),
    col: ((d as { column?: string }).column ?? (d as { col?: string }).col ?? null) as string | null, old: d.old, new: d.new,
  }));
  const ignore = new Set(opts.ignore ?? []);
  // placeholders per table, in ascending key order
  const byTable = new Map<string, Record<string, unknown>[]>();
  for (const r of rows) {
    const ks = byTable.get(r.table) ?? [];
    if (!ks.some((k) => stableJSON(k) === stableJSON(r.key))) ks.push(r.key);
    byTable.set(r.table, ks);
  }
  const ph = new Map<string, string>();       // table|key json -> placeholder
  const phIndex = new Map<string, number>();
  for (const [t, ks] of byTable) {
    ks.sort(cmpKey).forEach((k, i) => {
      ph.set(`${t}|${stableJSON(k)}`, `<${short(t)}:${i + 1}>`);
      phIndex.set(`${t}|${stableJSON(k)}`, i + 1);
    });
  }
  const fks = opts.foreignKeys ?? [];
  const value = (table: string, key: Record<string, unknown>, col: string, v: unknown): string => {
    if (Object.keys(key).length === 1 && col in key) return ph.get(`${table}|${stableJSON(key)}`) ?? stableJSON(v);
    for (const f of fks) {
      if (f.table === table && f.columns.length === 1 && f.columns[0] === col) {
        const p = ph.get(`${f.references}|${stableJSON({ [f.referenced_columns[0]]: v })}`);
        if (p) return p;
      }
    }
    return stableJSON(v);
  };
  const lines: { t: string; i: number; s: string }[] = [];
  for (const r of rows) {
    const id = `${r.table}|${stableJSON(r.key)}`;
    const p = ph.get(id)!;
    const i = phIndex.get(id)!;
    if (r.kind === "delete") { lines.push({ t: r.table, i, s: `${r.table} ${p} delete` }); continue; }
    if (r.kind === "insert") {
      const img = (r.new ?? {}) as Record<string, unknown>;
      for (const c of Object.keys(img)) {
        if (ignore.has(c)) continue;
        lines.push({ t: r.table, i, s: `${r.table} ${p} insert ${c} = ${value(r.table, r.key, c, img[c])}` });
      }
      continue;
    }
    if (r.col === null || ignore.has(r.col)) continue;
    lines.push({ t: r.table, i, s: `${r.table} ${p} update ${r.col}: ${value(r.table, r.key, r.col, r.old)} -> ${value(r.table, r.key, r.col, r.new)}` });
  }
  const uniq = [...new Map(lines.map((l) => [l.s, l])).values()];
  uniq.sort((a, b) => (a.t !== b.t ? (a.t < b.t ? -1 : 1) : a.i !== b.i ? a.i - b.i : a.s < b.s ? -1 : a.s > b.s ? 1 : 0));
  return uniq.map((l) => l.s);
}

/** A branch's diff as snapshot text, for expect(...).toMatchSnapshot() or a stored file. */
export async function gnomonDiff(g: Gnomon<AnyDB>, branch: string, opts: { ignore?: string[] } = {}): Promise<string> {
  const d = await g.diff(branch);
  const describe = await g.describe() as { tables: { schema: string; name: string; foreign_keys: { columns: string[]; references: string; referenced_columns: string[] }[] }[] };
  const fks: ForeignKey[] = [];
  for (const t of describe.tables ?? []) {
    for (const f of t.foreign_keys ?? []) {
      fks.push({ table: `${t.schema}.${t.name}`, columns: f.columns, references: f.references.includes(".") ? f.references : `${t.schema}.${f.references}`, referenced_columns: f.referenced_columns });
    }
  }
  const qualify = (x: { table: string }) => ({ ...x, table: x.table.includes(".") ? x.table : `public.${x.table}` });
  return normalizeDiff((d as unknown as Change[]).map(qualify) as Change[], { ignore: opts.ignore, foreignKeys: fks }).join("\n") + "\n";
}

/** Nothing changed in these tables on the branch. */
export async function assertNoChanges(g: Gnomon<AnyDB>, branch: string, tables?: string[]): Promise<void> {
  const d = await g.diff(branch);
  const hit = d.filter((x) => !tables || tables.some((t) => x.table === t || x.table.endsWith("." + t)));
  if (hit.length) throw new Error(`expected no changes${tables ? " to " + tables.join(", ") : ""}, found ${hit.length}: ${stableJSON(hit.slice(0, 5))}`);
}

/** One field of one row changed to a value on the branch. */
export async function assertChanged(g: Gnomon<AnyDB>, branch: string, table: string, key: unknown, column: string, value: unknown): Promise<void> {
  const d = await g.diff(branch);
  const ok = d.some((x) => (x.table === table || x.table.endsWith("." + table)) && stableJSON(x.key) === stableJSON(key) &&
    ((x.kind === "update" && x.column === column && stableJSON(x.new) === stableJSON(value)) ||
     (x.kind === "insert" && stableJSON((x.new as Record<string, unknown>)?.[column]) === stableJSON(value))));
  if (!ok) throw new Error(`expected ${table} ${stableJSON(key)}.${column} = ${stableJSON(value)} on ${branch}`);
}

/** A scratch branch for one test (Jest, Vitest, node:test): created, then dropped. */
export async function withScratch<T>(g: Gnomon<AnyDB>, fn: (branch: string) => Promise<T>, prefix = "test"): Promise<T> {
  const b = await g.branches.scratch(prefix);
  try { return await fn(b); } finally { await g.branches.drop(b).catch(() => {}); }
}
