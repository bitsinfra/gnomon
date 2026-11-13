# Agents

Safe to hand to an agent. One command gives it a database role, a branch of its own and a
connection string — that's all it needs, whatever it's built with. It reads and writes its branch,
and the database refuses the rest, main included, even when the agent asks for it by name.

```bash
gnomon agent create support-bot
```

That one command creates a confined login role, a branch assigned to it, a token for the HTTP
transports, and prints the connection string and the MCP configuration. The agent connects, and
every query it runs lands on its branch.

## What the database refuses

The limits are inside Postgres, not in a wrapper the agent can talk its way around. A confined
role:

- writes only the branches in its access list, so main is out of reach even by a
  schema-qualified name;
- is not a member of `gnomon_merger`, so it cannot merge into main or undo there;
- cannot read another agent's or another run's branch;
- can be given a mask profile, so columns it shouldn't see come back masked.

```sql
select gnomon.confine('support_bot', array['agent/refunds']);
```

[Security →](security.md)

## It merges only what you allow

By default, merging is for the people you choose: an agent's branch waits for review.

When you want an agent to land its own work, write the rules and let Postgres enforce them:

```sql
select gnomon.create_merge_policy('refunds', array['support-bot'], '{
  "max_rows": 20,
  "tables": ["orders", "refunds"],
  "ops": ["update", "insert"],
  "no_stale_reads": true,
  "window": "09:00-17:00"
}');
```

The policy is evaluated at merge time against what the branch actually changed. A branch that
touches a table outside the list, or changes twenty-one rows, or read a row that main has changed
since, does not merge — whatever the agent was told to do. `no_stale_reads` checks the rows the
branch read, so it needs read tracking: the [C module](../src/c/README.md) and
`select gnomon.track_reads('agent/refunds')` on the branch.

## Nothing leaves before you approve

Side effects an agent queues — emails, webhooks, payments — go into a held outbox on its branch
and are delivered when the merge lands, not before:

```sql
select gnomon.outbox('outbox_msg', 'send_email');
```

Action tables work the same way: rows written on a branch are side effects that run on merge.

## Every change has a name on it

Each version records the role, the run and the reason the agent gave, so blame answers "which
agent changed this price, and why":

```sql
select * from gnomon.blame('orders', '{"id": 4182}');
```

The run record (`gnomon.agent_call`) is insert-only and hash-chained per run: every tool call, its
arguments, the branch and coordinate it ran at, and a digest of the rows it saw.
`gnomon.verify_run(run)` checks the chain.

## Replay what it saw

Gnomon records the coordinate of every read an agent makes, so a replay returns exactly the rows it
read, however much has changed since:

```bash
gnomon agent replay <run>
```

That is the difference between "the agent said the invoice was open" and knowing it was.

## Try a few ways at once

Start several attempts from the same moment, compare what each changed and which checks passed, and
keep the best one:

```bash
gnomon attempts create 3 refund-4182     # three branches from one coordinate
gnomon attempts compare refund-4182-1 refund-4182-2 refund-4182-3
gnomon attempts pick refund-4182 refund-4182-2
```

## Stop it, and take it back

One command locks an agent out: its token stops working, its role becomes `NOLOGIN`, its sessions
end and its open branches close. With `--undo-since`, Gnomon also undoes the merges its branches
landed, newest first.

```bash
gnomon agent stop support-bot --undo-since '2026-11-13 09:00'
```

## A fresh branch per task

An agent that works on one task after another gets a new branch for each:

```bash
gnomon agent next support-bot      # closes the old branch, opens support-bot/2
```

When it has finished, the agent says so from its own connection, which opens the review and sends
you the link:

```sql
select gnomon.done('Refunded order 4182; the customer was charged twice.');
```

## Ready for your agents

The Gnomon MCP server, on the agent's machine or over HTTP, lets it explore the schema, try a
change without keeping it, and rewind its branch to a checkpoint — the same limits, over a
protocol your agent already speaks.

[Review →](review.md) · [Merges →](merges.md) · [Runs and the SDKs →](sdk.md) · [The MCP server →](mcp.md)
