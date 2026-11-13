// Claude Agent SDK: an in-process MCP server (createSdkMcpServer); its tools appear to the agent
// as mcp__gnomon__<name>. Needs @anthropic-ai/claude-agent-sdk and zod (its tool() takes a Zod
// shape; the inputs here are strings and string arrays).
import { runTool, toolSpecs } from "./tools.ts";
import type { Run } from "./index.ts";

export async function claudeAgentServer(run: Run): Promise<unknown> {
  const sdk = await import("@anthropic-ai/claude-agent-sdk" as string) as {
    createSdkMcpServer: (o: unknown) => unknown; tool: (n: string, d: string, s: unknown, h: unknown) => unknown;
  };
  type Schema = { describe: (d: string) => Schema; optional: () => Schema };
  const { z } = await import("zod" as string) as { z: { string: () => Schema; array: (x: Schema) => Schema } };
  return sdk.createSdkMcpServer({
    name: "gnomon", version: "1.0.2",
    tools: toolSpecs.map((t) => sdk.tool(t.name, t.description,
      Object.fromEntries(Object.entries(t.input.properties).map(([k, v]) => {
        const p = v as { type?: string; description?: string };
        let s = p.type === "array" ? z.array(z.string()) : z.string();
        if (p.description) s = s.describe(p.description);   // (the model reads it, as in every other framework)
        return [k, t.input.required.includes(k) ? s : s.optional()];
      })),
      async (input: Record<string, unknown>) => {
        const r = await runTool(run, t.name, input);
        return { content: [{ type: "text", text: r.text }], isError: r.isError };
      })),
  });
}
