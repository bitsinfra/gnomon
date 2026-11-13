'use strict';
// Helpers for apps on a PostgreSQL database with the gnomon extension.
// In SQL-only mode a branch is the gnomon.branch setting plus the routing search_path; with the
// C module, the setting alone routes. Behind transaction poolers use withBranch(), which puts
// each transaction on the branch with gnomon.begin() (it lasts exactly one transaction).

const crypto = require('node:crypto');

/** The routing schema of a user schema: gnomon_r_<schema>, or gnomon_r_<schema>__s for a scratch branch. */
function routingSchema(schema = 'public', { scratch = false } = {}) {
  return `gnomon_r_${schema}${scratch ? '__s' : ''}`;
}

/** libpq `options` that put a session on a branch (scratch: the branch is a scratch branch). */
function branchOptions(branch, { cModule = false, schemas = ['public'], asOf, scratch = false } = {}) {
  const opts = [`-c gnomon.branch=${branch}`];
  if (asOf) opts.push(`-c gnomon.as_of=${asOf}`);
  if (!cModule) opts.push(`-c search_path=${schemas.flatMap((s) => [routingSchema(s, { scratch }), s]).join(',')}`);
  return opts.join(' ');
}

/**
 * The `options` the database computes for a branch (gnomon.connection_options): unlike
 * branchOptions it knows the branch's kind, a confined role's mask profile and the branch's
 * schema version. `client` is any pg client or pool.
 */
async function connectionOptions(client, branch, { cModule = false } = {}) {
  return (await client.query('select gnomon.connection_options($1, $2) as o', [branch, cModule])).rows[0].o;
}

/** A connection URL whose sessions start on `branch`. */
function branchUrl(url, branch, opts) {
  const u = new URL(url);
  u.searchParams.set('options', branchOptions(branch, opts));
  return u.toString();
}

/**
 * Prisma: a datasource URL per branch. Prisma names every table with the URL's `schema`, and in
 * SQL-only mode a name with main's schema reads main (writes to tracked tables are refused), so
 * the URL names the routing schema instead; with the C module, qualified names are routed and
 * the schema stays. `new PrismaClient({ datasourceUrl: prismaBranchUrl(url, 'feature') })`
 */
function prismaBranchUrl(url, branch, { cModule = false, schema, asOf, scratch = false } = {}) {
  const u = new URL(url);
  const s = schema ?? u.searchParams.get('schema') ?? 'public';
  u.searchParams.set('options', branchOptions(branch, { cModule, schemas: [s], asOf, scratch }));
  if (!cModule) u.searchParams.set('schema', routingSchema(s, { scratch }));
  return u.toString();
}

/** Run fn(client) in one transaction on a branch. Works with pg.Pool or a pg.Client. */
async function withBranch(poolOrClient, branch, fn, { asOf } = {}) {
  const isPool = typeof poolOrClient.connect === 'function' && typeof poolOrClient.totalCount === 'number';
  const client = isPool ? await poolOrClient.connect() : poolOrClient;
  try {
    await client.query('begin');
    await client.query('select gnomon.begin($1, $2)', [branch, asOf ?? null]);
    const out = await fn(client);
    await client.query('commit');
    return out;
  } catch (e) {
    await client.query('rollback').catch(() => {});
    throw e;
  } finally {
    if (isPool) client.release();
  }
}

/** Put a client's session on a branch ('main' resets it). */
async function use(client, branch = 'main', asOf = null) {
  const r = await client.query('select gnomon.use($1, $2) as path', [branch, asOf]);
  return r.rows[0].path;
}

async function createBranch(client, name, { parent = 'main', scratch = false, at = null } = {}) {
  const r = await client.query('select gnomon.create_branch($1, $2, $3, $4) as id', [name, parent, scratch ? 'scratch' : 'logged', at]);
  return r.rows[0].id;
}

async function createScratch(client, prefix = 'test', parent = 'main') {
  const name = `${prefix}-${process.pid.toString(16)}-${crypto.randomBytes(4).toString('hex')}`;
  await createBranch(client, name, { parent, scratch: true });
  return name;
}

async function dropBranch(client, name, cascade = true) {
  await client.query('select gnomon.drop_branch($1, $2)', [name, cascade]);
}

async function diff(client, a, b = null) {
  const r = await client.query('select tbl::text as table, key, kind, col, old, new from gnomon.diff($1, $2)', [a, b]);
  return r.rows;
}

async function merge(client, source, target = null) {
  const r = await client.query('select gnomon.merge($1, $2) as id', [source, target]);
  const m = await client.query('select id, status, stats from gnomon.merge where id = $1', [r.rows[0].id]);
  return m.rows[0];
}

/**
 * Drizzle: `const onBranch = drizzleOnBranch(pool, drizzle)` then
 * `await onBranch('feature', (db) => db.update(users).set(...))` - each call is one transaction
 * on the branch, through drizzle(client) built on the checked-out client.
 */
function drizzleOnBranch(pool, drizzle, config) {
  return (branch, fn) => withBranch(pool, branch, (client) => fn(drizzle(client, config)));
}

/**
 * Jest / Vitest: `const t = testBranch(() => new pg.Client(dsn))`, then in a test file
 *   beforeEach(t.setup); afterEach(t.teardown); ... t.client.query(...)
 * Each test runs on its own scratch branch of one seeded database; nothing reaches main.
 */
function testBranch(makeClient, { prefix = 'test', parent = 'main', keep = false } = {}) {
  const state = { client: null, branch: null };
  state.setup = async () => {
    state.client = makeClient();
    await state.client.connect();
    state.branch = await createScratch(state.client, prefix, parent);
    await use(state.client, state.branch);
  };
  state.teardown = async () => {
    if (!state.client) return;
    await use(state.client, 'main');
    if (!keep) await dropBranch(state.client, state.branch);
    await state.client.end();
    state.client = null;
  };
  return state;
}

module.exports = { routingSchema, branchOptions, connectionOptions, branchUrl, prismaBranchUrl, withBranch, use, createBranch, createScratch, dropBranch, diff, merge, drizzleOnBranch, testBranch };
