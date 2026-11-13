# History and time travel

Any moment, exactly as it was. Gnomon keeps the history of every table you track, so you can read
the whole database as it stood at any moment, with the queries you already have, and get the same
answer every time. When an agent makes a decision, you can see exactly what it saw.

```sql
-- The open invoices at the end of October
select gnomon.use('main', '2026-10-31 23:59');
select sum(amount) from invoices where status = 'open';

select gnomon.use('main');   -- back to now
```

Nothing about the query changes: same tables, same joins, same views. Only the moment changes.

## Naming a moment

| Reference | Meaning |
|---|---|
| `'2026-10-31 23:59'` | A timestamp, resolved to the nearest clock tick at or before it |
| `'tag:before-migration'` | A tag you made with `gnomon.create_tag` |
| `'e1:880:882:881@0/1A2B3C4'` | An exact coordinate |

A coordinate is exact and replayable; a timestamp is as precise as your heartbeat. Capture one with
`select gnomon.coordinate_text()` and the same read comes back identically, however much has
changed since. This is what lets you see exactly what an agent saw.

For one transaction, or behind a pooler, `gnomon.begin('main', '2026-10-31 23:59')` does the same
thing without leaving the session in the past. The past is read-only; writes are refused.

## Where a value came from

```sql
select * from gnomon.history('orders', '{"id": 4182}');   -- every version of one row
select * from gnomon.blame('orders', '{"id": 4182}');     -- per field: who last changed it, when and why
select * from gnomon.log();                               -- commits, merges and undos, newest first
```

Blame answers the question people actually ask: not just when the status became `refunded`, but
which agent did it, in which run and for what reason.

## Find the change that broke it

When a check that used to pass starts failing, Gnomon finds the transaction that broke it. It runs
the check on the database as it was halfway between the last good moment and now, then halves
what's left, until one transaction remains:

```bash
gnomon bisect refund_within_total --good '2026-11-12 08:00'
```

It reports the transaction, who made it, when and why.

## Undo

```sql
select gnomon.undo_merge(7);                       -- a whole merge
select gnomon.undo(xid);                           -- one transaction
select gnomon.undo_role('gnomon_agent_support_bot', since => '2026-11-13 09:00');
```

Undo goes through the merge engine, so it puts back exactly the fields that changed. If something
written since would be overwritten, it refuses with 40001 rather than guessing. To put a table back
as it was at a moment, `gnomon.revert('orders', '2026-11-13 15:00')`.

## Valid time

Some tables need two clocks: when a fact was recorded, and when it was true. Track a table as
bitemporal and Gnomon keeps both:

```sql
select gnomon.track('price', mode => 'bitemporal');
set gnomon.valid_at = '2026-06-01';   -- prices as they stood in June
```

Corrections rewrite what was true then without losing what you believed before, and a change dated
in the future lands when it comes due.

## Keeping history in hand

| | |
|---|---|
| Retention | `gnomon.set_retention('orders', '{"keep_all": "30 days", "daily": "1 year", "monthly": true}')` keeps versions visible at retained coordinates and thins the rest. |
| Tags | Tagged coordinates keep their history from retention. |
| Checkpoints | A full image of a table at one coordinate, so a read far in the past rebuilds only what changed since: `gnomon checkpoints create orders --at tag:release`. |
| Archive | `gnomon archive` moves old partitions to Parquet, locally or in object storage; a read that reaches that far asks for them back, or reads them in place. |
| Erasure | `gnomon.erase('customer', '{"id": 7}', array['email'], 'request 42')` is the one path that rewrites history; archives are reached by crypto-shredding their keys. |
| Ledger | A hash-chained Merkle block per tick, so you can show that history has not been edited: `gnomon.verify_ledger()`. |

[Operations →](operations.md) · [The change feed →](feed.md)
