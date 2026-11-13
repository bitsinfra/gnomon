# Merges that understand your data

When main and a branch change the same value, Gnomon doesn't just pick a side. Counts add up, JSON
merges key by key and text merges line by line. Anything that truly clashes becomes a conflict, for
a person to settle or for a query to resolve.

```sql
select * from gnomon.merge_preview('agent/refunds');   -- what a merge would do, right now
select gnomon.merge('agent/refunds');                  -- the merge itself
```

A merge is three-way, like a merge in Git: Gnomon compares the branch against the *base* — the
state at the fork — and against the target as it stands now, field by field rather than row by row.
Two branches that touch different columns of the same row both land.

| What happened | What the merge does |
|---|---|
| Only the branch changed a field | The branch's value lands |
| Only main changed it | Main's value stays |
| Both changed it, to the same value | It lands once |
| Both changed it, differently | The column's strategy decides |

## Strategies, per column

```sql
select gnomon.set_merge_strategy('products', 'stock', 'counter');
```

| Strategy | What it does |
|---|---|
| `conflict` | The default: refuse to guess, and raise a conflict. |
| `counter` | Add the two deltas. Ten in stock, main sells three, the branch sells two, the result is five — taking either side would have lost a sale. |
| `jsonb` | Merge key by key; a clash inside one key is a conflict. |
| `set` | Union the arrays. |
| `text3` | Merge text line by line, as a text merge does, and conflict only where the same lines differ. |
| `ours`, `theirs` | Always take the target's side, or the branch's. |
| a function | `(base jsonb, ours jsonb, theirs jsonb) -> jsonb`, returning null for a conflict. |

A merge is only ever a fixed point: re-applying either side to the result changes nothing. Where
that cannot hold, Gnomon raises a conflict rather than inventing a value.

## Conflicts are rows

Nothing is half-applied and nothing is guessed. A merge that meets a clash comes back with status
`conflicts`, and the clashes are rows you can query:

```sql
select * from gnomon.conflict where merge_id = :merge;
select gnomon.resolve(conflict_id, 'theirs');        -- or 'ours', 'base', or a value
select gnomon.resolve_all(merge_id, 'theirs');
select gnomon.merge('agent/refunds', resume => :merge);
```

A person can settle them in the review app, side by side; an application can settle them with a
query. Checks on the change request run inside the merge transaction against the merged result, so
a merge that would break an invariant never lands.

## Between any two branches

Merging isn't only branch-to-main. A branch merges into its parent, into a sibling, or into any
branch you name, and a single transaction can be picked from one branch onto another.

```sql
select gnomon.merge('feature', target => 'release');
select gnomon.cherry_pick(array[xid]::xid8[], 'feature', 'main');   -- some transactions, onto another branch
select gnomon.merge_where('feature', 'orders', 'id < 1000');   -- part of a branch
select gnomon.rebase('feature');                               -- carry it onto main's current state
```

For a branch with a great many rows, `CALL gnomon.merge_incremental(...)` commits in batches,
parents before children on the way in and children first on the way out, and resumes where it
stopped.

## Undo is the same engine

Taking something back is a merge in reverse, field by field — not a restore, and not a snapshot
rollback.

```sql
select gnomon.undo_merge(7);                     -- a whole merge
select gnomon.undo(xid);                         -- one transaction
select gnomon.undo_role('gnomon_agent_support_bot', since => '2026-11-13 09:00');
select gnomon.revert('orders', '2026-11-13 15:00');   -- a table as it was at three o'clock
```

Gnomon never overwrites a change made since. If one is in the way it refuses with 40001 and tells
you, rather than quietly losing it — undo the later change too, or settle it by hand.

## Early warning

A branch that sits while main moves underneath it is the usual source of surprise. `gnomon.watch()`
records the keys main has changed that an open branch has touched, and warns when a branch falls
far behind its base; with `auto_rebase` on it carries the branch forward instead.

```sql
select * from gnomon.warning;
select gnomon.set('warn_changes_since_base', '1000000');
```

Stale reads are the sharper version of the same question: with the C module, Gnomon records what a
branch *read*, so a merge can refuse when the branch decided on a row main has since changed.

[Review →](review.md) · [Branches →](branches.md) · [Concepts →](concepts.md)
