// Anthropic SDK: tools for the Messages API and the tool runner. `tools` goes in the request;
// `run(toolUse)` answers a tool_use block with a tool_result. With @anthropic-ai/sdk's tool runner,
// betaTools(run) returns objects with run functions (its betaTool shape).
import { runTool, toolSpecs } from "./tools.ts";
import type { Run } from "./index.ts";

export function anthropicTools(run: Run) {
  return {
    tools: toolSpecs.map((t) => ({ name: `gnomon_${t.name}`, description: t.description, input_schema: t.input })),
    async handle(block: { id: string; name: string; input: Record<string, unknown> }) {
      const r = await runTool(run, block.name.replace(/^gnomon_/, ""), block.input ?? {});
      return { type: "tool_result" as const, tool_use_id: block.id, content: r.text, is_error: r.isError };
    },
  };
}

export function betaTools(run: Run) {
  return toolSpecs.map((t) => ({
    name: `gnomon_${t.name}`, description: t.description, input_schema: t.input,
    run: async (input: Record<string, unknown>) => (await runTool(run, t.name, input)).text,
  }));
}
