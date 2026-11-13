// OpenAI Agents SDK: tool({ name, description, parameters, execute }). Needs @openai/agents (a
// peer dependency); parameters are JSON Schema in strict mode's terms.
import { runTool, toolSpecs } from "./tools.ts";
import type { Run } from "./index.ts";

export async function openaiAgentsTools(run: Run): Promise<unknown[]> {
  const sdk = await import("@openai/agents" as string) as { tool: (t: unknown) => unknown };
  return toolSpecs.map((t) => sdk.tool({
    name: `gnomon_${t.name}`, description: t.description, strict: false,
    parameters: { ...t.input, additionalProperties: false },
    execute: async (input: Record<string, unknown>) => (await runTool(run, t.name, input)).text,
  }));
}
