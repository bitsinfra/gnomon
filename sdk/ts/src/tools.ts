// The tools every framework adapter returns, bound to one run (spec: Tools for models). The
// descriptions are written once, in sdk/spec/tools.json; this copy is checked against it.
import specs from "./tools.json" with { type: "json" };
import { GnomonError } from "./errors.ts";
import { stableJSON } from "./json.ts";
import type { Run } from "./index.ts";

export interface ToolSpec { name: string; description: string; input: { type: "object"; properties: Record<string, unknown>; required: string[] } }
export const toolSpecs: ToolSpec[] = (specs as { tools: ToolSpec[] }).tools;

/** Run one tool on a run; the result is text for a model (errors included, never thrown). */
export async function runTool(run: Run, name: string, input: Record<string, unknown>): Promise<{ text: string; isError: boolean; value?: unknown }> {
  try {
    let v: unknown;
    switch (name) {
      case "sql": {
        const r = await run.sql(String(input.statement ?? ""), [], { reason: input.reason as string | undefined });
        v = { rows: r.rows, rowCount: r.rowCount, truncated: r.truncated };
        break;
      }
      case "describe": v = await run.describe(input.schema as string | undefined); break;
      case "diff": v = await run.diff(); break;
      case "dry_run": v = await run.dryRun((input.statements as string[]) ?? []); break;
      case "checkpoint": v = { checkpoint: await run.checkpoint(String(input.name)) }; break;
      case "rewind": v = await run.rewind(String(input.name)); break;
      case "done": {
        const r = await run.submit({ title: String(input.summary ?? "").split("\n")[0].slice(0, 100) || undefined, body: String(input.summary ?? "") });
        v = { change_request: r.id, note: "a person reviews it now" };
        break;
      }
      default: throw new GnomonError(`unknown tool ${name}`);
    }
    return { text: stableJSON(v), isError: false, value: v };
  } catch (e) {
    const ge = e as GnomonError;
    return { text: `${ge.name ?? "Error"}: ${ge.message}${ge.hint ? `\nhint: ${ge.hint}` : ""}`, isError: true };
  }
}
