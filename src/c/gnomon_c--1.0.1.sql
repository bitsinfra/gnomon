\echo Use "CREATE EXTENSION gnomon_c" to load this file. \quit

create function _gnomon.c_version_trigger() returns trigger
language c as 'MODULE_PATHNAME', 'gnomon_c_version_trigger';

-- The touched-key filter (shared memory, gnomon.touched_filter_kb): a BEFORE INSERT trigger on a
-- table's touched-key tables records each (branch, key) as it is first touched, so branch point
-- reads can skip the touched-key scan for keys no level touched. ENABLE ALWAYS: restores and
-- replication set the bits too. Attached by gnomon.use_c_trigger (which gnomon.track() calls for
-- the tables the C trigger serves) and, below, for every table already tracked.
create function _gnomon.c_touch_filter() returns trigger language c as 'MODULE_PATHNAME', 'gnomon_c_touch_filter';
create function _gnomon.c_filter_attach(tid int) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked := _gnomon.trow(tid); s text;
begin
  if t.id is null then return; end if;
  foreach s in array array['bk', 'bk_u'] loop
    if to_regclass(_gnomon.obj(t, s)) is not null then
      execute format('drop trigger if exists gnomon_c_filter on %s', _gnomon.obj(t, s));
      execute format('create trigger gnomon_c_filter before insert on %s for each row execute function _gnomon.c_touch_filter()', _gnomon.obj(t, s));
      execute format('alter table %s enable always trigger gnomon_c_filter', _gnomon.obj(t, s));
    end if;
  end loop;
end $$;

-- Switch a tracked table between the generated PL/pgSQL row trigger and the C trigger.
create function gnomon.use_c_trigger(tbl regclass, on_off bool default true) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked;
begin
  tbl := _gnomon.base_rel(tbl);
  perform _gnomon.require_manage(tbl);
  select * into t from gnomon.tracked where rel = tbl;
  if t.id is null then raise exception '% is not tracked', tbl; end if;
  if on_off and (t.wide_key or t.mode <> 'known' or t.write_mode <> 'row') then
    raise exception 'the C trigger supports known-time, row-mode tables without wide keys';
  end if;
  update gnomon.tracked set c_trigger = on_off where id = t.id;
  perform _gnomon.attach_main_triggers(t.id);
  perform _gnomon.c_filter_attach(t.id);
end $$;

-- The read context and the shared-memory watermarks in C. Not called directly: with the module
-- loaded, a planner hook puts these in place of gnomon._ctx(), its accessors and
-- _gnomon.unchanged_since() (gnomon.c_substitute = off turns that off).
create function _gnomon.c_ctx() returns _gnomon.ctx language c stable as 'MODULE_PATHNAME', 'gnomon_c_ctx';
create function _gnomon.c_ctx_main_now() returns bool language c stable as 'MODULE_PATHNAME', 'gnomon_c_ctx_main_now';
create function _gnomon.c_ctx_branch() returns int language c stable as 'MODULE_PATHNAME', 'gnomon_c_ctx_branch';
create function _gnomon.c_ctx_asof_null() returns bool language c stable as 'MODULE_PATHNAME', 'gnomon_c_ctx_asof_null';
create function _gnomon.c_ctx_lb() returns int[] language c stable as 'MODULE_PATHNAME', 'gnomon_c_ctx_lb';
create function _gnomon.c_ctx_lc() returns gnomon.coord[] language c stable as 'MODULE_PATHNAME', 'gnomon_c_ctx_lc';
create function _gnomon.c_ctx_main_cut() returns gnomon.coord language c stable as 'MODULE_PATHNAME', 'gnomon_c_ctx_main_cut';
create function _gnomon.c_ctx_main_xmin() returns int8 language c stable as 'MODULE_PATHNAME', 'gnomon_c_ctx_main_xmin';
create function _gnomon.c_ctx_main_xmax() returns int8 language c stable as 'MODULE_PATHNAME', 'gnomon_c_ctx_main_xmax';
create function _gnomon.c_ctx_valid_at() returns timestamptz language c stable as 'MODULE_PATHNAME', 'gnomon_c_ctx_valid_at';
create function _gnomon.c_unchanged_since(int, int8) returns bool language c stable as 'MODULE_PATHNAME', 'gnomon_c_unchanged_since';
-- Point reads by primary key through a routing view: the parse-analysis hook puts this in the
-- view's place (gnomon.c_point_reads = off turns that off). The answer is always the view's.
create function _gnomon.c_point(oid, int2, anyelement) returns setof record language c stable as 'MODULE_PATHNAME', 'gnomon_c_point';
create function _gnomon.c_point_stats() returns int8[] language c volatile as 'MODULE_PATHNAME', 'gnomon_c_point_stats';
-- the module's counters summed over every session since the server started: point
-- reads by how they were answered, touched-key filter skips and scans, DDL sent to gnomon.ddl,
-- queries given the search views, upserts rewritten; none when the module is not preloaded
create function _gnomon.c_counters() returns table(name text, value int8) language c volatile as 'MODULE_PATHNAME', 'gnomon_c_counters';
-- the feed's C arm: images rebuilt in one pass over a row-index-ordered scan
create function _gnomon.c_feed(q text, cols text[], kinds text, missing jsonb, with_old bool, rel regclass, rel_name text,
                               p1 int8, p2 int8, p3 gnomon.coord, p4 gnomon.coord, p5 bool, p6 int8, p7 int8, p8 int8, p9 int8, p10 int8, p11 int8)
returns table(vkey int8, vlsn pg_lsn, tbl regclass, tname text, key jsonb, op text, xid xid8, role name, new jsonb, old jsonb)
language c volatile as 'MODULE_PATHNAME', 'gnomon_c_feed';
revoke all on function _gnomon.c_feed(text, text[], text, jsonb, bool, regclass, text, int8, int8, gnomon.coord, gnomon.coord, bool, int8, int8, int8, int8, int8, int8) from public;
-- A point read caches, per session, what it read from a table's gnomon.tracked row and from a
-- branch's gnomon.branch row, and checks only that the same row version is still visible. A
-- branch TRUNCATE (a _gnomon.cleared row) and a new branch base (rebase, merge) give those rows a
-- new version, so the check sees them too.
create function _gnomon.c_touch_tracked() returns trigger language plpgsql security definer
set search_path = pg_catalog, pg_temp as $$
begin
  update gnomon.tracked set relname = relname where id = new.tbl;
  return null;
end $$;
create trigger gnomon_c_touch after insert on _gnomon.cleared for each row execute function _gnomon.c_touch_tracked();
create function _gnomon.c_touch_branch() returns trigger language plpgsql security definer
set search_path = pg_catalog, pg_temp as $$
begin
  update gnomon.branch set last_used = last_used where id = new.branch;
  return null;
end $$;
create trigger gnomon_c_touch after insert on gnomon.branch_base for each row execute function _gnomon.c_touch_branch();

-- the touched-key filter for the tables already tracked
select _gnomon.c_filter_attach(id) from gnomon.tracked;
