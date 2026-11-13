// @bitsinfra/gnomon: gnomon for applications and the agents they run.
//
// Three layers. Runs: an agent's statements go to a branch of the database, inside an envelope
// that binds them to the run, attributes them and bounds them in time; the application reads what
// the run changed and accepts it, submits it for review, or discards it. Review: change requests,
// their reviews and comments, merge and undo. Core: branches, history, blame, revert, status.
// Every method is one SQL function call: the database is the only place with logic.

import {
  GnomonError, IncompatibleVersionError, MergeConflictError, ChecksFailedError, SerializationError, toGnomonError,
} from "./errors.ts";
import { parseJSON, type BigintMode } from "./json.ts";
import { splitSQL } from "./sqlsplit.ts";

export * from "./errors.ts";
export { parseJSON, stableJSON } from "./json.ts";
export { splitSQL } from "./sqlsplit.ts";

/** The SQL API versions this SDK speaks (gnomon.api_version()). */
export const SUPPORTED_API = { min: 2, max: 2 };

export interface QueryResult {
  rows: Record<string, unknown>[];
  fields: string[];
  rowCount: number | null;
}

/** One statement: parameters by position; `oneStatement` asks the driver for the extended protocol. */
export interface Queryable {
  query(sql: string, params?: unknown[], opts?: { oneStatement?: boolean }): Promise<QueryResult>;
}

/** A driver adapter: three functions (spec: Drivers). */
export interface Adapter extends Queryable {
  transaction<T>(fn: (q: Queryable) => Promise<T>): Promise<T>;
  release?(): Promise<void>;
}

export interface StatementEvent {
  run?: string;
  login: "app" | "runs";
  statement: string;
  durationMs: number;
  ok: boolean;
  error?: GnomonError;
  rowCount?: number | null;
}

/** A tracer shaped like @opentelemetry/api's (startActiveSpan(name, options, fn)). */
export interface TracerLike {
  startActiveSpan<T>(name: string, options: { attributes?: Record<string, unknown> }, fn: (span: SpanLike) => T): T;
}
export interface SpanLike {
  setAttribute(k: string, v: unknown): unknown;
  recordException?(e: unknown): unknown;
  setStatus?(s: { code: number; message?: string }): unknown;
  end(): unknown;
}

export interface GnomonOptions {
  /** The application's login: starts runs, reads them, accepts them. */
  app: Adapter;
  /** The login every run shares: confined, no grant on the base tables. */
  runs?: Adapter;
  /** Defaults for each run statement. */
  statementTimeoutMs?: number;
  lockTimeoutMs?: number;
  maxRows?: number;
  bigint?: BigintMode;
  onStatement?: (e: StatementEvent) => void;
  tracer?: TracerLike;
  /** Skip the version check at the first call (tests of older servers). */
  skipVersionCheck?: boolean;
  /** The database's connection string (host, port, database), for run.url() and run.connection(). */
  url?: string;
}

export type ChangeKind = "insert" | "update" | "delete";
export interface Change<Row = Record<string, unknown>> {
  table: string;
  key: Record<string, unknown>;
  kind: ChangeKind;
  /** The column of an update; null for inserts and deletes (old/new are then whole rows). */
  column: string | null;
  old: unknown;
  new: unknown;
  /** (typed per table with generated types) */
  _row?: Row;
}

/** A database's tables, as `gnomon types --lang ts` writes them: { "schema.table": { row, key } }. */
export type AnyDB = Record<string, { row: Record<string, unknown>; key: Record<string, unknown> }>;

/** A change typed by table: `table` narrows `key`, `old` and `new`. */
export type DiffOf<DB extends AnyDB> = {
  [T in keyof DB & string]:
    | { table: T; key: DB[T]["key"]; kind: "insert"; column: null; old: null; new: DB[T]["row"] }
    | { table: T; key: DB[T]["key"]; kind: "delete"; column: null; old: DB[T]["row"]; new: null }
    | { [C in keyof DB[T]["row"] & string]: { table: T; key: DB[T]["key"]; kind: "update"; column: C; old: DB[T]["row"][C]; new: DB[T]["row"][C] } }[keyof DB[T]["row"] & string]
}[keyof DB & string];

export interface Summary {
  version: number;
  branch: string;
  status: string;
  changes: { rows: number; tables: { table: string; inserts: number; updates: number; deletes: number }[] };
  checks: { passed: boolean; passed_count: number; failed_count: number; results: { check: string; passed: boolean; detail: string }[] };
  conflicts: number;
  warnings: { kind: string; table: string; key: unknown; detail: unknown }[];
  behind_main: number | null;
}

export interface SqlResult<T = Record<string, unknown>> {
  rows: T[];
  rowCount: number | null;
  fields: string[];
  truncated: boolean;
}

export interface StartRunOptions {
  task?: string;
  actor?: string;
  kind?: "logged" | "scratch";
  ttl?: string;
  parent?: string;
  /** a wall-clock limit for the whole run, in ms */
  deadlineMs?: number;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class Gnomon<DB extends AnyDB = AnyDB> {
  readonly app: Adapter;
  readonly runs: Adapter | undefined;
  readonly options: GnomonOptions;
  readonly requests: Requests<DB>;
  readonly branches: Branches<DB>;
  private checked: Promise<void> | undefined;

  constructor(options: GnomonOptions) {
    this.options = options;
    this.app = options.app;
    this.runs = options.runs;
    this.requests = new Requests(this);
    this.branches = new Branches(this);
  }

  /** Check once that the extension speaks this SDK's API (spec: connect). */
  async ready(): Promise<void> {
    if (this.options.skipVersionCheck) return;
    this.checked ??= (async () => {
      let v: number;
      try {
        const r = await this.app.query("select gnomon.api_version() as v");
        v = Number(r.rows[0]?.v);
      } catch (e) {
        throw new IncompatibleVersionError("this server's gnomon has no gnomon.api_version(): it predates this SDK (needs API 2)", { cause: e });
      }
      if (v < SUPPORTED_API.min || v > SUPPORTED_API.max) {
        throw new IncompatibleVersionError(`gnomon API ${v} on the server; this SDK speaks ${SUPPORTED_API.min}..${SUPPORTED_API.max}`);
      }
    })();
    return this.checked;
  }

  /** A statement on the app login, with errors typed and the hook called. */
  async appQuery(sql: string, params: unknown[] = []): Promise<QueryResult> {
    await this.ready();
    return this.observe("app", undefined, sql, () => this.app.query(sql, params));
  }

  async value<T = unknown>(sql: string, params: unknown[] = []): Promise<T> {
    const r = await this.appQuery(sql, params);
    const row = r.rows[0];
    return (row ? Object.values(row)[0] : undefined) as T;
  }

  /** jsonb returned as text, parsed losslessly. */
  async json<T = unknown>(sql: string, params: unknown[] = []): Promise<T> {
    const t = await this.value<string | null>(`select (${sql})::text`, params);
    return parseJSON(t, this.options.bigint) as T;
  }

  async observe<T extends QueryResult>(login: "app" | "runs", run: string | undefined, sql: string, fn: () => Promise<T>): Promise<T> {
    const t0 = performance.now();
    const go = async (span?: SpanLike) => {
      try {
        const r = await fn();
        this.options.onStatement?.({ run, login, statement: sql, durationMs: performance.now() - t0, ok: true, rowCount: r.rowCount });
        return r;
      } catch (e) {
        const ge = toGnomonError(e);
        this.options.onStatement?.({ run, login, statement: sql, durationMs: performance.now() - t0, ok: false, error: ge });
        span?.recordException?.(ge);
        span?.setStatus?.({ code: 2, message: ge.message });
        throw ge;
      } finally {
        span?.end();
      }
    };
    if (!this.options.tracer) return go();
    return this.options.tracer.startActiveSpan("gnomon.statement", { attributes: { "gnomon.run": run, "gnomon.login": login } }, go);
  }

  /** Start an agent run: a branch the runs login may write (gnomon.run_start). */
  async startRun(opts: StartRunOptions = {}): Promise<Run<DB>> {
    if (!this.runs) throw new GnomonError("startRun needs the runs login: new Gnomon({ app, runs })");
    const branch = await this.value<string>("select gnomon.run_start($1, $2, $3, $4::interval, $5)",
      [opts.task ?? null, opts.actor ?? null, opts.kind ?? "logged", opts.ttl ?? null, opts.parent ?? "main"]);
    return new Run<DB>(this, branch, opts);
  }

  /** A run already started (by its branch name), e.g. in another process. */
  run(branch: string, opts: StartRunOptions = {}): Run<DB> {
    return new Run<DB>(this, branch, opts);
  }

  // ---- core
  async status(): Promise<Record<string, unknown>> {
    return this.json("select gnomon.status()");
  }

  async doctor(): Promise<{ check_name: string; status: string; detail: string }[]> {
    return (await this.appQuery("select check_name, status, detail from gnomon.doctor()")).rows as never;
  }

  async describe(schema?: string): Promise<Record<string, unknown>> {
    return this.json("select gnomon.describe($1)", [schema ?? null]);
  }

  async history(table: string, key: unknown, opts: { branch?: string } = {}) {
    const r = await this.appQuery(`select vkey::text, xid::text, role, op, at, actor, reason, row_image::text as row_image, on_branch
                                     from gnomon.history($1, $2::jsonb, $3)`, [table, JSON.stringify(key), opts.branch ?? "main"]);
    return r.rows.map((x) => ({ ...x, row_image: parseJSON(x.row_image as string, this.options.bigint) }));
  }

  async blame(table: string, key: unknown, opts: { branch?: string } = {}) {
    const r = await this.appQuery(`select col, value::text as value, xid::text, role, actor, reason, at, on_branch
                                     from gnomon.blame($1, $2::jsonb, $3)`, [table, JSON.stringify(key), opts.branch ?? "main"]);
    return r.rows.map((x) => ({ ...x, value: parseJSON(x.value as string, this.options.bigint) }));
  }

  async revert(table: string, at: string, opts: { keys?: unknown[]; filter?: string; columns?: string[]; branch?: string; dryRun?: boolean } = {}) {
    return this.json("select gnomon.revert($1, $2, $3::jsonb, $4, $5::text[], $6, $7)",
      [table, at, opts.keys ? JSON.stringify(opts.keys) : null, opts.filter ?? null, opts.columns ?? null, opts.branch ?? "main", opts.dryRun ?? false]);
  }

  /** Changes between two references (branch, main, branch@ref, a coordinate, tag:x, a time). */
  async diff(a: string, b?: string): Promise<DiffOf<DB>[]> {
    const r = await this.appQuery(`select tbl::text as table, key::text as key, kind, col, old::text as old, new::text as new
                                     from gnomon.diff($1, $2)`, [a, b ?? null]);
    return r.rows.map((x) => ({
      table: x.table as string, key: parseJSON(x.key as string, this.options.bigint) as Record<string, unknown>,
      kind: x.kind as ChangeKind, column: (x.col as string) ?? null,
      old: parseJSON(x.old as string, this.options.bigint), new: parseJSON(x.new as string, this.options.bigint),
    })) as unknown as DiffOf<DB>[];
  }
}

/** One agent run: a branch, its envelope, and what the application does with it. */
export class Run<DB extends AnyDB = AnyDB> {
  readonly gnomon: Gnomon<DB>;
  readonly branch: string;
  readonly task: string | undefined;
  readonly actor: string | undefined;
  private seq = 0;
  private finished: "merged" | "submitted" | "discarded" | undefined;
  private deadline: number | undefined;

  constructor(gnomon: Gnomon<DB>, branch: string, opts: StartRunOptions = {}) {
    this.gnomon = gnomon;
    this.branch = branch;
    this.task = opts.task;
    this.actor = opts.actor;
    if (opts.deadlineMs) this.deadline = Date.now() + opts.deadlineMs;
  }

  get state() { return this.finished ?? "open"; }

  private checkOpen() {
    if (this.finished) throw new GnomonError(`run ${this.branch} is ${this.finished}`, { code: "branch_closed" });
    if (this.deadline && Date.now() > this.deadline) throw new GnomonError(`run ${this.branch} passed its time limit`, { code: "run_deadline" });
  }

  /** The envelope (spec): begin on the run, attribution, timeouts, one statement. */
  private async envelope<T>(q: Queryable, reason: string | undefined, timeoutMs: number | undefined, body: (q: Queryable) => Promise<T>): Promise<T> {
    const o = this.gnomon.options;
    this.seq++;
    await q.query("select gnomon.begin($1)", [this.branch]);
    await q.query("select gnomon.note($1, $2, $3::jsonb)", [this.actor ?? "agent", reason ?? null,
      JSON.stringify({ run: this.branch, call: this.seq, task: this.task ?? null })]);
    await q.query("select set_config('statement_timeout', $1, true), set_config('lock_timeout', $2, true)",
      [String(timeoutMs ?? o.statementTimeoutMs ?? 30000), String(o.lockTimeoutMs ?? 5000)]);
    return body(q);
  }

  /**
   * One statement on the run. Rows past the cap come back with truncated: true. A gnomon refusal
   * is a typed error whose message is written for a model to read. Retried on a serialization
   * failure (the envelope held nothing else).
   */
  async sql<T = Record<string, unknown>>(statement: string, params: unknown[] = [], opts: { reason?: string; timeoutMs?: number; maxRows?: number } = {}): Promise<SqlResult<T>> {
    this.checkOpen();
    const g = this.gnomon;
    await g.ready();
    if (splitSQL(statement).length > 1) {
      throw new GnomonError("one statement per call: this one holds several (split it, or use transaction())", { code: "one_statement", sqlstate: "42601" });
    }
    const cap = opts.maxRows ?? g.options.maxRows ?? 1000;
    for (let attempt = 0; ; attempt++) {
      try {
        const r = await g.observe("runs", this.branch, statement, () =>
          g.runs!.transaction((q) => this.envelope(q, opts.reason, opts.timeoutMs, (q2) => q2.query(statement, params, { oneStatement: true }))));
        const truncated = r.rows.length > cap;
        return { rows: (truncated ? r.rows.slice(0, cap) : r.rows) as T[], rowCount: r.rowCount, fields: r.fields, truncated };
      } catch (e) {
        if (e instanceof SerializationError && attempt < 3) { await sleep(20 * 2 ** attempt); continue; }
        throw e;
      }
    }
  }

  /** Several statements in one envelope (tools written in code). Retried by running fn again. */
  async transaction<T>(fn: (q: { sql: (s: string, p?: unknown[]) => Promise<QueryResult> }) => Promise<T>, opts: { reason?: string; timeoutMs?: number } = {}): Promise<T> {
    this.checkOpen();
    const g = this.gnomon;
    await g.ready();
    for (let attempt = 0; ; attempt++) {
      try {
        return await g.runs!.transaction((q) => this.envelope(q, opts.reason, opts.timeoutMs, (q2) =>
          fn({ sql: (s, p = []) => {
            if (splitSQL(s).length > 1) throw new GnomonError("one statement per call", { code: "one_statement", sqlstate: "42601" });
            return g.observe("runs", this.branch, s, () => q2.query(s, p, { oneStatement: true }));
          } })));
      } catch (e) {
        const ge = toGnomonError(e);
        if (ge instanceof SerializationError && attempt < 3) { await sleep(20 * 2 ** attempt); continue; }
        throw ge;
      }
    }
  }

  /** What the run changed, typed (read by the app login). */
  diff(): Promise<DiffOf<DB>[]> { return this.gnomon.diff(this.branch); }

  /** Changes, checks, the conflicts a merge would hit, warnings: one round trip. */
  summary(opts: { runChecks?: boolean } = {}): Promise<Summary> {
    return this.gnomon.json("select gnomon.run_summary($1, $2)", [this.branch, opts.runChecks ?? true]);
  }

  async checks(): Promise<{ check_name: string; passed: boolean; detail: string }[]> {
    return (await this.gnomon.appQuery("select check_name, passed, detail from gnomon.run_checks($1)", [this.branch])).rows as never;
  }

  /** Accept the run into the real data. Conflicts throw MergeConflictError (resolve, then merge again). */
  async merge(opts: { close?: boolean } = {}): Promise<{ merge: number; status: string; stats: unknown }> {
    const g = this.gnomon;
    const doMerge = async () => {
      let id: number;
      try {
        id = Number(await g.value("select gnomon.merge($1, null, 'atomic', null, null, null, $2)", [this.branch, opts.close ?? true]));
      } catch (e) {
        const ge = toGnomonError(e);
        if (ge instanceof ChecksFailedError) throw ge;
        throw ge;
      }
      const m = await g.json<{ id: number; status: string; stats: unknown }>("select to_jsonb(m) from gnomon.merge m where id = $1", [id]);
      if (m.status === "conflicts") {
        const c = await g.json<unknown[]>("select coalesce(jsonb_agg(to_jsonb(c)), '[]') from gnomon.conflict c where merge_id = $1", [id]);
        throw new MergeConflictError(`merging run ${this.branch} stopped on ${c.length} conflict(s)`, id, c);
      }
      this.finished = "merged";
      return { merge: id, status: m.status, stats: m.stats };
    };
    if (!g.options.tracer) return doMerge();
    return g.options.tracer.startActiveSpan("gnomon.merge", { attributes: { "gnomon.run": this.branch } }, async (span) => {
      try { return await doMerge(); } finally { span.end(); }
    });
  }

  /** Open a change request for a person to review (Review.wait() waits for it). */
  async submit(opts: { title?: string; body?: string } | string = {}): Promise<Request<DB>> {
    const o = typeof opts === "string" ? { title: opts } : opts;
    const id = Number(await this.gnomon.value("select gnomon.open_change_request($1, $2, $3)",
      [this.branch, o.title ?? this.task ?? `Run ${this.branch}`, o.body ?? null]));
    this.finished = "submitted";
    return new Request(this.gnomon, id);
  }

  /** Drop the run's branch and what it holds. */
  async discard(): Promise<void> {
    if (this.finished === "discarded") return;
    await this.gnomon.appQuery("select gnomon.run_end($1, false)", [this.branch]);
    this.finished = "discarded";
  }

  /**
   * A connection string pinned to the run, for a tool that wants one: a login of the run's own
   * (gnomon.run_login), confined to the run's branch, dropped when the run ends. `base` gives the
   * host, port and database (default: the url option).
   */
  async url(base?: string): Promise<string> {
    this.checkOpen();
    const b = base ?? this.gnomon.options.url;
    if (!b) throw new GnomonError("run.url() needs a base connection string (the url option, or an argument)", { code: "run_url_base" });
    const login = await this.gnomon.json<{ role: string; password: string }>("select gnomon.run_login($1)", [this.branch]);
    if (b.includes("://")) {
      const u = new URL(b);
      if (u.hostname === "") {
        // a socket URL (postgresql:///db?host=/dir): no host part to carry a user, so parameters
        u.searchParams.set("user", login.role);
        u.searchParams.set("password", login.password);
      } else {
        u.username = login.role;
        u.password = login.password;
      }
      return u.toString();
    }
    return `${b} user=${login.role} password=${login.password}`;
  }

  /** A connection pinned to the run: `connect` opens one from run.url() with your driver. */
  async connection<T>(connect: (url: string) => Promise<T> | T, base?: string): Promise<T> {
    return connect(await this.url(base));
  }

  checkpoint(name: string): Promise<string> {
    return this.gnomon.value("select gnomon.checkpoint($1, $2)", [`${this.branch}:${name}`, this.branch]);
  }

  rewind(name: string): Promise<unknown> {
    return this.gnomon.json("select gnomon.rewind($1, $2)", [this.branch, `${this.branch}:${name}`]);
  }

  dryRun(statements: string[], opts: { checks?: boolean } = {}): Promise<{ ok: boolean; summary?: unknown; diff?: unknown; checks?: unknown; error?: string }> {
    return this.gnomon.json("select gnomon.dry_run($1::text[], $2, $3)", [statements, this.branch, opts.checks ?? true]);
  }

  /** The database as this run sees it (for describe tools). */
  async describe(schema?: string): Promise<unknown> {
    const r = await this.gnomon.runs!.transaction(async (q) => {
      await q.query("select gnomon.begin($1)", [this.branch]);
      return q.query("select gnomon.describe($1)::text as d", [schema ?? null]);
    });
    return parseJSON(r.rows[0]?.d as string);
  }

  async [Symbol.asyncDispose](): Promise<void> {
    if (!this.finished) await this.discard();
  }
}

export class Requests<DB extends AnyDB = AnyDB> {
  readonly gnomon: Gnomon<DB>;
  constructor(g: Gnomon<DB>) { this.gnomon = g; }
  async open(): Promise<Request<DB>[]> {
    const r = await this.gnomon.appQuery("select id from gnomon.change_request where status in ('open', 'approved') order by id");
    return r.rows.map((x) => new Request(this.gnomon, Number(x.id)));
  }
  get(id: number): Request<DB> { return new Request(this.gnomon, id); }
}

/** A change request: what a product's own Approve, Reject and Undo buttons call. */
export class Request<DB extends AnyDB = AnyDB> {
  readonly gnomon: Gnomon<DB>;
  readonly id: number;
  constructor(g: Gnomon<DB>, id: number) { this.gnomon = g; this.id = id; }
  status(): Promise<Record<string, unknown>> { return this.gnomon.json("select gnomon.change_request_status($1)", [this.id]); }
  async diff(): Promise<Change[]> {
    const s = await this.status();
    return this.gnomon.diff(String(s.branch));
  }
  async approve(body?: string): Promise<void> { await this.gnomon.appQuery("select gnomon.review($1, 'approve', $2)", [this.id, body ?? null]); }
  async reject(note?: string): Promise<void> { await this.gnomon.appQuery("select gnomon.review($1, 'reject', $2)", [this.id, note ?? null]); }
  async comment(body: string, at: { table?: string; key?: unknown; column?: string } = {}): Promise<number> {
    return Number(await this.gnomon.value("select gnomon.comment($1, $2, $3::regclass, $4::jsonb, $5)",
      [this.id, body, at.table ?? null, at.key === undefined ? null : JSON.stringify(at.key), at.column ?? null]));
  }
  async merge(opts: { close?: boolean } = {}): Promise<number> {
    const s = await this.status();
    return Number(await this.gnomon.value("select gnomon.merge($1, null, 'atomic', null, null, null, $2)", [s.branch, opts.close ?? true]));
  }
  async undo(): Promise<unknown> {
    const s = await this.status() as { merge?: { id: number } };
    if (!s.merge) throw new GnomonError(`change request ${this.id} is not merged`);
    return this.gnomon.json("select gnomon.undo_merge($1)", [s.merge.id]);
  }
  wait(timeoutMs = 300000): Promise<Record<string, unknown>> {
    return this.gnomon.json("select gnomon.wait_for_review($1, $2::interval)", [this.id, `${Math.round(timeoutMs)} milliseconds`]);
  }
}

export class Branches<DB extends AnyDB = AnyDB> {
  readonly gnomon: Gnomon<DB>;
  constructor(g: Gnomon<DB>) { this.gnomon = g; }
  async create(name: string, opts: { parent?: string; kind?: "logged" | "scratch"; at?: string; ttl?: string } = {}): Promise<string> {
    await this.gnomon.appQuery("select gnomon.create_branch($1, $2, $3, $4, $5::interval)", [name, opts.parent ?? "main", opts.kind ?? "logged", opts.at ?? null, opts.ttl ?? null]);
    return name;
  }
  async scratch(prefix = "test", parent = "main"): Promise<string> {
    return this.gnomon.value("select gnomon.create_scratch($1, $2)", [prefix, parent]);
  }
  async drop(name: string): Promise<void> { await this.gnomon.appQuery("select gnomon.drop_branch($1, true)", [name]); }
  rebase(name: string, opts: { dryRun?: boolean } = {}): Promise<unknown> {
    return this.gnomon.json("select gnomon.rebase($1, null, $2)", [name, opts.dryRun ?? false]);
  }
  async list(): Promise<Record<string, unknown>[]> { return (await this.gnomon.appQuery("select * from gnomon.branches order by created_at")).rows; }
  /** Connection options that put a connection's sessions on a branch (gnomon.connection_options). */
  options(name: string, opts: { cModule?: boolean } = {}): Promise<string> {
    return this.gnomon.value("select gnomon.connection_options($1, $2)", [name, opts.cModule ?? false]);
  }
}
