// Any MCP client: a JSON-RPC handler bound to the run (tools/list, tools/call), to put behind a
// transport (stdio lines, or one HTTP POST per request).
import { runTool, toolSpecs } from "./tools.ts";
import type { Run } from "./index.ts";

export function mcpHandler(run: Run, info = { name: "gnomon", version: "1.0.2" }) {
  return async (req: { jsonrpc: "2.0"; id?: unknown; method: string; params?: { name?: string; arguments?: Record<string, unknown>; protocolVersion?: string } }) => {
    const ok = (result: unknown) => ({ jsonrpc: "2.0", id: req.id, result });
    switch (req.method) {
      case "initialize": return ok({ protocolVersion: req.params?.protocolVersion ?? "2025-06-18", capabilities: { tools: {} }, serverInfo: info });
      case "server/discover": return ok({ supportedVersions: ["2026-07-28", "2025-06-18"], capabilities: { tools: {} }, serverInfo: info, resultType: "complete" });
      case "tools/list": return ok({ tools: toolSpecs.map((t) => ({ name: t.name, description: t.description, inputSchema: t.input })), ttlMs: 3600000, cacheScope: "private" });
      case "tools/call": {
        const r = await runTool(run, String(req.params?.name), req.params?.arguments ?? {});
        return ok({ content: [{ type: "text", text: r.text }], isError: r.isError, resultType: "complete" });
      }
    }
    return { jsonrpc: "2.0", id: req.id, error: { code: -32601, message: `method not found: ${req.method}` } };
  };
}
