# Testing on branches

Give every test its own branch of one seeded database. It starts in about a millisecond, sees the
seed data as it is, and is thrown away when the test ends — no truncation between tests, no
per-test fixtures, no second database.

Scratch branches are unlogged and swept automatically, so they cost almost nothing.

## TypeScript

```ts
import { withScratch, assertNoChanges, gnomonDiff } from "@bitsinfra/gnomon/testing";

test("signing up creates one customer", async () => {
  await withScratch(pool, async (db) => {
    await signup(db, "a@example.com");
    await expect(gnomonDiff(db)).toMatchSnapshot();
  });
});
```

`assertNoChanges(db)` is the other half: a read path that quietly writes fails the test.

## Python

```python
def test_signup(gnomon_conn, gnomon_snapshot):     # a psycopg connection on a fresh scratch branch
    signup(gnomon_conn, "a@example.com")
    gnomon_snapshot.assert_match(gnomon_conn)      # the branch's diff against a stored file
```

```bash
GNOMON_TEST_DSN=postgres://... pytest
```

The pytest plugin loads itself once the package is installed. `--gnomon-update-snapshots` records
the snapshots, and `--gnomon-keep` keeps the branches so you can look at one that failed.

## Everywhere else

Each binding has the same shape, so a test fixture is three lines in any of them:

| | |
|---|---|
| Ruby | RSpec examples on scratch branches (`gnomon: true`) |
| Go | `gnomontest.Branch(t, pool)` |
| Java | the `GnomonBranchExtension` JUnit 5 extension |
| Elixir | `Gnomon.Case` for ExUnit |
| .NET | the `GnomonBranchFixture` xUnit fixture |
| PHP | the `UsesGnomonBranch` trait for PHPUnit and Pest |
| Node | `withScratch` for Jest and Vitest, with Prisma and Drizzle adapters |

## Snapshots that read like a diff

A snapshot is the branch's diff, normalized: the rows and fields the test changed, with generated
keys and timestamps replaced. It fails with the change itself, not a wall of JSON:

```
orders 4182  status  paid → refunded
refunds new  amount  129.00
```

That makes a test's intent legible, and an unintended write obvious.

## Your whole suite on a branch

Branch-per-test works in the SQL core. If your tests run concurrently against one database and
take row locks, or use `INSERT ... ON CONFLICT`, load the C module so branches get real locks and
upserts. [Branches →](branches.md)
