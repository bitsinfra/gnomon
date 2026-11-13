# Review

Review data like code. Every branch comes with a diff — each row and field it changed, before and
after — and you read it in your browser, in your own product, or from SQL.

```sql
select * from gnomon.diff('agent/refunds');
```

| | |
|---|---|
| `tbl`, `key` | The table and the row's key |
| `col` | The field |
| `base`, `theirs` | What it was, and what the branch made it |
| `action` | `insert`, `update` or `delete` |

`gnomon.merge_preview(source)` goes further: it shows what a merge would actually do right now,
including rows main has changed since the branch started and anything that would clash.

## A change request

A branch becomes a request for a person to look at:

```sql
select gnomon.open_change_request('agent/refunds', 'Refund order 4182');
```

An agent on its own connection does the same thing with `select gnomon.done('summary')`, which
opens the request, or comments on the one already open, and sends the notification.

```sql
select gnomon.review(cr, 'approve');      -- or 'reject', with a comment
select gnomon.comment(cr, 'Check the tax on this one', 'orders', '{"id": 4182}', 'total');
```

Comments anchor to a row or a single field, so a reviewer can point at the value they mean.

## Approvals that go stale

An approval covers what the reviewer saw. Gnomon records the branch's head at the moment of the
review, and if the branch is written or rebased afterwards, the approval stops counting and the
request comes back to them.

```sql
select gnomon.review_stale(review_id);
select gnomon.set('stale_approvals', 'keep');   -- or let approvals stand
```

## Checks

A check is SQL that must hold. Gnomon runs it on the merged result, inside the merge transaction,
before the merge is allowed to land:

```sql
-- The default expectation is that the query returns no rows
select gnomon.add_check('refund_within_total', $$
  select r.id from refunds r join orders o on o.id = r.order_id
   where r.amount > o.total
$$);
```

A failing check stops the merge. The same checks run on a branch on demand
(`gnomon.run_checks(cr)`), so an agent can find out before it asks anyone.

## The review app

```bash
gnomon serve --addr 127.0.0.1:8090
```

Branches, their diffs field by field, the schema a branch changes, conflicts side by side, the
commit log, a row's history, and the graph. It takes a database login, or a trusted proxy's header
with a role map, so what a reviewer can see and do is what the database lets them: the server logs
in as one role and acts as each reviewer, so grant every reviewer's role to that login
(`grant shop_reviewer to <server login>`). It also serves a JSON API under `/api/v1` and
Prometheus metrics at `/metrics`.

The Approve, Reject and Undo buttons in your own product call the same review through the SDKs:

```ts
const requests = await gnomon.requests.open();
await gnomon.requests.get(id).approve();
```

## Review finds you

Set where notifications go, and Gnomon sends the request to a person rather than waiting to be
noticed:

```sql
select gnomon.add_notify_target('reviews', 'webhook', '{"url": "https://hooks.example/gnomon"}');
select gnomon.set('idle_review_after', '30 minutes');   -- assigned branches that go quiet
```

`gnomon.wait_for_review(cr, timeout)` blocks until an answer arrives, for a workflow that wants to
wait.

## Merging

```sql
select gnomon.merge('agent/refunds');
```

The merge is three-way and type-aware, conflicts come back as rows, and
`gnomon.require_change_request` can insist that nothing reaches main without an approved request.
For a large branch, `CALL gnomon.merge_incremental(...)` commits in batches and can be resumed.

Undo is the same engine in reverse: `gnomon.undo_merge(id)` puts main back field by field, and
refuses if something written since would be overwritten.

[Merges and conflicts →](concepts.md) · [The GitHub Action →](../action/README.md)
