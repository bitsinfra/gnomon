// Lossless JSON (spec: Values): integers beyond 2^53 and decimals a float would not reproduce are
// taken from the JSON text, not through a float.

export type BigintMode = "bigint" | "string";

export function parseJSON(text: string | null | undefined, bigint: BigintMode = "bigint"): unknown {
  if (text === null || text === undefined) return null;
  return JSON.parse(text, (_k, v, ctx?: { source?: string }) => {
    if (typeof v !== "number" || !ctx?.source) return v;
    const src = ctx.source;
    if (/^-?\d+$/.test(src)) {
      if (Number.isSafeInteger(v)) return v;
      return bigint === "bigint" ? BigInt(src) : src;
    }
    // a decimal: the text, when the float would not print it back the same (precision, scale)
    return String(v) === src ? v : src;
  });
}

/** JSON text with object keys sorted (snapshots, digests). */
export function stableJSON(v: unknown): string {
  return JSON.stringify(sortKeys(v), (_k, x) => (typeof x === "bigint" ? x.toString() : x));
}

function sortKeys(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v && typeof v === "object" && !(v instanceof Date)) {
    const o = v as Record<string, unknown>;
    return Object.fromEntries(Object.keys(o).sort().map((k) => [k, sortKeys(o[k])]));
  }
  return v;
}
