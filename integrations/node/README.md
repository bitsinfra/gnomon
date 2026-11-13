# @bitsinfra/gnomon-postgres (Node)

Helpers for apps on a PostgreSQL database with the gnomon extension: branch connection options and
URLs, one transaction on a branch through a pool, Prisma and Drizzle on a branch, and a Jest/Vitest
fixture. For runs, review and agent tools, use [@bitsinfra/gnomon](../../sdk/ts/README.md).

```js
const g = require('@bitsinfra/gnomon-postgres');
const pool = new pg.Pool({ connectionString: g.branchUrl(process.env.DATABASE_URL, 'feature') });
await g.withBranch(pool, 'feature', (c) => c.query("update accounts set ..."));   // behind poolers
const opts = await g.connectionOptions(adminClient, 'feature');   // what the database says the
                                                                  // branch needs (schema versions, masks)
```

`branchOptions`, `routingSchema`, `use`, `createBranch`, `createScratch`, `dropBranch`, `diff`,
`merge`. Prisma: `new PrismaClient({ datasourceUrl: g.prismaBranchUrl(url, 'feature') })` (Prisma
qualifies every name with its schema, so the URL names the routing schema). Drizzle:
`g.drizzleOnBranch(pool, drizzle, config)`.

Tests: `const t = g.testBranch(() => new pg.Client(dsn))`, then `beforeEach(t.setup)`,
`afterEach(t.teardown)`, and `t.client` in the test: each test on its own scratch branch of one
seeded database.
