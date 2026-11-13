// The conformance scenarios (sdk/spec/conformance) as a runner any test framework calls: Node's
// test runner for node-postgres, postgres.js, Kysely and Neon (conformance.test.ts), Bun's for its
// own client (bun.test.ts).
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { Gnomon, GnomonError, type Adapter, type Run } from "../src/index.ts";
import * as errors from "../src/errors.ts";
import { fixture, root } from "./env.ts";

const dir = path.join(root, "sdk/spec/conformance");
export const scenarios = fs.readdirSync(dir).filter((f) => f.endsWith(".json"))
  .map((f) => ({ file: f, ...JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")) }));

function get(o: unknown, p: string): unknown {
  return p.split(".").reduce((x: any, k) => (x == null ? x : x[k]), o);
}

export interface Driver {
  name: string;
  prefix: string;
  /** An adapter for one login of the scenario's database, and how to close it. */
  connect(db: string, user: string): { adapter: Adapter; close: () => Promise<void> };
}

export function defineScenarios(test: (name: string, fn: () => Promise<void>) => unknown, drivers: Driver[]) {
  for (const driver of drivers) {
    for (const sc of scenarios) {
      test(`${driver.name}: ${sc.name}`, async () => {
        const fx = await fixture(`${driver.prefix}_${sc.file.replace(".json", "")}`, sc.setup);
        const close: Array<() => Promise<void>> = [];
        const adapter = (user: string) => { const c = driver.connect(fx.db, user); close.push(c.close); return c.adapter; };
        const g = new Gnomon({ app: adapter(fx.appRole), runs: adapter(fx.runsRole) });
        const runs: Record<string, Run> = {};
        try {
          for (const [i, st] of (sc.steps as any[]).entries()) {
            const where = `${sc.file} step ${i + 1} (${st.call})`;
            const run = runs[st.on ?? "default"];
            const exp = st.expect ?? {};
            if (exp.sqlOnly && fx.cmod) continue;
            let out: any;
            try {
              switch (st.call) {
                case "startRun": runs[st.as ?? "default"] = await g.startRun(st.args); continue;
                case "run.sql": out = await run.sql(st.args.statement, [], { timeoutMs: st.options?.timeoutMs }); break;
                case "app.sql": out = await g.appQuery(st.args.statement); break;
                case "run.diff": out = await run.diff(); break;
                case "run.summary": out = await run.summary(); break;
                case "run.merge": out = await run.merge(); break;
                case "run.discard": out = await run.discard(); break;
                default: throw new Error(`unknown call ${st.call}`);
              }
            } catch (e) {
              if (!exp.error) throw new Error(`${where}: ${(e as Error).message}`);
              const cls = (errors as Record<string, unknown>)[exp.error] as typeof GnomonError;
              assert.ok(e instanceof cls, `${where}: expected ${exp.error}, got ${(e as Error).name}: ${(e as Error).message}`);
              continue;
            }
            assert.ok(!exp.error, `${where}: expected ${exp.error}`);
            if ("rowCount" in exp) assert.equal(out.rowCount, exp.rowCount, where);
            if ("rows" in exp) assert.deepEqual(out.rows.map((r: any) => ({ ...r })), exp.rows, where);
            if ("length" in exp) assert.equal(out.length, exp.length, where);
            for (const [k, v] of Object.entries(exp)) if (k.includes(".")) assert.deepEqual(get(out, k), v, where);
          }
        } finally {
          for (const c of close) await c();
          await fx.cleanup();
        }
      });
    }
  }
}
