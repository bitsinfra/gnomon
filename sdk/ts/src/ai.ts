// Vercel AI SDK: { name: tool({ description, inputSchema, execute }) }. Needs `ai` (a peer dependency).
import { runTool, toolSpecs } from "./tools.ts";
import type { Run } from "./index.ts";

export async function aiTools(run: Run): Promise<Record<string, unknown>> {
  const ai = await import("ai" as string) as { tool: (t: unknown) => unknown; jsonSchema: (s: unknown) => unknown };
  return Object.fromEntries(toolSpecs.map((t) => [`gnomon_${t.name}`, ai.tool({
    description: t.description, inputSchema: ai.jsonSchema(t.input),
    execute: async (input: Record<string, unknown>) => (await runTool(run, t.name, input)).text,
  })]));
}
