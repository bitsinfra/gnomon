'use strict';
const { test, before, after, beforeEach, afterEach, describe } = require('node:test');
const assert = require('node:assert');
const path = require('node:path');
const pg = require('pg');
const g = require('..');

const host = process.env.GNOMON_TEST_HOST || path.resolve(__dirname, '../../../build');
const port = Number(process.env.GNOMON_TEST_PORT || 54329);
const db = 'node_gnomon_test';
const cfg = { host, port, user: 'postgres', database: db };

before(async () => {
  const admin = new pg.Client({ ...cfg, database: 'postgres' });
  await admin.connect();
  await admin.query(`drop database if exists ${db} with (force)`);
  await admin.query(`create database ${db}`);
  await admin.end();
  const c = new pg.Client(cfg);
  await c.connect();
  await c.query('set client_min_messages = warning; create extension gnomon');
  await c.query("create table account (id int primary key, name text not null, balance int not null default 0)");
  await c.query("insert into account select g, 'acct ' || g, 100 from generate_series(1, 10) g");
  await c.query("select gnomon.track('account')");
  await c.end();
});

after(async () => {
  const admin = new pg.Client({ ...cfg, database: 'postgres' });
  await admin.connect();
  await admin.query(`drop database if exists ${db} with (force)`);
  await admin.end();
});

test('branchOptions and branchUrl', () => {
  assert.strictEqual(g.branchOptions('f'), '-c gnomon.branch=f -c search_path=gnomon_r_public,public');
  assert.strictEqual(g.branchOptions('f', { cModule: true }), '-c gnomon.branch=f');
  const u = new URL(g.branchUrl('postgresql://u@h:5432/d?sslmode=disable', 'f'));
  assert.strictEqual(u.searchParams.get('options'), '-c gnomon.branch=f -c search_path=gnomon_r_public,public');
  assert.strictEqual(u.searchParams.get('sslmode'), 'disable');
});

test('routing schemas: scratch branches and Prisma datasource URLs', () => {
  assert.strictEqual(g.branchOptions('s', { scratch: true }), '-c gnomon.branch=s -c search_path=gnomon_r_public__s,public');
  const p = new URL(g.prismaBranchUrl('postgresql://u@h:5432/d?schema=public', 'f'));
  assert.strictEqual(p.searchParams.get('schema'), 'gnomon_r_public');
  assert.strictEqual(p.searchParams.get('options'), '-c gnomon.branch=f -c search_path=gnomon_r_public,public');
  assert.strictEqual(new URL(g.prismaBranchUrl('postgresql://u@h/d', 's', { scratch: true })).searchParams.get('schema'), 'gnomon_r_public__s');
  assert.strictEqual(new URL(g.prismaBranchUrl('postgresql://u@h/d?schema=public', 'f', { cModule: true })).searchParams.get('schema'), 'public');
});

test('names qualified as Prisma qualifies them, with the schema of prismaBranchUrl, reach the branch', async () => {
  const admin = new pg.Client(cfg);
  await admin.connect();
  await g.createBranch(admin, 'prisma-like');
  const url = new URL(g.prismaBranchUrl('postgresql://x@y/z?schema=public', 'prisma-like'));
  const schema = url.searchParams.get('schema');
  const c = new pg.Client({ ...cfg, options: url.searchParams.get('options') });
  await c.connect();
  await c.query(`update "${schema}"."account" set name = 'via prisma schema' where id = 2`);
  assert.strictEqual((await c.query(`select name from "${schema}"."account" where id = 2`)).rows[0].name, 'via prisma schema');
  assert.notStrictEqual((await admin.query('select name from account where id = 2')).rows[0].name, 'via prisma schema');
  await c.end();
  await admin.end();
});

test('a scratch branch through connection options', async () => {
  const admin = new pg.Client(cfg);
  await admin.connect();
  const name = await g.createScratch(admin, 'opts');
  const c = new pg.Client({ ...cfg, options: g.branchOptions(name, { scratch: true }) });
  await c.connect();
  await c.query("update account set name = 'scratch via options' where id = 3");
  assert.strictEqual((await c.query('select name from account where id = 3')).rows[0].name, 'scratch via options');
  await c.end();
  await g.dropBranch(admin, name);
  await admin.end();
});

test('a connection opened with branch options is on the branch', async () => {
  const admin = new pg.Client(cfg);
  await admin.connect();
  await g.createBranch(admin, 'opts');
  const c = new pg.Client({ ...cfg, options: g.branchOptions('opts') });
  await c.connect();
  await c.query("update account set name = 'via options' where id = 1");
  assert.strictEqual((await c.query('select name from account where id = 1')).rows[0].name, 'via options');
  await c.end();
  assert.strictEqual((await admin.query('select name from account where id = 1')).rows[0].name, 'acct 1');
  await g.dropBranch(admin, 'opts');
  await admin.end();
});

test("connectionOptions names the branch's schema version", async () => {
  const admin = new pg.Client(cfg);
  await admin.connect();
  await g.createBranch(admin, 'node-sv');
  await g.use(admin, 'node-sv');
  await admin.query("select gnomon.ddl($$alter table account add column tier text default 'basic'$$)");
  await g.use(admin, 'main');
  const opts = await g.connectionOptions(admin, 'node-sv');
  assert.match(opts, /__v\d+/);
  const c = new pg.Client({ ...cfg, options: opts });
  await c.connect();
  assert.strictEqual((await c.query('select tier from account where id = 1')).rows[0].tier, 'basic');
  await c.end();
  await g.dropBranch(admin, 'node-sv');
  await admin.end();
});

test('withBranch: one transaction on a branch, through a pool', async () => {
  const pool = new pg.Pool({ ...cfg, max: 1 });
  const admin = await pool.connect();
  await g.createBranch(admin, 'pooled');
  admin.release();
  await g.withBranch(pool, 'pooled', (c) => c.query("update account set balance = 1 where id = 2"));
  const onMain = await pool.query('select balance from account where id = 2');
  assert.strictEqual(onMain.rows[0].balance, 100, 'the same pooled connection is back on main');
  const onBranch = await g.withBranch(pool, 'pooled', (c) => c.query('select balance from account where id = 2'));
  assert.strictEqual(onBranch.rows[0].balance, 1);
  const d = await g.diff(pool, 'pooled');
  assert.strictEqual(d.length, 1);
  const m = await g.merge(pool, 'pooled');
  assert.strictEqual(m.status, 'applied');
  assert.strictEqual((await pool.query('select balance from account where id = 2')).rows[0].balance, 1);
  await pool.end();
});

test('drizzleOnBranch builds the ORM on the branch client', async () => {
  const pool = new pg.Pool(cfg);
  await g.createBranch(pool, 'drz');
  const fakeDrizzle = (client) => ({ run: (sql) => client.query(sql) });
  const onBranch = g.drizzleOnBranch(pool, fakeDrizzle);
  await onBranch('drz', (db) => db.run("update account set name = 'drizzle' where id = 3"));
  const r = await onBranch('drz', (db) => db.run('select name from account where id = 3'));
  assert.strictEqual(r.rows[0].name, 'drizzle');
  assert.strictEqual((await pool.query('select name from account where id = 3')).rows[0].name, 'acct 3');
  await g.dropBranch(pool, 'drz');
  await pool.end();
});

describe('testBranch fixture (Jest/Vitest style)', () => {
  const t = g.testBranch(() => new pg.Client(cfg));
  beforeEach(t.setup);
  afterEach(t.teardown);
  for (const n of [1, 2, 3]) {
    test(`isolated test ${n}`, async () => {
      const r = await t.client.query('select balance from account where id = 4');
      assert.strictEqual(r.rows[0].balance, 100);
      await t.client.query('update account set balance = balance + $1 where id = 4', [n]);
      assert.strictEqual((await t.client.query('select balance from account where id = 4')).rows[0].balance, 100 + n);
    });
  }
});
