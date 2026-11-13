// LangChain and LangGraph: tool(fn, { name, description, schema }). Needs @langchain/core.
import { runTool, toolSpecs } from "./tools.ts";
import type { Run } from "./index.ts";

export async function langchainTools(run: Run): Promise<unknown[]> {
  const lc = await import("@langchain/core/tools" as string) as { tool: (fn: unknown, o: unknown) => unknown };
  return toolSpecs.map((t) => lc.tool(async (input: Record<string, unknown>) => (await runTool(run, t.name, input)).text,
    { name: `gnomon_${t.name}`, description: t.description, schema: t.input }));
}
