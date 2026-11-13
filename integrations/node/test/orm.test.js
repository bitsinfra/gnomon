'use strict';
// The ORMs themselves on branches: Prisma (its generated client and query compiler, through the pg
// driver adapter) and Drizzle (drizzle-orm over node-postgres). `npm test` generates the Prisma
// client first (test/prisma/schema.prisma).
const { test, before, after } = require('node:test');
const assert = require('node:assert');
const path = require('node:path');
const pg = require('pg');
const g = require('..');

const host = process.env.GNOMON_TEST_HOST || path.resolve(__dirname, '../../../build');
const port = Number(process.env.GNOMON_TEST_PORT || 54329);
const db = 'node_gnomon_orm';
const cfg = { host, port, user: 'postgres', database: db };

async function q(sql, params) {
  const c = new pg.Client(cfg);
  await c.connect();
  try { return (await c.query(sql, params)).rows; } finally { await c.end(); }
}

before(async () => {
  const admin = new pg.Client({ ...cfg, database: 'postgres' });
  await admin.connect();
  await admin.query(`drop database if exists ${db} with (force)`);
  await admin.query(`create database ${db}`);
  await admin.end();
  await q("set client_min_messages = warning; create extension gnomon");
  await q('create table item (id serial primary key, name text not null, qty int not null default 0)');
  await q("insert into item (name) select 'item ' || g from generate_series(1, 5) g");
  await q("select gnomon.track('item')");
});

after(async () => {
  const admin = new pg.Client({ ...cfg, database: 'postgres' });
  await admin.connect();
  await admin.query(`drop database if exists ${db} with (force)`);
  await admin.end();
});

function prismaOn(branch, { routed = true } = {}) {
  const { PrismaClient } = require('./prisma/client');
  const { PrismaPg } = require('@prisma/adapter-pg');
  // the datasource URL an app would configure: prismaBranchUrl names the routing schema
  const base = `postgresql://postgres@localhost:${port}/${db}?schema=public`;
  const url = new URL(routed ? g.prismaBranchUrl(base, branch) : g.branchUrl(base, branch));
  const sql = [];
  const adapter = new PrismaPg({ host, port, user: 'postgres', database: db, options: url.searchParams.get('options') },
                               { schema: url.searchParams.get('schema') });
  const prisma = new PrismaClient({ adapter, log: [{ emit: 'event', level: 'query' }] });
  prisma.$on('query', (e) => sql.push(e.query));
  return { prisma, sql };
}

test('Prisma reads and writes a branch through prismaBranchUrl', async () => {
  await q("select gnomon.create_branch('prisma-b')");
  const { prisma, sql } = prismaOn('prisma-b');
  try {
    assert.strictEqual((await prisma.item.findMany()).length, 5);
    await prisma.item.update({ where: { id: 1 }, data: { name: 'prisma on a branch', qty: 3 } });
    const created = await prisma.item.create({ data: { name: 'created by prisma' } });
    assert.ok(created.id > 5, 'the new id comes from main\'s sequence, through the routing view');
    await prisma.item.delete({ where: { id: 2 } });
    await prisma.$transaction([
      prisma.item.update({ where: { id: 3 }, data: { qty: { increment: 10 } } }),
      prisma.item.updateMany({ where: { name: { startsWith: 'item 4' } }, data: { qty: 4 } }),
    ]);
    const rows = await prisma.item.findMany({ orderBy: { id: 'asc' } });
    assert.deepStrictEqual(rows.map((r) => [r.id, r.name, r.qty]),
      [[1, 'prisma on a branch', 3], [3, 'item 3', 10], [4, 'item 4', 4], [5, 'item 5', 0], [created.id, 'created by prisma', 0]]);
    assert.ok(sql.length > 0 && sql.every((s) => !/"public"\./.test(s)), 'every statement names the routing schema');
  } finally {
    await prisma.$disconnect();
  }
  // main never saw it; the merge brings it
  assert.deepStrictEqual((await q('select id, name, qty from item order by id')).map((r) => r.name),
    ['item 1', 'item 2', 'item 3', 'item 4', 'item 5']);
  await q("select gnomon.merge('prisma-b')");
  assert.strictEqual((await q('select name from item where id = 1'))[0].name, 'prisma on a branch');
  assert.strictEqual((await q('select count(*)::int as n from item where id = 2'))[0].n, 0);
});

test('Prisma with main\'s schema on a branch session is refused, never writes main', async () => {
  await q("select gnomon.create_branch('prisma-unrouted')");
  const { prisma } = prismaOn('prisma-unrouted', { routed: false });
  try {
    await assert.rejects(prisma.item.update({ where: { id: 3 }, data: { name: 'leaked to main' } }),
      (e) => /would change main|25006/.test(String(e.message) + JSON.stringify(e)), 'the main-write guard refuses it');
  } finally {
    await prisma.$disconnect();
  }
  assert.notStrictEqual((await q('select name from item where id = 3'))[0].name, 'leaked to main');
});

test('Drizzle on a branch, a transaction per call (drizzleOnBranch)', async () => {
  const { drizzle } = require('drizzle-orm/node-postgres');
  const { pgTable, serial, text, integer } = require('drizzle-orm/pg-core');
  const { eq, asc, sql } = require('drizzle-orm');
  const item = pgTable('item', { id: serial('id').primaryKey(), name: text('name').notNull(), qty: integer('qty').notNull().default(0) });
  await q("select gnomon.create_branch('drizzle-b')");
  const pool = new pg.Pool({ ...cfg, max: 2 });
  try {
    const onBranch = g.drizzleOnBranch(pool, drizzle);
    await onBranch('drizzle-b', (d) => d.update(item).set({ qty: sql`${item.qty} + 7` }).where(eq(item.id, 4)));
    const [added] = await onBranch('drizzle-b', (d) => d.insert(item).values({ name: 'from drizzle' }).returning());
    await onBranch('drizzle-b', (d) => d.delete(item).where(eq(item.id, 5)));
    const rows = await onBranch('drizzle-b', (d) => d.select().from(item).orderBy(asc(item.id)));
    assert.ok(rows.some((r) => r.id === 4 && r.qty === 11), 'update with an expression');
    assert.ok(rows.some((r) => r.id === added.id && r.name === 'from drizzle'), 'insert ... returning');
    assert.ok(!rows.some((r) => r.id === 5), 'delete');
    // the same pool, outside drizzleOnBranch: main
    const mainRows = await drizzle(pool).select().from(item).where(eq(item.id, 4));
    assert.strictEqual(mainRows[0].qty, 4);
    assert.strictEqual((await drizzle(pool).select().from(item).where(eq(item.id, 5))).length, 1);
  } finally {
    await pool.end();
  }
});
