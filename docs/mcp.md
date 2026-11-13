# The MCP server

`gnomon mcp` serves the database to an agent over the Model Context Protocol: it explores the
schema, writes on a branch of its own, looks at its diff, tries a change without keeping it, and
asks for review. The agent never touches main.

## On the agent's machine

```bash
gnomon --dsn "$GNOMON_AGENT_URL" mcp
```

`gnomon agent create support-bot` prints a ready-made configuration. Point your MCP client at it:

```json
{
  "mcpServers": {
    "gnomon": {
      "command": "gnomon",
      "args": ["--dsn", "postgres://gnomon_agent_support_bot@localhost/app", "mcp"]
    }
  }
}
```

The DSN is a confined role, so the server's limits are the database's limits.

## Over HTTP

For agents that run elsewhere, the same tools are served over streamable HTTP, one JSON-RPC
request per POST:

```bash
gnomon --dsn "$SERVER_DSN" mcp --http 127.0.0.1:8822
```

`gnomon serve --mcp` serves the same transport at `/mcp` beside the review app (port 8090 by
default), which is the address `gnomon agent create` prints. Each request carries an agent's
bearer token. The server logs in as one role, checks the token against `gnomon.agent_auth` and
`SET ROLE`s to that agent inside the request's transaction, so every check in the database
applies to the agent that asked. That login needs `gnomon_runner` and membership in each agent's
role (`grant gnomon_agent_support_bot to <login>`; `agent create` reminds you). Budgets per agent
(`calls_per_minute`, `max_result_rows`, `max_result_bytes`) are enforced here too.

## The tools

| Tool | What it does |
|---|---|
| `describe`, `status` | The schema as an agent sees it; which branch this session is on. |
| `list_branches`, `create_branch`, `drop_branch` | Branches. |
| `query`, `execute` | Read, and write on the branch. |
| `dry_run` | Run statements and roll them back, returning what they would have changed. |
| `diff`, `merge_preview`, `conflicts`, `resolve` | What changed, what a merge would do, what clashes. |
| `checkpoint`, `rewind`, `revert` | Savepoints across calls; put rows back as they were. |
| `history`, `blame`, `log`, `neighbors`, `impact` | Where a value came from, and what a branch touches. |
| `rebase`, `stale_reads`, `run_checks` | Catch up to main; what the branch read that has changed since. |
| `request_merge`, `change_request_status` | Ask a person, and watch for the answer. |

A call that names no branch works on the branch the agent's role is assigned to (the one its own
sessions start on), or on main where it has none. Writing tools are marked as such, so a client
that asks before writes can ask.

## In-process, through the SDKs

If your product runs the agent itself, you don't need a server: the SDKs expose the same tools
bound to one run, for the Anthropic SDK, the Claude Agent SDK, the Vercel AI SDK, the OpenAI
Agents SDK, LangChain, and MCP in TypeScript and Python.

```ts
import { claudeAgentServer } from "@bitsinfra/gnomon/claude-agent";
const server = await claudeAgentServer(run);   // tools appear as mcp__gnomon__*
```

[Runs and the SDKs →](sdk.md) · [Agents →](agents.md)

## What the agent sees when it goes wrong

Every Gnomon error carries a stable slug in its hint, and the server turns it into an explanation
the agent can act on, rather than a bare SQLSTATE:

```
cannot run ALTER TABLE on a branch session [gnomon:ddl_on_branch]
→ Run it through gnomon.ddl('...') to change the branch only.
```

[Errors →](errors.md)
