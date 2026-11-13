-- Tracking tables, DDL sync and the fingerprint check.

-- (its own search_path: the text forms it hashes qualify names by it, and it is compared across
-- callers)
create function _gnomon.fingerprint(rel regclass) returns text language sql stable set search_path = pg_catalog, pg_temp as $$
  select md5(concat_ws('|',
    (select string_agg(format('%s:%s:%s:%s:%s', a.attnum, a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull,
                              coalesce(pg_get_expr(d.adbin, d.adrelid), '')), ',' order by a.attnum)
       from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
      where a.attrelid = rel and a.attnum > 0 and not a.attisdropped),
    (select string_agg(pg_get_constraintdef(c.oid), ',' order by c.conname) from pg_constraint c where c.conrelid = rel or c.confrelid = rel),
    (select string_agg(tg.tgname || pg_get_triggerdef(tg.oid), ',' order by tg.tgname) from pg_trigger tg
      where tg.tgrelid = rel and not tg.tgisinternal and tg.tgname not like 'gnomon%'),
    (select string_agg(i.indexrelid::regclass::text, ',' order by 1) from pg_index i where i.indrelid = rel and i.indisunique)))
$$;

create function _gnomon.fingerprint_check(tid int) returns void language plpgsql stable as $$
declare t gnomon.tracked := _gnomon.trow(tid);
begin
  if t.fingerprint is distinct from _gnomon.fingerprint(t.rel) then
    raise exception 'the definition of % changed since gnomon last synced it; branch writes are refused', t.rel
      using errcode = '55000', hint = format('Run select gnomon.sync(%L);', t.rel::text);
  end if;
end $$;

create function _gnomon.key_of(rel regclass, key name[]) returns name[] language plpgsql stable as $$
declare k name[];
begin
  if key is not null then
    -- a unique not-null key named at track time
    if exists (select 1 from unnest(key) x
                where not exists (select 1 from pg_attribute a where a.attrelid = rel and a.attname = x and a.attnotnull)) then
      raise exception 'tracking key columns of % must exist and be NOT NULL', rel using hint = '[gnomon:tracking_key_columns_must]';
    end if;
    if not exists (select 1 from pg_index i where i.indrelid = rel and i.indisunique and i.indpred is null and i.indexprs is null
                     and (select array_agg(a.attname order by a.attname) from unnest(i.indkey) x join pg_attribute a on a.attrelid = rel and a.attnum = x)
                         = (select array_agg(y order by y) from unnest(key) y)) then
      raise exception 'tracking key (%) of % is not covered by a unique index', array_to_string(key, ', '), rel using hint = '[gnomon:tracking_key_not_covered]';
    end if;
    return key;
  end if;
  select array_agg(a.attname order by k2.ord) into k
    from pg_index i
    cross join unnest(i.indkey) with ordinality k2(attnum, ord)
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k2.attnum
   where i.indrelid = rel and i.indisprimary;
  if k is null then
    raise exception 'table % has no primary key', rel
      using hint = 'Add a primary key, or name a unique NOT NULL key: gnomon.track(table, key => array[''col'']). [gnomon:table_no_primary_key]';
  end if;
  return k;
end $$;

-- Who may change how a table is tracked: a superuser, the role
-- that installed gnomon, or a gnomon_admin member who owns the table (the DDL tracking does on a
-- table is its owner's to do). The management functions run as gnomon's owner after this check.
create function _gnomon.require_manage(rel regclass) returns void language plpgsql stable
security definer set search_path = pg_catalog, pg_temp as $$
declare who text := coalesce(nullif(current_setting('role'), 'none'), session_user::text);
begin
  if (select r.rolsuper from pg_roles r where r.rolname = who)
     or pg_has_role(who, (select n.nspowner from pg_namespace n where n.nspname = 'gnomon'), 'member') then
    return;
  end if;
  if rel is not null and pg_has_role(who, 'gnomon_admin', 'member')
     and pg_has_role(who, (select c.relowner from pg_class c where c.oid = rel), 'member') then
    return;
  end if;
  raise exception 'managing % needs gnomon_admin and ownership of the table', coalesce(rel::text, 'every tracked table')
    using errcode = '42501', hint = 'Or a superuser, or the role that installed gnomon. [gnomon:managing_needs_gnomon_admin_ownership]';
end $$;

create function _gnomon.generate(tid int) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare cmm text := current_setting('client_min_messages'); gn_prev_ddl text := coalesce(current_setting('gnomon._in_ddl', true), '');
begin
  perform set_config('gnomon._in_ddl', '1', true);
  perform set_config('client_min_messages', 'warning', true);
  perform _gnomon.refresh_user_rls(tid);
  perform _gnomon.gen_storage(tid);
  perform _gnomon.gen_main_trigger(tid);
  perform _gnomon.gen_read(tid);
  update gnomon.tracked set fingerprint = _gnomon.fingerprint(rel) where id = tid;
  perform set_config('gnomon._in_ddl', gn_prev_ddl, true);
  perform set_config('client_min_messages', cmm, true);
end $$;

create function gnomon.track(
  tbl regclass,
  mode text default 'known',
  write_mode text default 'row',
  key name[] default null,
  key_index text default null,
  part_span int8 default null,
  merge jsonb default '{}',
  protected bool default false,
  lock_timeout text default '100ms',
  retries int default 50
) returns int
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare
  k name[]; tid int; st gnomon.stamp; nsp name; rn name; base text; wide bool; kind "char"; urls bool;
  attempt int := 0; dep record; gn_prev_ddl text := coalesce(current_setting('gnomon._in_ddl', true), ''); cmm text;
begin
  perform _gnomon.require_manage(tbl);
  select c.relkind, c.relrowsecurity, n.nspname, c.relname into kind, urls, nsp, rn
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = tbl;
  if kind not in ('r', 'p') then
    raise exception '% is not a table', tbl using hint = '[gnomon:not_table]';
  end if;
  if nsp in ('gnomon', '_gnomon', 'pg_catalog', 'information_schema') or nsp like 'gnomon\_r\_%' then
    raise exception 'cannot track % in schema %', tbl, nsp using hint = '[gnomon:cannot_track_schema]';
  end if;
  if exists (select 1 from gnomon.tracked t where t.rel = tbl) then
    return (select id from gnomon.tracked t where t.rel = tbl);
  end if;
  if mode not in ('known', 'bitemporal') then raise exception 'mode must be known or bitemporal' using hint = '[gnomon:mode_must_known_bitemporal]'; end if;
  k := _gnomon.key_of(tbl, key);
  -- wide keys get an internal bigint id
  select cardinality(k) > 2 or sum(case when t.typlen < 0 then 17 else t.typlen end) > 16 into wide
    from unnest(k) x join pg_attribute a on a.attrelid = tbl and a.attname = x join pg_type t on t.oid = a.atttypid;
  base := case when nsp = 'public' then rn else nsp || '__' || rn end;
  if length(base) > 40 then base := left(base, 30) || '_' || tbl::oid; end if;

  -- metadata-only locks, taken under lock_timeout with retries
  loop
    begin
      perform set_config('lock_timeout', lock_timeout, true);
      execute format('lock table %s in share row exclusive mode', tbl);
      perform set_config('lock_timeout', '0', true);
      exit;
    exception when lock_not_available then
      attempt := attempt + 1;
      if attempt > retries then
        raise exception 'could not lock % within % after % attempts', tbl, lock_timeout, retries using hint = '[gnomon:could_not_lock_within]';
      end if;
      perform pg_sleep(least(0.05 * attempt, 1));
    end;
  end loop;

  st := gnomon._stamp();
  insert into gnomon.tracked(rel, nsp, relname, base, mode, write_mode, key_cols, wide_key, merge, protected,
                             part_span, key_index, user_rls, track_coord, track_key, track_xoff, track_role)
  values (tbl, nsp, rn, base, mode, write_mode, k, wide, coalesce(merge, '{}'), protected,
          coalesce(part_span, gnomon._cfg('part_span')::int8),
          coalesce(key_index, 'brin'), coalesce(urls, false),   -- RLS on, with or without policies
          gnomon._coordinate_self(), st.key, st.xoff, st.role)
  returning id into tid;
  update gnomon.tracked set blob_threshold = gnomon._cfg('blob_threshold')::int where id = tid;
  -- with the C module installed, tables it can version get its trigger (setting c_trigger: auto | off)
  if gnomon._cfg('c_trigger') = 'auto' and to_regproc('_gnomon.c_version_trigger') is not null
     and mode = 'known' and write_mode = 'row' and not wide then
    update gnomon.tracked set c_trigger = true where id = tid;
  end if;
  perform _gnomon.generate(tid);
  -- with the C module installed: its touched-key filter on the new touched-key tables
  -- (its trigger DDL on gnomon's own tables needs no resync: _in_ddl keeps the event triggers out)
  if to_regproc('_gnomon.c_filter_attach') is not null then
    cmm := current_setting('client_min_messages');
    perform set_config('client_min_messages', 'warning', true);
    perform set_config('gnomon._ddl_internal', '1', true);
    perform set_config('gnomon._in_ddl', '1', true);
    execute 'select _gnomon.c_filter_attach($1)' using tid;
    perform set_config('gnomon._in_ddl', gn_prev_ddl, true);
    perform set_config('gnomon._ddl_internal', '', true);
    perform set_config('client_min_messages', cmm, true);
  end if;
  perform _gnomon.refresh_schema_views(nsp);
  -- tables related by foreign keys pick up the new cascade and check targets
  for dep in select t.id from gnomon.tracked t
              where t.id <> tid and t.rel in (select conrelid from pg_constraint where confrelid = tbl and contype = 'f'
                                              union select confrelid from pg_constraint where conrelid = tbl and contype = 'f') loop
    perform set_config('gnomon._in_ddl', '1', true);
    perform _gnomon.gen_read(dep.id);
    perform set_config('gnomon._in_ddl', gn_prev_ddl, true);
  end loop;
  perform gnomon._bump();
  return tid;
end $$;

create function gnomon.track_schema(nsp name, mode text default 'known', write_mode text default 'row') returns int
language plpgsql volatile as $$
declare r record; n int := 0;
begin
  for r in select c.oid::regclass as rel from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
            where ns.nspname = nsp and c.relkind in ('r','p')
              and not exists (select 1 from pg_inherits i where i.inhrelid = c.oid)
              and exists (select 1 from pg_index i where i.indrelid = c.oid and i.indisprimary)
            order by c.oid loop
    perform gnomon.track(r.rel, mode, write_mode);
    n := n + 1;
  end loop;
  perform _gnomon.refresh_schema_views(nsp);
  return n;
end $$;

create function _gnomon.drop_routing(tid int, keep_functions bool default false) returns void
language plpgsql volatile set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked := _gnomon.trow(tid); f record; gn_prev_ddl text := coalesce(current_setting('gnomon._in_ddl', true), '');
begin
  perform set_config('gnomon._in_ddl', '1', true);
  execute format('drop view if exists %s cascade', _gnomon.robj(t));
  execute format('drop view if exists %s cascade', _gnomon.robj_s(t));
  execute format('drop view if exists %s cascade', _gnomon.obj(t, 'hist'));
  execute format('drop view if exists %s cascade', _gnomon.obj(t, 'hist_s'));
  execute format('drop view if exists %I.%I', 'gnomon_q_' || t.nsp, t.relname);
  execute format('drop policy if exists gnomon_arm1 on %s', _gnomon.qrel(t));
  execute format('drop policy if exists gnomon_arm1_s on %s', _gnomon.qrel(t));
  execute format('drop policy if exists gnomon_user_arm1 on %s', _gnomon.qrel(t));
  if to_regclass(_gnomon.obj(t, 'ck')) is not null then
    execute format('drop policy if exists gnomon_ck on %s', _gnomon.obj(t, 'ck'));
    execute format('drop policy if exists gnomon_ck_s on %s', _gnomon.obj(t, 'ck'));
  end if;
  if not keep_functions then
    for f in select p.oid::regprocedure as fn from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = '_gnomon' and p.proname like t.base || '\_\_%' loop
      execute format('drop function if exists %s cascade', f.fn);
    end loop;
  end if;
  perform set_config('gnomon._in_ddl', gn_prev_ddl, true);
end $$;

create function gnomon.untrack(tbl regclass, keep_history bool default false) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; s text; gn_prev_ddl text := coalesce(current_setting('gnomon._in_ddl', true), '');
begin
  perform _gnomon.require_manage(_gnomon.base_rel(tbl));

  tbl := _gnomon.base_rel(tbl);  select * into t from gnomon.tracked where rel = tbl;
  if t.id is null then raise exception '% is not tracked', tbl using hint = '[gnomon:not_tracked]'; end if;
  perform set_config('gnomon._in_ddl', '1', true);
  perform _gnomon.drop_routing(t.id);
  foreach s in array array['gnomon_v','gnomon_vs_i','gnomon_vs_u','gnomon_vs_d','gnomon_truncate','gnomon_protect','gnomon_bt'] loop
    execute format('drop trigger if exists %I on %s', s, tbl);
  end loop;
  execute format('drop policy if exists gnomon_all on %s', tbl);
  if not t.user_rls then
    execute format('alter table %s disable row level security', tbl);
  end if;
  if not keep_history then
    foreach s in array array['v','b','b_u','bk','bk_u','bv','bv_u','id','sched','ck'] loop
      execute format('drop table if exists %s cascade', _gnomon.obj(t, s));
    end loop;
  end if;
  delete from gnomon.tracked where id = t.id;
  perform _gnomon.passthrough(tbl);
  perform set_config('gnomon._in_ddl', gn_prev_ddl, true);
  perform gnomon._bump();
end $$;

create function gnomon.sync(tbl regclass default null) returns int
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t record; n int := 0;
begin

  tbl := _gnomon.base_rel(tbl);
  perform _gnomon.require_manage(tbl);
  for t in select * from gnomon.tracked where tbl is null or rel = tbl order by id loop
    perform _gnomon.drop_routing(t.id, true);
    perform _gnomon.generate(t.id);
    n := n + 1;
  end loop;
  for t in select distinct nsp from gnomon.tracked loop
    perform _gnomon.refresh_schema_views(t.nsp);
  end loop;
  perform gnomon._bump();
  return n;
end $$;

create function gnomon.set_write_mode(tbl regclass, write_mode text) returns void language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform _gnomon.require_manage(_gnomon.base_rel(tbl));

  tbl := _gnomon.base_rel(tbl);  update gnomon.tracked set write_mode = $2 where rel = tbl;
  perform _gnomon.attach_main_triggers((select id from gnomon.tracked where rel = tbl));
end $$;

create function _gnomon.store_merge_strategy(tbl regclass, col name, strategy text) returns void language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform _gnomon.require_manage(tbl);
  update gnomon.tracked set merge = merge || jsonb_build_object(col, strategy) where rel = tbl;
  if not found then raise exception '% is not tracked', tbl using hint = '[gnomon:not_tracked]'; end if;
end $$;

-- (the function name resolves with the caller's search_path; the definer stores it qualified)
create function gnomon.set_merge_strategy(tbl regclass, col name, strategy text) returns void language plpgsql volatile as $$
declare fn text;
begin

  tbl := _gnomon.base_rel(tbl);
  if strategy not in ('conflict','ours','theirs','counter','jsonb','set','text3') then
    -- a function (base, ours, theirs) -> value, stored schema-qualified: merges resolve it under a
    -- fixed search_path
    fn := (select format('%I.%I', n.nspname, p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where p.oid = coalesce(to_regprocedure(strategy || '(jsonb, jsonb, jsonb)'), to_regproc(strategy)));
    if fn is null then
      raise exception 'unknown merge strategy "%"', strategy
        using hint = 'Use conflict, ours, theirs, counter, jsonb, set, text3, or a function (base jsonb, ours jsonb, theirs jsonb) -> jsonb. [gnomon:unknown_merge_strategy]';
    end if;
    strategy := fn;
  end if;
  perform _gnomon.store_merge_strategy(tbl, col, strategy);
end $$;

create function gnomon.protect(tbl regclass, on_off bool default true) returns void language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform _gnomon.require_manage(_gnomon.base_rel(tbl));

  tbl := _gnomon.base_rel(tbl);  update gnomon.tracked set protected = on_off where rel = tbl;
  if not found then raise exception '% is not tracked', tbl using hint = '[gnomon:not_tracked]'; end if;
  perform _gnomon.attach_main_triggers((select id from gnomon.tracked where rel = tbl));
end $$;

-------------------------------------------------------------------------------
-- Event triggers. Our own DDL sets gnomon._in_ddl so it does not recurse.
-------------------------------------------------------------------------------
-- Does a statement's (lowercased) text name this identifier as a whole word?
create function _gnomon.mentions(qtext text, name text) returns bool language sql immutable as $$
  select qtext ~ ('(^|[^a-z0-9_$])' || regexp_replace(lower(name), '([.^$*+?()\[\]{}|\\])', '\\\1', 'g') || '($|[^a-z0-9_$])')
$$;

create function _gnomon.on_ddl_start() returns event_trigger language plpgsql as $$
declare t record; r record; qtext text := lower(current_query()); all_objs bool;
begin
  if current_setting('gnomon._in_ddl', true) = '1' then return; end if;
  -- pg_restore and pg_dump scripts run with an empty search_path: restore objects as dumped
  if current_setting('search_path') = '' then return; end if;
  -- plain DDL on a tracked table from a branch session would change main for every branch
  -- (DDL gnomon runs itself, a merge's or gnomon.ddl's, is not this: gnomon._ddl_internal)
  if coalesce(current_setting('gnomon.branch', true), '') not in ('', 'main')
     and coalesce(current_setting('gnomon._ddl_internal', true), '') <> '1'
     and tg_tag in ('ALTER TABLE', 'DROP TABLE', 'CREATE INDEX', 'DROP INDEX', 'ALTER INDEX', 'COMMENT')
     and exists (select 1 from gnomon.tracked x where _gnomon.mentions(qtext, x.relname)) then
    raise exception '% on a branch session changes main for every branch', tg_tag
      using errcode = '0A000',
            hint = 'Run it through gnomon.ddl(''...'') (or gnomon migrate <branch> -- files) to change the branch only, or gnomon.use(''main'') first. [gnomon:ddl_on_branch]';
  end if;
  if tg_tag not in ('ALTER TABLE', 'DROP TABLE', 'ALTER TYPE', 'DROP SCHEMA', 'ALTER SCHEMA', 'DROP OWNED', 'DROP POLICY',
                    'CREATE POLICY', 'ALTER POLICY', 'DROP TRIGGER', 'CREATE TRIGGER', 'DROP INDEX', 'ALTER INDEX', 'DROP DOMAIN', 'ALTER DOMAIN',
                    'DROP VIEW', 'ALTER VIEW', 'DROP MATERIALIZED VIEW', 'ALTER MATERIALIZED VIEW', 'DROP FOREIGN TABLE', 'ALTER FOREIGN TABLE') then
    return;
  end if;
  all_objs := tg_tag in ('DROP SCHEMA', 'DROP OWNED', 'ALTER TYPE', 'ALTER DOMAIN', 'DROP DOMAIN');
  -- pass-through (and masked) views of untracked relations the statement may name would block a
  -- DROP or a column type change, and go stale on ADD COLUMN: drop them now, re-create them when
  -- the statement is done (on_ddl_end)
  for r in select n.nspname, c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname like 'gnomon\_r\_%' and c.relkind = 'v'
              and (all_objs or _gnomon.mentions(qtext, c.relname))
              and not exists (select 1 from gnomon.tracked tr where tr.relname = c.relname
                                 and n.nspname in ('gnomon_r_' || tr.nsp, 'gnomon_r_' || tr.nsp || '__s'))
  loop
    perform set_config('gnomon._in_ddl', '1', true);
    execute format('drop view if exists %I.%I cascade', r.nspname, r.relname);
    perform set_config('gnomon._in_ddl', '', true);
    perform set_config('gnomon._resync_nsp', coalesce(current_setting('gnomon._resync_nsp', true), '')
                       || regexp_replace(r.nspname, '^gnomon_r_(.*?)(__s|__m[0-9]+)?$', '\1') || chr(1), true);
  end loop;
  -- only when the statement may touch a tracked table: views and functions over it block the DDL
  for t in select * from gnomon.tracked loop
    if all_objs or _gnomon.mentions(qtext, t.relname) then
      perform _gnomon.drop_routing(t.id, tg_tag not in ('DROP TABLE', 'DROP SCHEMA', 'DROP OWNED'));
      perform set_config('gnomon._resync', coalesce(nullif(current_setting('gnomon._resync', true), ''), '') || t.id || ',', true);
    end if;
  end loop;
end $$;

-- After an upgrade of the extension (src/upgrade): rebuild every per-table object from the new
-- code. Run by the ddl_command_end trigger once ALTER EXTENSION gnomon UPDATE is done, still in
-- its transaction but outside the extension script, so the objects stay ordinary objects (dumped
-- by pg_dump) rather than members of the extension; the plain-SQL upgrade calls it directly.
create function _gnomon.upgrade_regenerate() returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare t record; s name; o jsonb;
begin
  perform set_config('gnomon._up_regen', '', true);
  -- this function rebuilds everything itself, so its own DDL must not reach the ddl_command_end
  -- trigger: that would regenerate a table a second time and leave gnomon._in_ddl cleared, and
  -- the mask profiles below would then see their own DROP SCHEMA come back through the trigger.
  perform set_config('gnomon._in_ddl', '1', true);
  for t in select id from gnomon.tracked order by id loop
    perform _gnomon.generate(t.id);
  end loop;
  for s in select distinct nsp from gnomon.tracked loop
    perform _gnomon.refresh_schema_views(s);
  end loop;
  for t in select name from gnomon.mask_profile loop
    perform gnomon.build_mask_profile(t.name);
  end loop;
  for o in select jsonb_array_elements(coalesce(nullif(current_setting('gnomon._up_outbox', true), ''), '[]')::jsonb) loop
    perform gnomon.outbox((o ->> 'rel')::regclass, o ->> 'channel');
  end loop;
  perform set_config('gnomon._up_outbox', '', true);
  perform _gnomon.regen_versions();   -- schema versions' views
  perform set_config('gnomon._in_ddl', '', true);
  perform gnomon._bump();
end $$;

create function _gnomon.on_ddl_end() returns event_trigger language plpgsql as $$
declare r record; t gnomon.tracked; ids text := coalesce(current_setting('gnomon._resync', true), '');
        nsps text := coalesce(current_setting('gnomon._resync_nsp', true), ''); n text; rn name; rnsp name;
begin
  if tg_tag = 'ALTER EXTENSION' and current_setting('gnomon._up_regen', true) = '1' then
    perform _gnomon.upgrade_regenerate();
    return;
  end if;
  if current_setting('gnomon._in_ddl', true) = '1' then return; end if;
  if current_setting('search_path') = '' then return; end if;
  perform set_config('gnomon._resync', '', true);
  perform set_config('gnomon._resync_nsp', '', true);
  -- grants on tracked tables are mirrored onto their routing views
  if tg_tag in ('GRANT', 'REVOKE') then
    perform set_config('gnomon._in_ddl', '1', true);
    for t in select * from gnomon.tracked loop
      if to_regclass(_gnomon.robj(t)) is not null then perform _gnomon.sync_grants(t.id); end if;
    end loop;
    perform set_config('gnomon._in_ddl', '', true);
    return;
  end if;
  for t in select * from gnomon.tracked loop
    if not exists (select 1 from pg_class where oid = t.rel) then
      -- dropped tracked tables: forget them (storage stays unless untracked explicitly)
      perform set_config('gnomon._in_ddl', '1', true);
      perform _gnomon.drop_routing(t.id);
      delete from gnomon.tracked where id = t.id;
      perform set_config('gnomon._in_ddl', '', true);
      continue;
    end if;
    -- renamed, or moved to another schema: tracking follows the table (its storage keeps its names)
    select c.relname, ns.nspname into rn, rnsp from pg_class c join pg_namespace ns on ns.oid = c.relnamespace where c.oid = t.rel;
    if rn <> t.relname or rnsp <> t.nsp then
      perform set_config('gnomon._in_ddl', '1', true);
      perform _gnomon.drop_routing(t.id, true);   -- the routing views under the old name
      update gnomon.tracked set relname = rn, nsp = rnsp where id = t.id;
      perform set_config('gnomon._in_ddl', '', true);
      nsps := nsps || t.nsp || chr(1) || rnsp || chr(1);
      ids := ids || t.id || ',';
    end if;
    if ids like '%' || t.id || ',%' or exists (
        select 1 from pg_event_trigger_ddl_commands() c where c.objid = t.rel) then
      perform _gnomon.drop_routing(t.id, true);
      perform _gnomon.generate(t.id);
    end if;
  end loop;
  -- pass-through views dropped at the start of the statement come back for what still exists
  if nsps <> '' then
    perform set_config('gnomon._in_ddl', '1', true);
    foreach n in array (select array_agg(distinct x) from unnest(string_to_array(nsps, chr(1))) x where x <> '') loop
      if exists (select 1 from pg_namespace where nspname = n) then perform _gnomon.refresh_schema_views(n); end if;
    end loop;
    for r in select name from gnomon.mask_profile loop
      perform gnomon.build_mask_profile(r.name);
    end loop;
    perform set_config('gnomon._in_ddl', '', true);
  end if;
  -- new tables and views in routed schemas get routing views
  for r in select * from pg_event_trigger_ddl_commands() c
            where c.object_type in ('table', 'view', 'materialized view', 'foreign table') and c.command_tag like 'CREATE%' loop
    perform set_config('gnomon._in_ddl', '1', true);
    perform _gnomon.passthrough(r.objid::regclass);
    perform set_config('gnomon._in_ddl', '', true);
  end loop;
  -- open schema versions read through the routing views just regenerated
  if ids <> '' or nsps <> '' or exists (select 1 from pg_event_trigger_ddl_commands() c join gnomon.tracked x on x.rel = c.objid) then
    perform _gnomon.regen_versions();
  end if;
  perform gnomon._bump();
end $$;

do $$
begin
  begin
    create event trigger gnomon_ddl_start on ddl_command_start execute function _gnomon.on_ddl_start();
    create event trigger gnomon_ddl_end on ddl_command_end execute function _gnomon.on_ddl_end();
  exception when insufficient_privilege then
    insert into gnomon.setting_default values ('event_triggers_installed', 'off', 'Event triggers were not allowed at install time.');
    update gnomon.setting_default set value = 'off' where name = 'event_triggers';
    raise notice 'gnomon: event triggers are not allowed here; branch writes check table fingerprints instead (run gnomon.sync() after DDL)';
  end;
end $$;
