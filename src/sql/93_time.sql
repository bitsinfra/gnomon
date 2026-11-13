-- SCD type-2 views, timeline and series, the graph and the metrics source.

-------------------------------------------------------------------------------
-- When a version was written: its commit time where known, else its commit-log row, else the
-- first tick that saw it.
-------------------------------------------------------------------------------
create function _gnomon.version_time(k int8, xoff int4) returns timestamptz language plpgsql stable as $$
declare x xid8 := (((k & 281474976710655) - xoff)::text)::xid8; ts timestamptz;
begin
  if current_setting('track_commit_timestamp') = 'on' and (k >> 48) = gnomon._epoch_ro() then
    begin
      ts := pg_xact_commit_timestamp(((x::text::int8 % 4294967296)::text)::xid);
    exception when others then ts := null;
    end;
    if ts is not null then return ts; end if;
  end if;
  select xa.at into ts from gnomon.xact xa where xa.epoch = (k >> 48)::int2 and xa.xid = x;
  return coalesce(ts, gnomon._tick_of(k, xoff));
end $$;

-------------------------------------------------------------------------------
-- SCD type 2
-------------------------------------------------------------------------------
-- <table>_history: one row per version, with valid_from, valid_to (null while current),
-- is_current, op, xid and actor. Copies kept for storage (carry-forward keyframes) are skipped; a
-- row tracked before it changed starts at the tracking time, and a row never changed since is one
-- current row from then. Deletes end a row's validity. Images are rebuilt set-based, as the
-- feed's large windows are. Run it again after DDL on the table.
create function gnomon.scd2(tbl regclass, view_name text default null) returns regclass
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; cs _gnomon.col[]; ks _gnomon.col[]; vs _gnomon.col[]; pk text; kfirst text; nat text; cols text; vn text; r regclass;
        keq text; g record; idj text;
begin
  tbl := _gnomon.base_rel(tbl);
  select * into t from gnomon.tracked where rel = tbl;
  if t.id is null then raise exception '% is not tracked', tbl using hint = '[gnomon:not_tracked]'; end if;
  if t.mode <> 'known' then raise exception 'scd2 views are for known-time tables; bitemporal tables already have both axes' using errcode = '0A000', hint = '[gnomon:scd2_views_known_time]'; end if;
  perform _gnomon.require_manage(tbl);
  cs := _gnomon.tcols(t.id); ks := _gnomon.keys(cs); vs := _gnomon.vals(cs);
  vn := coalesce(view_name, t.relname || '_history');
  pk := case when t.wide_key then 'v.gn_rid' else _gnomon.lst(ks, 'v.') end;
  kfirst := coalesce((select string_agg(format('first_value(v.gn_c%1$s) over wk as k_gn_c%1$s', c.slot)
                                        || case when c.large then format(', first_value(v.gn_h%1$s) over wk as k_gn_h%1$s', c.slot) else '' end, ', ')
                        from unnest(vs) c), 'null::int as gn_none');
  nat := (select string_agg(case when c.iskey then case when t.wide_key then 'i.' else 'v.' end || c.q
                                 else replace(replace(_gnomon.rval(c), 'k.gn_mask', 'v.k_gn_mask'), 'k.gn_', 'v.k_gn_') end
                            || ' AS ' || c.q, ', ' order by c.num) from unnest(cs) c);
  cols := (select string_agg(c.q, ', ' order by c.num) from unnest(cs) c);
  keq := case when t.wide_key then (select string_agg(format('i2.%1$s = cur.%1$s', k.q), ' and ') from unnest(ks) k)
              else (select string_agg(format('v2.%1$s = cur.%1$s', k.q), ' and ') from unnest(ks) k) end;
  idj := case when t.wide_key then format('LEFT JOIN %s i ON i.gn_rid = v.gn_rid', _gnomon.obj(t, 'id')) else '' end;
  execute format('drop view if exists %I.%I', t.nsp, vn);
  execute _gnomon.tpl($v$
create view @VIEW@ as
select @COLS@, h.valid_from, h.valid_to, h.valid_to is null as is_current, h.op, h.xid, h.actor
  from (select x.*, lead(x.valid_from) over (partition by x.gn_pk order by x.gn_key, x.gn_lsn) as valid_to
          from (select v.*, case when v.gn_flags & 32 <> 0 then @TRACKED@::timestamptz else _gnomon.version_time(v.gn_key, v.gn_xoff) end as valid_from,
                       case when v.gn_flags & 32 <> 0 then 'tracked' when v.gn_flags & 1 <> 0 then 'insert' when v.gn_flags & 4 <> 0 then 'delete' else 'update' end as op,
                       case when v.gn_flags & 32 <> 0 then null else (((v.gn_key & 281474976710655) - v.gn_xoff)::text)::xid8 end as xid,
                       (select xa.actor from gnomon.xact xa where xa.epoch = (v.gn_key >> 48)::int2
                           and xa.xid = (((v.gn_key & 281474976710655) - v.gn_xoff)::text)::xid8) as actor
                  from (select v.gn_key, v.gn_lsn, v.gn_flags, v.gn_xoff, v.gn_pk, @NAT@
                          from (select v.*, first_value(v.gn_mask) over wk as k_gn_mask, @KFIRST@
                                  from (select v.*, @PKX@ as gn_pk, count(*) filter (where (v.gn_flags & 8) <> 0) over wkf as gn_kg
                                          from @V@ v
                                        window wkf as (partition by @PK@, v.gn_part order by v.gn_key, v.gn_lsn rows between unbounded preceding and current row)) v
                                window wk as (partition by @PK@, v.gn_part, v.gn_kg order by v.gn_key, v.gn_lsn rows between unbounded preceding and current row)) v
                          @IDJ@) v
                 where (v.gn_flags & 16) = 0) x) h
 where h.op <> 'delete'
union all
-- rows unchanged since tracking: no version, one current row
select @CURCOLS@, @TRACKED@::timestamptz, null::timestamptz, true, 'tracked', null::xid8, null::text
  from @REL@ cur
 where not exists (select 1 from @V@ v2 @IDJ2@ where @KEQ@)$v$,
    'VIEW', format('%I.%I', t.nsp, vn), 'COLS', (select string_agg('h.' || c.q, ', ' order by c.num) from unnest(cs) c),
    'TRACKED', quote_literal(t.created_at::text), 'NAT', nat, 'KFIRST', kfirst,
    'PKX', case when t.wide_key then 'v.gn_rid' else 'row(' || _gnomon.lst(ks, 'v.') || ')' end, 'PK', pk,
    'V', _gnomon.obj(t, 'v'), 'IDJ', idj, 'CURCOLS', (select string_agg('cur.' || c.q, ', ' order by c.num) from unnest(cs) c),
    'REL', _gnomon.qrel(t), 'KEQ', keq,
    'IDJ2', case when t.wide_key then format('join %s i2 on i2.gn_rid = v2.gn_rid', _gnomon.obj(t, 'id')) else '' end);
  r := format('%I.%I', t.nsp, vn)::regclass;
  -- the view reads gnomon's storage: it belongs to gnomon_reader, and only roles that may read the
  -- table may read it
  execute format('alter view %s owner to gnomon_reader', r);
  execute format('revoke all on %s from public', r);
  for g in select distinct a.grantee from information_schema.role_table_grants a
            where a.table_schema = t.nsp and a.table_name = t.relname and a.privilege_type = 'SELECT' loop
    execute format('grant select on %s to %s', r, case when g.grantee = 'PUBLIC' then 'public' else quote_ident(g.grantee) end);
  end loop;
  execute format('grant select on %s to %I', r, (select pg_get_userbyid(c.relowner) from pg_class c where c.oid = t.rel));
  execute format('comment on view %s is %L', r, format('gnomon SCD type-2 history of %s (gnomon.scd2)', t.rel));
  return r;
end $$;

-- For incremental loads: changes since a reference with their validity start, from the feed.
-- A filter on valid_from cannot reach below the view's window functions, so a large table loads
-- through this, not the view.
create function gnomon.scd2_changes(tbl regclass, since text, until text default null)
returns table(valid_from timestamptz, op text, xid xid8, key jsonb, row_image jsonb, old_image jsonb, vkey int8, vlsn pg_lsn)
language sql volatile as $$
  select _gnomon.version_time(c.vkey, ((c.vkey & 281474976710655) - (c.xid::text::int8 & 281474976710655))::int4),
         c.op, c.xid, c.key, c.new, c.old, c.vkey, c.vlsn
    from gnomon.changes(since, until, array[tbl], 'both') c
$$;

-- dbt: a table kept in dbt's snapshot shape, from the change feed (the gnomon_dbt package's
-- gnomon_history materialization calls this). Unlike a dbt snapshot, which records the state at
-- each run, it records every version, and a hard delete closes the row. The first call loads the
-- table's whole history; later ones apply the changes since the model's consumer. dbt_scd_id
-- (md5 of the key and the version) makes a change applied twice land once.
create function gnomon.dbt_snapshot(tbl regclass, target text, consumer text default null) returns jsonb
language plpgsql volatile as $$
declare t gnomon.tracked; cs _gnomon.col[]; cols text; keyeq text; keyj text; cons text := coalesce(consumer, 'dbt:' || target); tgt regclass;
        ins bigint := 0; closed bigint := 0; n bigint; r record; batch int; first bool := false; tracked_at timestamptz; pos text;
        ob text := current_setting('gnomon.branch', true); oa text := current_setting('gnomon.as_of', true);
begin
  -- the target is an ordinary table on main: the function's own writes go there whatever branch
  -- or moment the session is on (put back at the end)
  perform set_config('gnomon.branch', '', true);
  perform set_config('gnomon.as_of', '', true);
  tbl := _gnomon.base_rel(tbl);
  select * into t from gnomon.tracked x where x.rel = tbl;
  if t.id is null then raise exception '% is not tracked', tbl using hint = '[gnomon:not_tracked]'; end if;
  cs := _gnomon.cols(t.rel);
  cols := (select string_agg(c.q, ', ' order by c.num) from unnest(cs) c);
  keyeq := (select string_agg(format('d.%1$I = (k.p).%1$I', k), ' and ') from unnest(t.key_cols) k);
  keyj := 'jsonb_build_object(' || (select string_agg(format('%L, x.%I', k, k), ', ') from unnest(t.key_cols) k) || ')';
  tracked_at := _gnomon.version_time(t.track_key, t.track_xoff);
  tgt := to_regclass(target);
  if tgt is null then
    -- the first run: the whole history, from the tracking point
    first := true;
    execute format('create table %s as select %s, null::text as dbt_scd_id, null::timestamptz as dbt_updated_at, null::timestamptz as dbt_valid_from, null::timestamptz as dbt_valid_to from %s where false',
                   target, cols, tbl);
    execute format('create index on %s (%s) where dbt_valid_to is null', target, (select string_agg(quote_ident(k), ', ') from unnest(t.key_cols) k));
    execute format('create unique index on %s (dbt_scd_id)', target);
    tgt := to_regclass(target);
    if not exists (select 1 from gnomon.consumer c where c.name = cons) then
      perform gnomon.feed_create(cons, gnomon.coord_text(t.track_coord));
    end if;
  end if;
  -- the changes since, in order: each closes the key's open row and (unless a delete) opens one;
  -- a key's first update or delete opens its state from before it, valid from the tracking point
  loop
    batch := 0;
    -- (a change's time is its commit time, or the first tick at or after it; one made after the
    -- last tick has neither yet and takes the time it is read, likewise an upper bound, so the
    -- rows valid at every tick still equal the as-of read there)
    for r in select f.*, coalesce(_gnomon.version_time(f.vkey, ((f.vkey & 281474976710655) - (f.xid::text::int8 & 281474976710655))::int4),
                                  clock_timestamp()) as at
               from gnomon.feed_poll(cons, 1000) f loop
      batch := batch + 1;
      continue when r.tbl <> tbl;
      if r.op in ('update', 'delete') and r.old is not null then
        execute format($q$insert into %s select (k.p).*, md5($2::text || ':tracked'), $3, $3, null::timestamptz
                           from (select jsonb_populate_record(null::%s, $1) as p) k
                          where not exists (select 1 from %s d where %s)$q$, target, tbl, target, keyeq) using r.old, r.key, tracked_at;
        get diagnostics n = row_count;
        ins := ins + n;
      end if;
      execute format('update %s d set dbt_valid_to = $2 from (select jsonb_populate_record(null::%s, $1) as p) k where %s and d.dbt_valid_to is null and d.dbt_valid_from <= $2',
                     target, tbl, keyeq) using coalesce(r.new, r.old, r.key), r.at;
      get diagnostics n = row_count;
      closed := closed + n;
      if r.op <> 'delete' then
        execute format($q$insert into %s select (k.p).*, md5($2::text || ':' || $3::text), $4, $4, null::timestamptz
                           from (select jsonb_populate_record(null::%s, $1) as p) k
                          where not exists (select 1 from %s d where d.dbt_scd_id = md5($2::text || ':' || $3::text))$q$,
                       target, tbl, target) using r.new, r.key, r.vkey, r.at;
        get diagnostics n = row_count;
        ins := ins + n;
      end if;
    end loop;
    exit when batch < 1000;
  end loop;
  if first then
    -- rows never written since tracking: as they are at the consumer's position, from the tracking point
    select gnomon.coord_text(c.pos) into pos from gnomon.consumer c where c.name = cons;
    -- (read at that moment into a temporary table, then written with the moment unset: the C
    -- module routes every name while gnomon.as_of is set, the target's included)
    perform set_config('gnomon.as_of', pos, true);
    execute format('create temp table gn_dbt_first on commit drop as select %s from %I.%I x',
                   (select string_agg('x.' || c.q, ', ' order by c.num) from unnest(cs) c), 'gnomon_r_' || t.nsp, t.relname);
    perform set_config('gnomon.as_of', '', true);
    execute format($q$insert into %s select %s, md5(%s::text || ':tracked'), $1, $1, null::timestamptz from pg_temp.gn_dbt_first x
                       where not exists (select 1 from %s d where %s)$q$,
                   target, (select string_agg('x.' || c.q, ', ' order by c.num) from unnest(cs) c), keyj, target,
                   (select string_agg(format('d.%1$I = x.%1$I', k), ' and ') from unnest(t.key_cols) k)) using tracked_at;
    get diagnostics n = row_count;
    ins := ins + n;
    drop table pg_temp.gn_dbt_first;
  end if;
  perform set_config('gnomon.branch', coalesce(ob, ''), true);
  perform set_config('gnomon.as_of', coalesce(oa, ''), true);
  return jsonb_build_object('target', tgt::text, 'consumer', cons, 'first', first, 'inserted', ins, 'closed', closed);
end $$;

-------------------------------------------------------------------------------
-- Timeline and series
-------------------------------------------------------------------------------
-- One column of one row over time: each version where its value changed.
create function gnomon.series(tbl regclass, key jsonb, col text, since timestamptz default null, until timestamptz default null,
                              branch text default 'main')
returns table(at timestamptz, value jsonb, op text, vkey int8, actor text, on_branch text) language sql volatile as $$
  select h.at, h.v, h.op, h.vkey, h.actor, h.on_branch
    from (select h.*, h.row_image -> col as v, lag(h.row_image -> col) over (order by h.ord) as pv
            from gnomon.history(tbl, key, branch) with ordinality as h(vkey, xid, role, op, at_tick, actor, reason, row_image, at, on_branch, ord)) h
   where (h.ord = 1 or h.v is distinct from h.pv)
     and (since is null or h.at >= since) and (until is null or h.at <= until)
   order by h.ord
$$;

-- A query evaluated at the tick nearest each step. Each point is a past read, so the number of
-- points is capped and every evaluation has a statement timeout.
create function gnomon.metric_series(sql text, since timestamptz, until timestamptz default now(), step interval default '1 hour',
                                     max_points int default 100, branch text default 'main', timeout interval default '30 seconds')
returns table(at timestamptz, tick_at timestamptz, value numeric) language plpgsql volatile as $$
declare ts timestamptz; tk gnomon.tick; n int := 0; old_to text := current_setting('statement_timeout');
begin
  if (select count(*) from generate_series(since, until, step)) > max_points then
    raise exception 'more than % points from % to % by %', max_points, since, until, step
      using errcode = '54000', hint = 'Use a larger step or raise max_points. [gnomon:too_many_points]';
  end if;
  perform set_config('statement_timeout', (extract(epoch from timeout) * 1000)::int::text, true);
  for ts in select g from generate_series(since, until, step) g loop
    select * into tk from gnomon.tick x where x.at <= ts order by x.at desc, x.id desc limit 1;
    continue when tk.id is null;
    at := ts; tick_at := tk.at;
    value := _gnomon.eval_metric(sql, branch, gnomon.coord_text(tk.coord));
    return next;
  end loop;
  perform set_config('statement_timeout', old_to, true);
end $$;

-- A sum or count over one table, as it changes: its value at `since`, then one pass over the feed
-- with both images, each change contributing new minus old. Cost follows the changes.
create function gnomon.metric_series_incremental(tbl regclass, agg text, col text default null, filter text default null,
                                                 since text default null, until text default null)
returns table(at timestamptz, value numeric, vkey int8) language plpgsql volatile as $$
declare t gnomon.tracked; v0 numeric; f text; fx text; q text;
begin
  tbl := _gnomon.base_rel(tbl);
  select * into t from gnomon.tracked where rel = tbl;
  if t.id is null then raise exception '% is not tracked', tbl using hint = '[gnomon:not_tracked]'; end if;
  if agg not in ('count', 'sum') then raise exception 'agg must be count or sum' using hint = '[gnomon:agg_must_count_sum]'; end if;
  if agg = 'sum' and col is null then raise exception 'a sum needs a column' using hint = '[gnomon:sum_needs_column]'; end if;
  since := coalesce(since, gnomon.coord_text(t.track_coord));
  f := coalesce(filter, 'true');
  fx := case when agg = 'count' then '1' else format('coalesce((%I)::numeric, 0)', col) end;
  -- (unqualified: the as-of read goes through the routing view)
  v0 := coalesce(_gnomon.eval_metric(format('select %s(%s) from %I where %s', agg, case when agg = 'count' then '*' else quote_ident(col) end,
                                            t.relname, f), 'main', since), 0);
  q := format($q$
    select _gnomon.version_time(ch.vkey, ((ch.vkey & 281474976710655) - (ch.xid::text::int8 & 281474976710655))::int4),
           $1 + sum(coalesce(n.d, 0) - coalesce(o.d, 0)) over (order by ch.vkey, ch.vlsn, ch.key::text rows between unbounded preceding and current row),
           ch.vkey
      from gnomon.changes($2, $3, array[$4], 'both') ch
      left join lateral (select case when (%1$s) then %2$s else 0 end as d from jsonb_populate_record(null::%3$s, ch.new) as %4$I where ch.new is not null) n on true
      left join lateral (select case when (%1$s) then %2$s else 0 end as d from jsonb_populate_record(null::%3$s, ch.old) as %4$I where ch.old is not null) o on true
     order by ch.vkey, ch.vlsn, ch.key::text$q$, f, fx, _gnomon.qrel(t), t.relname);
  return query execute q using v0, since, until, tbl;
end $$;

-- The changes to a row and its neighbours in a window, in feed order, with actor and reason.
create function gnomon.events(tbl regclass, key jsonb, depth int default 1, since text default null, until text default null,
                              max_neighbors int default 50)
returns table(vkey int8, at timestamptz, rel regclass, row_key jsonb, op text, xid xid8, actor text, reason text, new jsonb, old jsonb)
language plpgsql volatile as $$
declare t gnomon.tracked; nodes jsonb; tbls regclass[];
begin
  tbl := _gnomon.base_rel(tbl);
  select * into t from gnomon.tracked x where x.rel = tbl;
  if t.id is null then raise exception '% is not tracked', tbl using hint = '[gnomon:not_tracked]'; end if;
  key := _gnomon.key_arg(t, key);
  select coalesce(jsonb_agg(jsonb_build_object('t', n.rel::text, 'k', n.row_key)), '[]'), array_agg(distinct n.rel)
    into nodes, tbls from gnomon.neighbors(tbl, key, depth, 'both', max_neighbors) n;
  since := coalesce(since, gnomon.coord_text(t.track_coord));
  return query
    select c.vkey, _gnomon.version_time(c.vkey, ((c.vkey & 281474976710655) - (c.xid::text::int8 & 281474976710655))::int4),
           c.tbl, c.key, c.op, c.xid, xa.actor, xa.reason, c.new, c.old
      from gnomon.changes(since, until, tbls, 'both') c
      left join gnomon.xact xa on xa.epoch = (c.vkey >> 48)::int2 and xa.xid = c.xid
     where jsonb_build_object('t', c.tbl::text, 'k', c.key) in (select e.value from jsonb_array_elements(nodes) e)
     order by c.vkey, c.vlsn, c.tbl::text, c.key::text;
end $$;

-------------------------------------------------------------------------------
-- The graph
-------------------------------------------------------------------------------
-- Relationships that are not foreign keys: soft references, polymorphic ones (a filter on a type
-- column, over the "from" row as f), a jsonb path (an expression as a "from" column).
create function gnomon.link(name text, from_tbl regclass, from_cols text[], to_tbl regclass, to_cols text[], filter text default null) returns void
language sql volatile as $$
  insert into gnomon.link values (name, _gnomon.base_rel(from_tbl), from_cols, _gnomon.base_rel(to_tbl), to_cols, filter)
    on conflict on constraint link_pkey do update set from_tbl = excluded.from_tbl, from_cols = excluded.from_cols,
       to_tbl = excluded.to_tbl, to_cols = excluded.to_cols, filter = excluded.filter
$$;
grant insert, update, delete on gnomon.link to public;

-- What a table is read through in this session: its routing view on a branch or in the past (the
-- one the session's path names, so a mask profile applies), else the table.
create function _gnomon.session_rel(rel regclass) returns text language plpgsql stable as $$
declare t gnomon.tracked; r regclass; c _gnomon.ctx := gnomon._ctx();
begin
  select * into t from gnomon.tracked x where x.rel = session_rel.rel;
  if t.id is null or c.main_now then return rel::text; end if;
  r := to_regclass(quote_ident(t.relname));
  if r is not null and r <> rel and _gnomon.base_rel(r) = rel then return r::text; end if;
  return _gnomon.robj_for(t, c.kind);
end $$;

-- An edge's far side for a set of near rows: (near image, far image) pairs. cols on the near
-- side match fcols on the far one; expressions are allowed on the near side (links).
create function _gnomon.edge_rows(far regclass, fcols text[], near_imgs jsonb, ncols text[], filter text default null)
returns table(near jsonb, far_img jsonb) language plpgsql volatile as $$
declare src text := _gnomon.session_rel(far); cond text;
begin
  cond := (select string_agg(format('x.%I::text = (n.value ->> %L)', fcols[i], ncols[i]), ' and ')
             from generate_subscripts(fcols, 1) i);
  return query execute format('select n.value, to_jsonb(x) from jsonb_array_elements($1) n join %s x on %s%s',
                              src, cond, case when filter is null then '' else ' where ' || filter end)
    using near_imgs;
end $$;

create function _gnomon.key_of_img(rel regclass, img jsonb) returns jsonb language plpgsql stable as $$
begin
  return (select jsonb_object_agg(k, img -> k) from unnest(gnomon.primary_key(rel)) k);
end $$;

-- Breadth-first over foreign keys in both directions and over declared links, a level at a time
-- (one query per edge per level), through the session's branch and coordinate. A visited set stops
-- cycles; max_rows caps the result.
create function gnomon.neighbors(tbl regclass, key jsonb, depth int default 1, direction text default 'both', max_rows int default 100,
                                 links bool default true)
returns table(level int, rel regclass, row_key jsonb, via text, from_tbl regclass, from_key jsonb, row_image jsonb)
language plpgsql volatile as $$
declare front jsonb; nxt jsonb; seen text[] := '{}'; img jsonb; lvl int; e record; r record; n int := 0; fr record; k jsonb; t gnomon.tracked;
begin
  if direction not in ('both', 'in', 'out') then raise exception 'direction is both, in or out' using hint = '[gnomon:direction_both_out]'; end if;
  tbl := _gnomon.base_rel(tbl);
  select * into t from gnomon.tracked x where x.rel = tbl;
  if t.id is not null then key := _gnomon.key_arg(t, key); end if;
  execute format('select to_jsonb(x) from %s x where %s', _gnomon.session_rel(tbl),
                 (select string_agg(format('x.%I::text = ($1 ->> %L)', kk, kk), ' and ') from jsonb_object_keys(key) kk)) into img using key;
  if img is null then return; end if;
  level := 0; rel := tbl; row_key := key; via := null; from_tbl := null; from_key := null; row_image := img;
  return next;
  seen := seen || (tbl::text || key::text);
  front := jsonb_build_array(jsonb_build_object('t', tbl::text, 'img', img));
  for lvl in 1..depth loop
    nxt := '[]';
    for fr in select (fe.value ->> 't')::regclass as frel, jsonb_agg(fe.value -> 'img') as imgs from jsonb_array_elements(front) fe group by 1 loop
      for e in
        -- out: this table's foreign keys to their parents
        select c.conname::text as via, c.confrelid::regclass as far,
               (select array_agg(a.attname::text order by u.o) from unnest(c.confkey) with ordinality u(n, o) join pg_attribute a on a.attrelid = c.confrelid and a.attnum = u.n) as fcols,
               (select array_agg(a.attname::text order by u.o) from unnest(c.conkey) with ordinality u(n, o) join pg_attribute a on a.attrelid = c.conrelid and a.attnum = u.n) as ncols,
               null::text as filter
          from pg_constraint c where c.contype = 'f' and c.conrelid = fr.frel and direction in ('both', 'out')
        union all
        -- in: foreign keys of other tables to this one
        select c.conname, c.conrelid::regclass,
               (select array_agg(a.attname::text order by u.o) from unnest(c.conkey) with ordinality u(n, o) join pg_attribute a on a.attrelid = c.conrelid and a.attnum = u.n),
               (select array_agg(a.attname::text order by u.o) from unnest(c.confkey) with ordinality u(n, o) join pg_attribute a on a.attrelid = c.confrelid and a.attnum = u.n),
               null
          from pg_constraint c where c.contype = 'f' and c.confrelid = fr.frel and direction in ('both', 'in')
        union all
        select 'link:' || l.name, l.to_tbl, l.to_cols, l.from_cols, null from gnomon.link l
         where links and l.from_tbl = fr.frel and direction in ('both', 'out') and l.filter is null
        union all
        select 'link:' || l.name, l.from_tbl, l.from_cols, l.to_cols, l.filter from gnomon.link l
         where links and l.to_tbl = fr.frel and direction in ('both', 'in')
      loop
        for r in select * from _gnomon.edge_rows(e.far, e.fcols, fr.imgs, e.ncols, e.filter) loop
          k := _gnomon.key_of_img(e.far, r.far_img);
          continue when (e.far::text || coalesce(k, r.far_img)::text) = any(seen);
          seen := seen || (e.far::text || coalesce(k, r.far_img)::text);
          level := lvl; rel := e.far; row_key := k; via := e.via; from_tbl := fr.frel;
          from_key := _gnomon.key_of_img(fr.frel, r.near); row_image := r.far_img;
          return next;
          n := n + 1;
          if n >= max_rows then return; end if;
          nxt := nxt || jsonb_build_object('t', e.far::text, 'img', r.far_img);
        end loop;
      end loop;
    end loop;
    exit when jsonb_array_length(nxt) = 0;
    front := nxt;
  end loop;
end $$;

-- A table's name with its schema, whatever the search_path.
create function _gnomon.qname(r regclass) returns text language sql stable as $$
  select format('%I.%I', n.nspname, c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.oid = r
$$;

-- A branch's diff as a graph: the changed rows as nodes (kind and changed columns), the edges
-- among them, and one hop of context around them, read on the branch.
create function gnomon.impact(branch text, max_context int default 200) returns jsonb language plpgsql volatile as $$
declare nodes jsonb; edges jsonb := '[]'; ctx jsonb := '[]'; nd record; nb record; ids text[]; n int := 0;
        ob text := current_setting('gnomon.branch', true); oa text := current_setting('gnomon.as_of', true); sp text := current_setting('search_path');
begin
  select coalesce(jsonb_agg(jsonb_build_object('table', _gnomon.qname(x.tbl), 'oid', x.tbl::oid, 'key', x.key, 'kind', x.kind, 'columns', x.cols)), '[]'),
         array_agg(x.tbl::oid::text || x.key::text)
    into nodes, ids
    from (select d.tbl, d.key, min(d.kind) as kind, array_remove(array_agg(d.col), null) as cols
            from gnomon.diff(branch) d group by d.tbl, d.key) x;
  perform gnomon.use(branch, null, true);
  for nd in select (e.value ->> 'oid')::oid::regclass as rel, e.value -> 'key' as key, e.value ->> 'kind' as kind from jsonb_array_elements(nodes) e loop
    continue when nd.kind = 'delete';
    for nb in select * from gnomon.neighbors(nd.rel, nd.key, 1, 'both', 50) x where x.level = 1 loop
      if (nb.rel::oid::text || nb.row_key::text) = any(ids) then
        -- (each edge once, though both ends find it)
        continue when edges @> jsonb_build_array(jsonb_build_object('from', jsonb_build_object('table', _gnomon.qname(nb.rel), 'key', nb.row_key),
                                                                    'to', jsonb_build_object('table', _gnomon.qname(nd.rel), 'key', nd.key), 'via', nb.via));
        edges := edges || jsonb_build_object('from', jsonb_build_object('table', _gnomon.qname(nd.rel), 'key', nd.key),
                                             'to', jsonb_build_object('table', _gnomon.qname(nb.rel), 'key', nb.row_key), 'via', nb.via);
      elsif n < max_context then
        ctx := ctx || jsonb_build_object('table', _gnomon.qname(nb.rel), 'key', nb.row_key, 'via', nb.via,
                                         'of', jsonb_build_object('table', _gnomon.qname(nd.rel), 'key', nd.key));
        n := n + 1;
      end if;
    end loop;
  end loop;
  perform set_config('gnomon.branch', coalesce(ob, ''), true); perform set_config('gnomon.as_of', coalesce(oa, ''), true);
  perform set_config('search_path', sp, true);
  return jsonb_build_object('version', 1, 'branch', branch, 'nodes', nodes, 'edges', edges, 'context', ctx);
end $$;

-------------------------------------------------------------------------------
-- Metrics: catalogs and statistics only, never a tracked table
-------------------------------------------------------------------------------
create function gnomon.metrics(per_branch bool default false, max_branches int default 50)
returns table(name text, labels jsonb, value float8, type text, help text)
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; r record;
begin
  return query select 'gnomon_tick_lag_seconds', '{}'::jsonb, coalesce(extract(epoch from now() - max(x.at)), -1)::float8, 'gauge',
                      'Seconds since the last tick (as-of by timestamp resolves to it).' from gnomon.tick x;
  for t in select * from gnomon.tracked order by id loop
    return query
      select 'gnomon_version_bytes', jsonb_build_object('table', _gnomon.qname(t.rel)),
             coalesce(sum(pg_total_relation_size(p.relid)), 0)::float8, 'gauge', 'Bytes of version storage.'
        from pg_partition_tree(_gnomon.obj(t, 'v')::regclass) p where p.isleaf
      union all
      select 'gnomon_partitions', jsonb_build_object('table', _gnomon.qname(t.rel)), (count(*) filter (where p.isleaf))::float8, 'gauge', 'Version partitions.'
        from pg_partition_tree(_gnomon.obj(t, 'v')::regclass) p
      union all
      select 'gnomon_default_partition_rows', jsonb_build_object('table', _gnomon.qname(t.rel)),
             coalesce((select s.n_live_tup from pg_stat_all_tables s where s.relid = to_regclass(_gnomon.obj(t, 'v_d'))), 0)::float8,
             'gauge', 'Versions in the default partition (should be zero; the heartbeat creates partitions).'
      union all
      select 'gnomon_branch_head_rows', jsonb_build_object('table', _gnomon.qname(t.rel)),
             coalesce((select sum(s.n_live_tup) from pg_stat_all_tables s where s.relid in (to_regclass(_gnomon.obj(t, 'b')), to_regclass(_gnomon.obj(t, 'b_u')))), 0)::float8,
             'gauge', 'Branch head rows of the table.';
  end loop;
  return query select 'gnomon_blob_bytes', '{}'::jsonb, pg_total_relation_size('_gnomon.blob')::float8, 'gauge', 'Bytes in the blob store.';
  return query select 'gnomon_branches', jsonb_build_object('kind', b.kind, 'status', b.status), count(*)::float8, 'gauge', 'Branches by kind and status.'
                 from gnomon.branch b where b.id <> 0 group by b.kind, b.status;
  return query select 'gnomon_oldest_open_branch_seconds', '{}'::jsonb, coalesce(extract(epoch from now() - min(b.created_at)), 0)::float8, 'gauge',
                      'Age of the oldest open branch.' from gnomon.branch b where b.id <> 0 and b.status = 'open';
  return query select 'gnomon_branches_over_quota', '{}'::jsonb, count(*)::float8, 'gauge', 'Branches over quota (writes refused).'
                 from gnomon.branch b where b.over_quota is not null;
  return query select 'gnomon_merges', jsonb_build_object('status', m.status), count(*)::float8, 'counter', 'Merges by status.'
                 from gnomon.merge m group by m.status;
  return query select 'gnomon_merge_duration_seconds_bucket', jsonb_build_object('le', le), count(*) filter (where d <= le_n)::float8, 'histogram', 'Merge durations.'
                 from (select extract(epoch from m.finished_at - m.created_at) as d from gnomon.merge m where m.finished_at is not null) x,
                      unnest(array['0.1', '1', '10', '60', '+Inf'], array[0.1, 1, 10, 60, 'infinity'::float8]) as b(le, le_n)
                group by le, le_n;
  return query select 'gnomon_merged_rows', '{}'::jsonb,
                      coalesce(sum(coalesce((m.stats ->> 'inserted')::int8, 0) + coalesce((m.stats ->> 'updated')::int8, 0) + coalesce((m.stats ->> 'deleted')::int8, 0)), 0)::float8,
                      'counter', 'Rows written by merges.' from gnomon.merge m where m.status = 'applied';
  return query select 'gnomon_open_conflicts', '{}'::jsonb, count(*)::float8, 'gauge', 'Unresolved merge conflicts.'
                 from gnomon.conflict c join gnomon.merge m on m.id = c.merge_id where c.resolution is null and m.status = 'conflicts';
  return query select 'gnomon_consumer_lag_seconds', jsonb_build_object('consumer', c.name),
                      coalesce(extract(epoch from now() - (select x.at from gnomon.tick x where x.kx >= gnomon._kxmax(c.pos) order by x.kx, x.id limit 1)), 0)::float8,
                      'gauge', 'How far behind a feed consumer is.' from gnomon.consumer c;
  return query select 'gnomon_sink_dead_batches', jsonb_build_object('sink', d.sink), count(*)::float8, 'gauge', 'Batches a sink gave up on.'
                 from gnomon.sink_dead d group by d.sink;
  return query select 'gnomon_ledger_blocks', '{}'::jsonb, count(*)::float8, 'counter', 'Sealed ledger blocks.' from gnomon.ledger_block;
  return query select 'gnomon_ledger_last_seal_seconds', '{}'::jsonb, coalesce(extract(epoch from now() - max(l.at)), -1)::float8, 'gauge',
                      'Seconds since the ledger was last sealed.' from gnomon.ledger_block l;
  return query select 'gnomon_ledger_verification_ok', '{}'::jsonb,
                      coalesce((select (v.failed = 0)::int from gnomon.ledger_verification v order by v.id desc limit 1), -1)::float8, 'gauge',
                      'Whether the last ledger verification passed (1) or failed (0); -1 if it never ran.';
  return query select 'gnomon_ledger_last_verification_seconds', '{}'::jsonb,
                      coalesce(extract(epoch from now() - (select max(v.at) from gnomon.ledger_verification v)), -1)::float8, 'gauge',
                      'Seconds since the ledger was last verified.';
  return query select 'gnomon_archived_partitions', jsonb_build_object('restored', a.restored), count(*)::float8, 'gauge', 'Archived partitions.'
                 from gnomon.archive a group by a.restored;
  return query select 'gnomon_archives_in_place', jsonb_build_object('engine', a.engine), count(*)::float8, 'gauge',
                      'Archived partitions read in place through a foreign partition.'
                 from gnomon.archive a where a.foreign_rel is not null group by a.engine;
  -- the C module's counters, summed over every session in shared memory
  if to_regprocedure('_gnomon.c_counters()') is not null then
    return query execute $q$
      select case when c.name like 'point\_%' then 'gnomon_c_point_reads_total' when c.name like 'filter\_%' then 'gnomon_c_touched_filter_total'
                  else 'gnomon_c_' || c.name || '_total' end,
             case when c.name like 'point\_%' then jsonb_build_object('answer', substr(c.name, 7))
                  when c.name like 'filter\_%' then jsonb_build_object('result', substr(c.name, 8)) else '{}'::jsonb end,
             c.value::float8, 'counter',
             case when c.name like 'point\_%' then 'C module point reads, by how they were answered.'
                  when c.name like 'filter\_%' then 'C module touched-key filter: scans it saved (skips) and could not (scans).'
                  when c.name = 'ddl_redirects' then 'C module: DDL of branch sessions sent to gnomon.ddl.'
                  when c.name = 'search_view_queries' then 'C module: queries given the search views.'
                  else 'C module: INSERT ... ON CONFLICT statements rewritten for a branch.' end
        from _gnomon.c_counters() c$q$;
  end if;
  return query select 'gnomon_thaw_requests', jsonb_build_object('status', x.status), count(*)::float8, 'gauge', 'Thaw requests by status.'
                 from gnomon.thaw_request x group by x.status;
  return query select 'gnomon_agent_calls', jsonb_build_object('agent', coalesce(c.agent, ''), 'tool', c.tool), count(*)::float8, 'counter', 'Recorded agent tool calls.'
                 from gnomon.agent_call c group by c.agent, c.tool;
  return query select 'gnomon_agent_refusals', jsonb_build_object('agent', coalesce(c.agent, ''), 'reason', coalesce((regexp_match(c.error, '\[gnomon:([a-z_]+)\]'))[1], 'other')),
                      count(*)::float8, 'counter', 'Agent calls refused, by reason.'
                 from gnomon.agent_call c where c.error is not null group by 1, 2;
  if per_branch then
    for r in select b.id, b.name from gnomon.branch b where b.id <> 0 and b.status = 'open' order by b.last_used desc limit max_branches loop
      return query select 'gnomon_branch_behind_main', jsonb_build_object('branch', r.name), coalesce(x.behind, 0)::float8, 'gauge',
                          'Changes main made since the branch''s base.' from gnomon.branches x where x.id = r.id;
    end loop;
  end if;
end $$;
revoke all on function gnomon.metrics(bool, int) from public;
grant execute on function gnomon.metrics(bool, int) to gnomon_admin, pg_monitor;

-- The Prometheus text format, for exporters that read one value.
create function gnomon.metrics_text(per_branch bool default false) returns text language sql stable
security definer set search_path = pg_catalog, pg_temp as $$
  with m as (select * from gnomon.metrics(per_branch)),
       h as (select distinct on (regexp_replace(name, '_bucket$', '')) regexp_replace(name, '_bucket$', '') as base, type, help from m order by 1)
  select string_agg(line, E'\n' order by o1, o2) || E'\n' from (
    select h.base as o1, 0 as o2, format('# HELP %s %s', h.base, h.help) as line from h
    union all select h.base, 1, format('# TYPE %s %s', h.base, h.type) from h
    union all select regexp_replace(m.name, '_bucket$', ''), 2,
                     m.name || case when m.labels = '{}' then '' else '{' || (select string_agg(format('%s="%s"', k, replace(replace(v, '\', '\\'), '"', '\"')), ',' order by k)
                                                                                from jsonb_each_text(m.labels) as l(k, v)) || '}' end
                     || ' ' || m.value from m) x
$$;
revoke all on function gnomon.metrics_text(bool) from public;
grant execute on function gnomon.metrics_text(bool) to gnomon_admin, pg_monitor;

-------------------------------------------------------------------------------
-- History checkpoints: a full image of a table at a coordinate
-------------------------------------------------------------------------------
insert into gnomon.setting_default values
  ('checkpoints', 'off', 'on: reads in the past use the nearest history checkpoint of a table, rebuilding only the rows changed between it and the read''s cutoff.');

-- Off the write path: an INSERT ... SELECT through an as-of read, into a partition of its own.
create function _gnomon.make_checkpoint(tid int, c gnomon.coord) returns int
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked := _gnomon.trow(tid); id int; n bigint; part text; cols text;
        ob text := current_setting('gnomon.branch', true); oa text := current_setting('gnomon.as_of', true);
begin
  if t.mode <> 'known' then raise exception 'history checkpoints are for known-time tables' using errcode = '0A000', hint = '[gnomon:history_checkpoints_known_time]'; end if;
  perform pg_advisory_xact_lock(1735290222, -tid);
  id := coalesce((select max(h.id) from gnomon.history_checkpoint h where h.tbl = tid), 0) + 1;
  part := _gnomon.obj(t, 'ck_' || id);
  execute format('create table %s partition of %s for values in (%s)', part, _gnomon.obj(t, 'ck'), id);
  cols := _gnomon.lst(_gnomon.cols(t.rel));
  -- the routing view as of c, read with its owner's (gnomon_reader's) policies
  perform set_config('gnomon.branch', '', true);
  perform set_config('gnomon.as_of', gnomon.coord_text(c), true);
  execute format('insert into %s (gn_ck, %s) select %s, %s from %s', part, cols, id, cols, _gnomon.robj(t));
  get diagnostics n = row_count;
  perform set_config('gnomon.branch', coalesce(ob, ''), true);
  perform set_config('gnomon.as_of', coalesce(oa, ''), true);
  execute format('analyze %s', part);
  insert into gnomon.history_checkpoint(tbl, id, coord, kx, rows, bytes)
  values (tid, id, c, gnomon._kxmax(c), n, pg_total_relation_size(part::regclass));
  perform gnomon._bump();
  return id;
exception when others then
  perform set_config('gnomon.branch', coalesce(ob, ''), true);
  perform set_config('gnomon.as_of', coalesce(oa, ''), true);
  raise;
end $$;
revoke all on function _gnomon.make_checkpoint(int, gnomon.coord) from public;

create function gnomon.history_checkpoint(tbl regclass, at text default 'now') returns int
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; c gnomon.coord;
begin
  tbl := _gnomon.base_rel(tbl);
  select * into t from gnomon.tracked where rel = tbl;
  if t.id is null then raise exception '% is not tracked', tbl using hint = '[gnomon:not_tracked]'; end if;
  perform _gnomon.require_manage(tbl);
  c := gnomon.resolve_coord(coalesce(at, 'now'));
  if not gnomon._vis(t.track_key, t.track_xoff, c) then raise exception 'there is no history of % at %', tbl, at using hint = '[gnomon:there_no_history]'; end if;
  return _gnomon.make_checkpoint(t.id, c);
end $$;

create function gnomon.drop_history_checkpoint(tbl regclass, id int) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked;
begin
  tbl := _gnomon.base_rel(tbl);
  select * into t from gnomon.tracked where rel = tbl;
  if t.id is null then raise exception '% is not tracked', tbl using hint = '[gnomon:not_tracked]'; end if;
  if current_setting('gnomon._sweeping', true) is distinct from '1' then perform _gnomon.require_manage(tbl); end if;
  execute format('drop table if exists %s', _gnomon.obj(t, 'ck_' || id));
  delete from gnomon.history_checkpoint h where h.tbl = t.id and h.id = drop_history_checkpoint.id;
  perform gnomon._bump();
end $$;

-- A checkpoint every `every`, keeping the last `keep` (and those nearest a tag).
create function gnomon.set_checkpoint_policy(tbl regclass, every interval default null, keep int default 3) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  tbl := _gnomon.base_rel(tbl);
  perform _gnomon.require_manage(tbl);
  update gnomon.tracked set checkpoint_policy = case when every is null then null else jsonb_build_object('every', every::text, 'keep', keep) end
   where rel = tbl;
  if not found then raise exception '% is not tracked', tbl using hint = '[gnomon:not_tracked]'; end if;
end $$;

create function gnomon.run_checkpoint_policies() returns int
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; made int := 0; last timestamptz; h record; pinned int[];
begin
  for t in select * from gnomon.tracked where checkpoint_policy is not null and mode = 'known' loop
    select max(x.created_at) into last from gnomon.history_checkpoint x where x.tbl = t.id;
    if last is null or last < now() - (t.checkpoint_policy ->> 'every')::interval then
      perform _gnomon.make_checkpoint(t.id, gnomon.coordinate());
      made := made + 1;
    end if;
    -- retention: the newest `keep`, plus the checkpoint nearest each tag
    pinned := array(select (select x.id from gnomon.history_checkpoint x where x.tbl = t.id
                             order by abs(x.kx - gnomon._kxmax(g.coord)) limit 1) from gnomon.tag g);
    for h in select x.id from gnomon.history_checkpoint x where x.tbl = t.id
              order by x.id desc offset coalesce((t.checkpoint_policy ->> 'keep')::int, 3) loop
      continue when h.id = any(pinned);
      perform set_config('gnomon._sweeping', '1', true);
      perform gnomon.drop_history_checkpoint(t.rel, h.id);
      perform set_config('gnomon._sweeping', '', true);
    end loop;
  end loop;
  return made;
end $$;
revoke all on function gnomon.run_checkpoint_policies() from public;
grant execute on function gnomon.run_checkpoint_policies() to gnomon_admin;

-------------------------------------------------------------------------------
-- Change feed sinks: delivered by the job loop (gnomon daemon)
-------------------------------------------------------------------------------
-- A sink is a feed consumer ("sink:<name>") and a destination. Delivery is
-- BEGIN; feed_poll; deliver; COMMIT: a failed delivery rolls the position back and the batch is
-- sent again (at least once). Every change carries its id (table, key, version key, LSN), a total
-- order, for consumers to deduplicate by.
create function gnomon.sink_add(name text, kind text, config jsonb, tables text[] default null, format text default 'gnomon', since text default 'now')
returns void language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform _gnomon.require_admin('adding a sink');
  if kind = 'kafka' and coalesce(config ->> 'brokers', '') = '' then
    raise exception 'a kafka sink needs config.brokers (host:port, comma separated) and config.topic' using errcode = '22023', hint = '[gnomon:sink_config]';
  end if;
  if kind = 'parquet' and coalesce(config ->> 'to', '') = '' then
    raise exception 'a parquet sink needs config.to: a directory, file://, s3:// or gs://' using errcode = '22023', hint = '[gnomon:sink_config]';
  end if;
  insert into gnomon.sink(name, kind, config, consumer, tables, format, created_by)
  values (name, kind, config, 'sink:' || name, tables, format, _gnomon.who());
  insert into gnomon.consumer(name, pos, created_by) values ('sink:' || name, gnomon.resolve_coord(since), 'gnomon_admin')
    on conflict on constraint consumer_pkey do update set pos = excluded.pos, pending_to = null, pending_off = 0,
      after_key = null, after_lsn = null, after_tbl = null, after_rk = null, updated_at = now();
end $$;

create function gnomon.sink_status(name text, status text) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform _gnomon.require_admin('changing a sink');
  if status not in ('active', 'paused') then raise exception 'status is active or paused' using hint = '[gnomon:status_active_paused]'; end if;
  update gnomon.sink s set status = sink_status.status, failures = case when sink_status.status = 'active' then 0 else s.failures end, updated_at = now()
   where s.name = sink_status.name;
  if not found then raise exception 'no sink "%"', name using errcode = '42704', hint = '[gnomon:no_sink]'; end if;
end $$;

-- Deliver again from a moment (consumers deduplicate by id).
create function gnomon.sink_replay(name text, since text) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform _gnomon.require_admin('replaying a sink');
  update gnomon.consumer c set pos = gnomon.resolve_coord(since), pending_to = null, pending_off = 0,
         after_key = null, after_lsn = null, after_tbl = null, after_rk = null, updated_at = now()
   where c.name = 'sink:' || sink_replay.name;
  if not found then raise exception 'no sink "%"', name using errcode = '42704', hint = '[gnomon:no_sink]'; end if;
end $$;

create function gnomon.sink_drop(name text) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform _gnomon.require_admin('dropping a sink');
  delete from gnomon.sink s where s.name = sink_drop.name;
  delete from gnomon.consumer c where c.name = 'sink:' || sink_drop.name;
end $$;

-- One batch for a sink, with each change's time (commit time where known) and id.
create function gnomon.sink_batch(name text, lim int default 500)
returns table(id text, vkey int8, vlsn pg_lsn, tbl text, key jsonb, op text, xid xid8, role name, new jsonb, old jsonb, ts timestamptz)
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare s gnomon.sink;
begin
  perform _gnomon.require_admin('delivering a sink');
  select * into s from gnomon.sink x where x.name = sink_batch.name;
  if s.name is null then raise exception 'no sink "%"', name using errcode = '42704', hint = '[gnomon:no_sink]'; end if;
  return query
    select p.tbl::text || ':' || p.key::text || ':' || p.vkey || ':' || p.vlsn, p.vkey, p.vlsn, _gnomon.qname(p.tbl), p.key, p.op, p.xid, p.role, p.new, p.old,
           _gnomon.version_time(p.vkey, ((p.vkey & 281474976710655) - (p.xid::text::int8 & 281474976710655))::int4)
      from gnomon.feed_poll(s.consumer, lim) p
     where s.tables is null or _gnomon.qname(p.tbl) = any(s.tables) or p.tbl::text = any(s.tables);
end $$;
revoke all on function gnomon.sink_batch(text, int) from public;
grant execute on function gnomon.sink_batch(text, int) to gnomon_admin;

-- The job loop's bookkeeping, for a gnomon_admin member that does not own the catalog.
create function gnomon.sink_report(name text, delivered int, error text default null, dead jsonb default null, pause bool default false) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform _gnomon.require_admin('reporting a sink');
  if error is null then
    update gnomon.sink s set delivered = s.delivered + sink_report.delivered, failures = 0, last_error = null, updated_at = now() where s.name = sink_report.name;
  else
    update gnomon.sink s set failures = s.failures + 1, last_error = sink_report.error, updated_at = now(),
           status = case when pause then 'paused' else s.status end
     where s.name = sink_report.name;
  end if;
  if dead is not null then insert into gnomon.sink_dead(sink, batch, error) values (name, dead, error); end if;
end $$;

-- A sink's own delivery state, saved in the delivery's transaction (Kafka: the idempotent
-- producer's id, epoch and next sequence per partition, so a batch sent again after a lost
-- acknowledgement carries the same sequences and the broker drops the duplicate).
create function gnomon.sink_state(name text, state jsonb) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform _gnomon.require_admin('reporting a sink');
  update gnomon.sink s set state = sink_state.state where s.name = sink_state.name;
end $$;

create function gnomon.notification_report(id bigint, error text default null) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform _gnomon.require_admin('reporting a notification');
  update gnomon.notification n set attempts = n.attempts + 1, last_error = error,
         sent_at = case when error is null then now() end where n.id = notification_report.id;
end $$;

-- Saved graph views. Saving one needs SELECT on its table (the key is a value of
-- it); the list shows the views on tables the caller may read; a view is changed or dropped by
-- whoever saved it, or gnomon_admin.
create function gnomon.save_graph_view(name text, tbl regclass, key jsonb, depth int default 1, branch text default null,
                                       at text default null, note text default null) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare who name := _gnomon.who(); old gnomon.graph_view;
begin
  if not has_table_privilege(who, tbl, 'select') then
    raise exception 'role % may not read %', who, tbl using errcode = '42501', hint = '[gnomon:graph_view_table]';
  end if;
  select * into old from gnomon.graph_view g where g.name = save_graph_view.name;
  if old.name is not null and old.created_by <> who and not pg_has_role(who, 'gnomon_admin', 'member') then
    raise exception 'graph view "%" belongs to %', old.name, old.created_by using errcode = '42501', hint = '[gnomon:graph_view_owner]';
  end if;
  insert into gnomon.graph_view as g (name, tbl, key, depth, branch, at, note, created_by)
  values (save_graph_view.name, _gnomon.qname(tbl), save_graph_view.key, save_graph_view.depth, nullif(save_graph_view.branch, ''),
          nullif(save_graph_view.at, ''), save_graph_view.note, who)
  on conflict on constraint graph_view_pkey do update
    set tbl = excluded.tbl, key = excluded.key, depth = excluded.depth, branch = excluded.branch, at = excluded.at, note = excluded.note;
end $$;

create function gnomon.graph_views() returns setof gnomon.graph_view
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select g.* from gnomon.graph_view g
   where to_regclass(g.tbl) is not null and has_table_privilege(_gnomon.who(), to_regclass(g.tbl), 'select')
   order by g.name
$$;

create function gnomon.drop_graph_view(name text) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare who name := _gnomon.who(); old gnomon.graph_view;
begin
  select * into old from gnomon.graph_view g where g.name = drop_graph_view.name;
  if old.name is null then
    raise exception 'no graph view "%"', drop_graph_view.name using errcode = '42704', hint = '[gnomon:graph_view_missing]';
  end if;
  if old.created_by <> who and not pg_has_role(who, 'gnomon_admin', 'member') then
    raise exception 'graph view "%" belongs to %', old.name, old.created_by using errcode = '42501', hint = '[gnomon:graph_view_owner]';
  end if;
  delete from gnomon.graph_view g where g.name = drop_graph_view.name;
end $$;
