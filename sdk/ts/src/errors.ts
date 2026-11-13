// Typed errors (spec: Errors). The SQLSTATE stays the standard one; the slug in the hint
// ([gnomon:<slug>]) is gnomon's stable code.

export class GnomonError extends Error {
  code: string | undefined;
  sqlstate: string | undefined;
  hint: string | undefined;
  constructor(message: string, opts: { code?: string; sqlstate?: string; hint?: string; cause?: unknown } = {}) {
    super(message, { cause: opts.cause });
    this.name = new.target.name;
    this.code = opts.code;
    this.sqlstate = opts.sqlstate;
    this.hint = opts.hint;
  }
}
export class SerializationError extends GnomonError {}
export class PermissionError extends GnomonError {}
export class BranchClosedError extends GnomonError {}
export class StatementTimeoutError extends GnomonError {}
export class UnsupportedOnBranchError extends GnomonError {}
export class NotRoutedError extends GnomonError {}
export class OverQuotaError extends GnomonError {}
export class ChecksFailedError extends GnomonError {
  results: unknown;
  constructor(message: string, opts: { code?: string; sqlstate?: string; hint?: string; cause?: unknown; results?: unknown } = {}) {
    super(message, opts);
    this.results = opts.results;
  }
}
export class MergeConflictError extends GnomonError {
  mergeId: number;
  conflicts: unknown[];
  constructor(message: string, mergeId: number, conflicts: unknown[]) {
    super(message, { code: "merge_conflict" });
    this.mergeId = mergeId;
    this.conflicts = conflicts;
  }
}
export class IncompatibleVersionError extends GnomonError {}

const SLUG = /\[gnomon:([a-z_]+)\]/;

/**
 * Map a driver error to a typed gnomon error. The SQLSTATE is `code` for node-postgres,
 * postgres.js and Neon, `errno` for Bun's client (whose `code` is its own).
 */
export function toGnomonError(err: unknown): GnomonError {
  if (err instanceof GnomonError) return err;
  const e = err as { code?: string; errno?: unknown; message?: string; hint?: string; detail?: string };
  const sqlstate = [e?.code, e?.errno].find((x): x is string => typeof x === "string" && /^[0-9A-Z]{5}$/.test(x));
  const hint = e?.hint;
  const slug = (SLUG.exec(`${hint ?? ""} ${e?.message ?? ""}`) ?? [])[1];
  const msg = e?.message ?? String(err);
  const opts = { code: slug, sqlstate, hint, cause: err };
  if (sqlstate === "40001") return new SerializationError(msg, opts);
  if (sqlstate === "57014") return new StatementTimeoutError(msg, opts);
  if (sqlstate === "42P10" || slug === "sql_only_dml" || slug === "upsert_on_branch") return new UnsupportedOnBranchError(
    msg + " (on a branch, write an upsert as UPDATE then INSERT ... WHERE NOT EXISTS, or load gnomon's C module)", opts);
  if (slug === "not_routed") return new NotRoutedError(msg, opts);
  if (sqlstate === "25006" || slug === "branch_closed") return new BranchClosedError(msg, opts);
  if (sqlstate === "53400" || slug === "over_quota") return new OverQuotaError(msg, opts);
  if (sqlstate === "23514") return new ChecksFailedError(msg, opts);
  if (sqlstate === "42501") return new PermissionError(msg, opts);
  return new GnomonError(msg, opts);
}
