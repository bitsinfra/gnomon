// The test server: the repository's dev cluster unless GNOMON_SDK_HOST/PORT say otherwise.
import { fileURLToPath } from "node:url";
import path from "node:path";
import pg from "pg";

const here = path.dirname(fileURLToPath(import.meta.url));
export const root = path.resolve(here, "../../..");
export const host = process.env.GNOMON_SDK_HOST ?? path.join(root, "build");
export const port = Number(process.env.GNOMON_SDK_PORT ?? 54329);

export async function admin(db = "postgres") {
  const c = new pg.Client({ host, port, user: "postgres", database: db });
  await c.connect();
  return c;
}

/** A fresh database with gnomon, an app login and a confined runs login (spec: Two logins). */
export async function fixture(name: string, setup: string[]) {
  const db = `sdk_ts_${name}`.replace(/[^a-z0-9_]/g, "_").slice(0, 60);
  const sfx = `${process.pid}_${name}`.replace(/[^a-z0-9_]/g, "_").slice(0, 40);
  const appRole = `sdk_app_${sfx}`, runsRole = `sdk_runs_${sfx}`;
  const a = await admin();
  await a.query(`drop database if exists ${db} with (force)`);
  await a.query(`create database ${db}`);
  for (const r of [appRole, runsRole]) {
    await a.query(`drop role if exists ${r}`).catch(() => {});
    await a.query(`create role ${r} login`);
  }
  await a.end();
  const c = await admin(db);
  await c.query("set client_min_messages = warning; create extension gnomon");
  for (const s of setup) await c.query(s);
  await c.query(`grant gnomon_runner, gnomon_merger to ${appRole}`);
  await c.query(`grant select, insert, update, delete on all tables in schema public to ${appRole}`);
  await c.query(`grant usage on all sequences in schema public to ${appRole}`);
  await c.query(`select gnomon.confine('${runsRole}', array[]::text[], false)`);
  await c.query(`select gnomon.set('runs_role', '${runsRole}')`);
  const cmod = (await c.query("select coalesce(current_setting('gnomon.c_module', true), '') = 'on' as on")).rows[0].on as boolean;
  await c.end();
  const pool = (user: string) => new pg.Pool({ host, port, user, database: db, max: 4 });
  return {
    db, appRole, runsRole, cmod, pool,
    async cleanup() {
      const x = await admin();
      await x.query(`drop database if exists ${db} with (force)`);
      for (const r of [appRole, runsRole]) await x.query(`drop role if exists ${r}`).catch(() => {});
      await x.end();
    },
  };
}
