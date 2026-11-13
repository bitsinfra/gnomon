"""Tools for models, bound to one run (sdk/spec/SPEC.md, Tools for models). The descriptions are
the specification's (tools.json, checked against sdk/spec/tools.json).

    from gnomon.tools import anthropic_tools
    tools = anthropic_tools(run)                 # @beta_tool functions for the Anthropic tool runner
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from ._util import stable_json
from .errors import GnomonError

TOOL_SPECS: list[dict] = json.loads((Path(__file__).parent / "tools.json").read_text())["tools"]


def run_tool(run, name: str, args: dict) -> tuple[str, bool]:
    """Run one tool on a (sync) run: (text for the model, is_error). Errors are returned, not raised."""
    try:
        if name == "sql":
            r = run.sql(str(args.get("statement", "")), reason=args.get("reason"))
            v: Any = {"rows": r["rows"], "row_count": r["row_count"], "truncated": r["truncated"]}
        elif name == "describe":
            v = run.describe(args.get("schema"))
        elif name == "diff":
            v = run.diff()
        elif name == "dry_run":
            v = run.dry_run(list(args.get("statements") or []))
        elif name == "checkpoint":
            v = {"checkpoint": run.checkpoint(str(args["name"]))}
        elif name == "rewind":
            v = run.rewind(str(args["name"]))
        elif name == "done":
            summary = str(args.get("summary", ""))
            v = {"change_request": run.submit(summary.split("\n")[0][:100] or None, summary).id, "note": "a person reviews it now"}
        else:
            raise GnomonError(f"unknown tool {name}")
        return stable_json(v), False
    except GnomonError as e:
        return f"{type(e).__name__}: {e}" + (f"\nhint: {e.hint}" if e.hint else ""), True


def tool_definitions() -> list[dict]:
    """Plain definitions (name, description, input_schema) for any framework or the Messages API."""
    return [{"name": f"gnomon_{t['name']}", "description": t["description"], "input_schema": t["input"]} for t in TOOL_SPECS]


def handle_tool_use(run, block: dict) -> dict:
    """Answer an Anthropic tool_use block with a tool_result block."""
    text, err = run_tool(run, block["name"].removeprefix("gnomon_"), block.get("input") or {})
    return {"type": "tool_result", "tool_use_id": block["id"], "content": text, "is_error": err}


def anthropic_tools(run) -> list:
    """Functions decorated with the Anthropic SDK's @beta_tool (needs anthropic). The input schemas
    are the specification's: beta_tool would infer an empty one from the functions' ``**kw``."""
    from anthropic import beta_tool  # type: ignore

    def make(name: str):
        def fn(**kw):
            return run_tool(run, name, kw)[0]
        return fn
    return [beta_tool(make(t["name"]), name=f"gnomon_{t['name']}", description=t["description"], input_schema=t["input"])
            for t in TOOL_SPECS]


def openai_agents_tools(run) -> list:
    """FunctionTool objects for the OpenAI Agents SDK (needs openai-agents)."""
    from agents import FunctionTool  # type: ignore

    def make(t):
        async def invoke(_ctx, args_json: str) -> str:
            return run_tool(run, t["name"], json.loads(args_json or "{}"))[0]
        return FunctionTool(name=f"gnomon_{t['name']}", description=t["description"],
                            params_json_schema={**t["input"], "additionalProperties": False}, on_invoke_tool=invoke, strict_json_schema=False)
    return [make(t) for t in TOOL_SPECS]


def langchain_tools(run) -> list:
    """StructuredTool objects for LangChain and LangGraph (needs langchain-core)."""
    from langchain_core.tools import StructuredTool  # type: ignore

    return [StructuredTool.from_function(func=(lambda name: (lambda **kw: run_tool(run, name, kw)[0]))(t["name"]),
                                         name=f"gnomon_{t['name']}", description=t["description"], args_schema=t["input"]) for t in TOOL_SPECS]


def mcp_handler(run):
    """A JSON-RPC handler bound to the run (tools/list, tools/call) for any MCP transport."""
    def handle(req: dict) -> dict:
        m, p = req.get("method"), req.get("params") or {}
        if m == "initialize":
            return {"jsonrpc": "2.0", "id": req.get("id"), "result": {"protocolVersion": p.get("protocolVersion", "2025-06-18"),
                    "capabilities": {"tools": {}}, "serverInfo": {"name": "gnomon", "version": "1.0.1"}}}
        if m == "tools/list":
            return {"jsonrpc": "2.0", "id": req.get("id"), "result": {"tools": [{"name": t["name"], "description": t["description"], "inputSchema": t["input"]} for t in TOOL_SPECS],
                    "ttlMs": 3600000, "cacheScope": "private"}}
        if m == "tools/call":
            text, err = run_tool(run, p.get("name", ""), p.get("arguments") or {})
            return {"jsonrpc": "2.0", "id": req.get("id"), "result": {"content": [{"type": "text", "text": text}], "isError": err, "resultType": "complete"}}
        return {"jsonrpc": "2.0", "id": req.get("id"), "error": {"code": -32601, "message": f"method not found: {m}"}}
    return handle
