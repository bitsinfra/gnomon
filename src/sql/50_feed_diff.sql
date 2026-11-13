-- Exact change feed, diff and the generic row readers used by merge and undo.

-- Key of a row image as jsonb, in key-column order.
create function _gnomon.keyj(t gnomon.tracked, r jsonb) returns jsonb language sql immutable as $$
  select jsonb_object_agg(k, r -> k) from unnest(t.key_cols) k
$$;

create function _gnomon.key_sql(t gnomon.tracked, alias text) returns text language sql immutable as $$
  select 'jsonb_build_object(' || string_agg(format('%L, %s.%I', k, alias, k), ', ') || ')' from unnest(t.key_cols) k
$$;

-- Typed record definition for jsonb_to_recordset over key objects.
create function _gnomon.key_recdef(t gnomon.tracked) returns text language sql stable as $$
  select string_agg(format('%I %s', a.attname, format_type(a.atttypid, a.atttypmod)), ', ' order by u.o)
    from unnest(t.key_cols) with ordinality u(k, o)
    join pg_attribute a on a.attrelid = t.rel and a.attname = u.k
$$;

-------------------------------------------------------------------------------
-- References: main | <branch> | <branch>@<coord-ref> | <coord-ref> (main as of)
-------------------------------------------------------------------------------
create type gnomon.ref as (branch text, as_of text);

create function gnomon.parse_ref(r text) returns gnomon.ref language plpgsql stable as $$
declare b text; a text;
begin
  r := btrim(r);
  if r is null or r = '' or r = 'main' then return row('main', null)::gnomon.ref; end if;
  if r ~ '^e\d+:' or r like 'tag:%' then return row('main', r)::gnomon.ref; end if;
  if position('@' in r) > 0 then
    b := split_part(r, '@', 1); a := substr(r, length(b) + 2);
    return row(coalesce(nullif(b, ''), 'main'), a)::gnomon.ref;
  end if;
  if exists (select 1 from gnomon.branch where name = r) then return row(r, null)::gnomon.ref; end if;
  begin
    perform r::timestamptz;
    return row('main', r)::gnomon.ref;
  exception when others then
    raise exception 'unknown branch or coordinate "%"', r using hint = '[gnomon:unknown_branch_coordinate]';
  end;
end $$;

-- Read rows of a table at a reference for a set of keys (null = every row) as (key, row jsonb).
-- Switches the session context for the duration of the call and restores it.
create function _gnomon.read_rows(tid int, ref gnomon.ref, keys jsonb default null)
returns table(k jsonb, r jsonb) language plpgsql volatile as $$
declare t gnomon.tracked := _gnomon.trow(tid);
        ob text := current_setting('gnomon.branch', true); oa text := current_setting('gnomon.as_of', true);
        q text; karr text; rv text;
begin
  rv := _gnomon.robj_for(t, (gnomon._branch_row(ref.branch)).kind);
  perform set_config('gnomon.branch', case when ref.branch = 'main' then '' else coalesce(ref.branch, '') end, true);
  perform set_config('gnomon.as_of', coalesce(ref.as_of, ''), true);
  if keys is null then
    q := format('select %s, to_jsonb(gn_row) from %s gn_row', _gnomon.key_sql(t, 'gn_row'), rv);
    return query execute q;
  elsif cardinality(t.key_cols) = 1 then
    -- key = ANY(array) is a restriction the planner pushes into every arm of the routing view
    -- (a join would re-run the history arm once per key)
    execute format('select coalesce(array_agg((x ->> %L)::%s), ''{}'') from jsonb_array_elements($1) x',
                   t.key_cols[1], (select format_type(a.atttypid, a.atttypmod) from pg_attribute a where a.attrelid = t.rel and a.attname = t.key_cols[1]))
      into karr using keys;
    q := format('select %s, to_jsonb(gn_row) from %s gn_row where gn_row.%I = any($1::%s[])',
                _gnomon.key_sql(t, 'gn_row'), rv, t.key_cols[1],
                (select format_type(a.atttypid, a.atttypmod) from pg_attribute a where a.attrelid = t.rel and a.attname = t.key_cols[1]));
    return query execute q using karr;
  else
    q := format('select %s, to_jsonb(gn_row) from jsonb_to_recordset($1) as gn_kk(%s) join %s gn_row on %s',
                _gnomon.key_sql(t, 'gn_row'), _gnomon.key_recdef(t), rv,
                (select string_agg(format('gn_row.%1$I = gn_kk.%1$I', x), ' and ') from unnest(t.key_cols) x));
    return query execute q using keys;
  end if;
  perform set_config('gnomon.branch', coalesce(ob, ''), true);
  perform set_config('gnomon.as_of', coalesce(oa, ''), true);
exception when others then
  perform set_config('gnomon.branch', coalesce(ob, ''), true);
  perform set_config('gnomon.as_of', coalesce(oa, ''), true);
  raise;
end $$;

-- The coordinate a reference reads main at (its main cutoff), and the branch levels it reads.
create function _gnomon.ref_ctx(ref gnomon.ref) returns _gnomon.ctx language sql stable as $$
  select gnomon._ctx_compute(case when ref.branch = 'main' then '' else ref.branch end, ref.as_of, null)
$$;

-- A lower bound for the keys of versions committed after now's snapshot. On a standby there is no
-- "now" coordinate (its snapshots do not report their xip), but their xmin is exact, which is all
-- a lower bound needs.
create function _gnomon.kxmin_now() returns int8 language sql stable as $$
  select case when pg_is_in_recovery()
              then (gnomon._epoch_ro()::int8 << 48) | gnomon._xid(pg_snapshot_xmin(pg_current_snapshot()))
              else gnomon._kxmin(gnomon.coordinate()) end
$$;

-- Candidate keys that can differ between two references (cost scales with changes).
create function _gnomon.candidate_keys(tid int, a gnomon.ref, b gnomon.ref) returns jsonb
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked := _gnomon.trow(tid); ca _gnomon.ctx := _gnomon.ref_ctx(a); cb _gnomon.ctx := _gnomon.ref_ctx(b);
        lo int8; brs int[]; res jsonb; vkey text;
begin
  perform _gnomon.require_read(t.rel);
  -- main changes since the earlier main point involved
  lo := least(coalesce(ca.main_xmin, _gnomon.kxmin_now()), coalesce(cb.main_xmin, _gnomon.kxmin_now()));
  if ca.main_now and cb.main_now then lo := null; end if;
  -- every lineage branch level of either side
  brs := array(select distinct x from unnest(ca.lb || cb.lb) x);
  vkey := case when t.wide_key then format('(select %s from %s i where i.gn_rid = v.gn_rid)', _gnomon.key_sql(t, 'i'), _gnomon.obj(t, 'id'))
               else _gnomon.key_sql(t, 'v') end;
  execute format($q$select coalesce(jsonb_agg(distinct k), '[]') from (
      select %1$s as k from %2$s v where $1 is not null and v.gn_key >= $1
      union all select %3$s from %4$s k where k.gn_branch = any($2)%5$s) s$q$,
    vkey, _gnomon.obj(t, 'v'), _gnomon.key_sql(t, 'k'), _gnomon.obj(t, 'bk'),
    -- scratch branches are unlogged: a standby has none (and cannot open the table)
    case when pg_is_in_recovery() then '' else
      format(' union all select %s from %s k where k.gn_branch = any($2)', _gnomon.key_sql(t, 'k'), _gnomon.obj(t, 'bk_u')) end)
    into res using lo, brs;
  -- a TRUNCATE on main between the two: every row its checkpoint holds is a candidate
  if exists (select 1 from _gnomon.cleared c where c.tbl = tid and c.branch = 0
                and gnomon._vis(c.key, c.xoff, ca.main_cut) is distinct from gnomon._vis(c.key, c.xoff, cb.main_cut)) then
    execute format('select coalesce(jsonb_agg(distinct x.k), ''[]'') from (select jsonb_array_elements($1) k union select %s from %s k
                     where k.gn_ck in (select h.id from gnomon.history_checkpoint h where h.tbl = $2 and h.cleared_key is not null)) x',
                   _gnomon.key_sql(t, 'k'), _gnomon.obj(t, 'ck'))
      into res using res, tid;
  end if;
  -- a branch TRUNCATE makes every ancestor key a candidate
  if exists (select 1 from _gnomon.cleared c where c.tbl = tid and c.branch = any(brs)) then
    select coalesce(jsonb_agg(distinct x.k), '[]') into res
      from (select jsonb_array_elements(res) k union select r.k from _gnomon.read_rows(tid, row('main', null)::gnomon.ref) r) x;
  end if;
  return res;
end $$;

-------------------------------------------------------------------------------
-- Diff: one row per changed field.
-------------------------------------------------------------------------------
create function gnomon.diff(a text, b text default null, tables regclass[] default null, keys jsonb default null)
returns table(tbl regclass, key jsonb, kind text, col text, old jsonb, new jsonb)
language plpgsql volatile as $$
declare ra gnomon.ref; rb gnomon.ref; t gnomon.tracked; cand jsonb; br gnomon.branch; bb gnomon.branch_base; side jsonb;
begin

  tables := _gnomon.base_rels(tables);  if b is null then
    -- a branch against its base: its parent at its current cutoff
    br := gnomon._branch_row(a);
    if br.id = 0 then raise exception 'diff(main) needs a second reference' using hint = '[gnomon:diff_needs_second_reference]'; end if;
    bb := gnomon._base_at(br.id, null);
    rb := row(a, null)::gnomon.ref;
    ra := row((select name from gnomon.branch where id = bb.lin_b[1]), gnomon.coord_text(bb.lin_c[1]))::gnomon.ref;
  else
    ra := gnomon.parse_ref(a); rb := gnomon.parse_ref(b);
  end if;
  for t in select * from gnomon.tracked where tables is null or rel = any(tables) order by id loop
    -- what the branch set in columns its version added (gnomon.ddl) lives beside its rows: it joins
    -- the branch's side, so it shows as a change from nothing (main has no such column yet)
    side := case when br.schema_version is not null
                 then _gnomon.branch_side_values(br.id, format('%I.%I', t.nsp, t.relname)) else '{}' end;
    cand := coalesce(keys, _gnomon.candidate_keys(t.id, ra, rb));
    if keys is null and side <> '{}' then
      cand := (select coalesce(jsonb_agg(distinct z.k), '[]')
                 from (select jsonb_array_elements(cand) k union select s.k::jsonb from jsonb_object_keys(side) s(k)) z);
    end if;
    if jsonb_array_length(cand) = 0 then continue; end if;
    return query
      with x as (select r.k, r.r from _gnomon.read_rows(t.id, ra, cand) r),
           y as (select r.k, r.r || coalesce(side -> (r.k::text), '{}') as r from _gnomon.read_rows(t.id, rb, cand) r),
           j as (select coalesce(x.k, y.k) as k, x.r as xr, y.r as yr from x full join y on x.k = y.k)
      select t.rel, j.k, 'insert'::text, null::text, null::jsonb, j.yr from j where j.xr is null
      union all
      select t.rel, j.k, 'delete', null, j.xr, null from j where j.yr is null
      union all
      select t.rel, j.k, 'update', e.key, j.xr -> e.key, e.value
        from j cross join lateral jsonb_each(j.yr) e
       where j.xr is not null and j.yr is not null and (j.xr -> e.key) is distinct from e.value
      order by 2, 3, 4;
  end loop;
end $$;

create function gnomon.diff_summary(a text, b text default null)
returns table(tbl regclass, inserts bigint, updates bigint, deletes bigint) language sql volatile as $$
  select d.tbl, count(distinct d.key) filter (where d.kind = 'insert'), count(distinct d.key) filter (where d.kind = 'update'),
         count(distinct d.key) filter (where d.kind = 'delete')
    from gnomon.diff(a, b) d group by d.tbl order by d.tbl::text
$$;

-------------------------------------------------------------------------------
-- Exact change feed
-------------------------------------------------------------------------------
insert into gnomon.setting_default values
  ('feed_setbased_min', '20000', 'A table''s feed window with at least this many versions rebuilds row images set-based; 0: always by probes.'),
  ('feed_c', 'off', 'on: with the C module, large feed windows rebuild row images in C in one pass (measured no faster than the SQL set-based arm).');
-- One tracked table's part of the feed: its versions visible at $4 and not at $3, with keys
-- in [$1, $2]. Parameters: $1, $2 the key bounds, $3, $4 the coordinates, $5 whether to rebuild
-- row images, $6-$8 and $9-$11 each coordinate's epoch, xmin and xmax as integers. Columns: vkey,
-- vlsn, tbl, tname, key, op, xid, role, then new and old, or for a page (paged) the version's
-- partition and row id instead, which _gnomon.feed_img_arm finds it by again.
create function _gnomon.feed_arm(t gnomon.tracked, images bool, paged bool, narrow text default '', with_old bool default true) returns text
language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare vk text; idj text; img text;
begin
  vk := case when t.wide_key then _gnomon.key_sql(t, 'i') else _gnomon.key_sql(t, 'v') end;
  idj := case when t.wide_key then format('LEFT JOIN %s i ON i.gn_rid = v.gn_rid', _gnomon.obj(t, 'id')) else '' end;
  if images and not paged then img := _gnomon.feed_img_joins(t, with_old); end if;
  return _gnomon.tpl($q$
      select v.gn_key, v.gn_lsn, @REL@::regclass, @REL@::text, @VK@,
             case when v.gn_flags & 1 <> 0 then 'insert' when v.gn_flags & 4 <> 0 then 'delete' else 'update' end,
             (((v.gn_key & 281474976710655) - v.gn_xoff)::text)::xid8, gn_r.rolname,
             @TAIL@
        from @V@ v
        @IDJ@
        left join pg_catalog.pg_roles gn_r on gn_r.oid = v.gn_role   -- one join, not a lookup per version
        @IMGJ@
       where v.gn_key >= $1 and v.gn_key <= $2 and (v.gn_flags & 48) = 0@NARROW@@AFTER@
         -- gnomon._vis at $4 and not at $3, with each coordinate's epoch and xmin/xmax as integers
         -- first: most versions are below the one's xmin or at or above the other's xmax, so few need
         -- the snapshot's in-progress list (and the xid8 conversion it takes)
         and ((v.gn_key >> 48) < $6 or ((v.gn_key >> 48) = $6 and (@X@ < $7 or (@X@ < $8
              and pg_visible_in_snapshot((@X@::text)::xid8, ($4).snap)))))
         and not ((v.gn_key >> 48) < $9 or ((v.gn_key >> 48) = $9 and (@X@ < $10 or (@X@ < $11
              and pg_visible_in_snapshot((@X@::text)::xid8, ($3).snap)))))$q$,
    'REL', quote_literal(t.rel::text), 'VK', vk, 'V', _gnomon.obj(t, 'v'), 'IDJ', idj,
    'TAIL', case when paged then 'v.gn_part, ' || case when t.wide_key then 'v.gn_rid' else 'null::int8' end
                 when images then 'case when v.gn_flags & 4 = 0 then to_jsonb(gn_img) end, o.img'
                 else 'null::jsonb, null::jsonb' end,
    'NARROW', narrow,
    -- a page starts after its position ($12, $13: version key and LSN; changes_page)
    'AFTER', case when paged then ' and ($12::int8 is null or (v.gn_key, v.gn_lsn) >= ($12, $13))' else '' end,
    -- the image joins only when images are asked for (not one empty join per version)
    'IMGJ', coalesce(img, ''),
    'X', '((v.gn_key & 281474976710655) - v.gn_xoff)');
end $$;

-- The joins that rebuild version v's row image (gn_img) and its predecessor's (o.img), inline (no
-- function call per version): the version itself, and for a delta its keyframe in the same
-- partition. The same expressions as the routing views' history arm.
create function _gnomon.feed_img_joins(t gnomon.tracked, with_old bool default true) returns text
language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare cs _gnomon.col[] := _gnomon.tcols(t.id); eq text; img text; oimg text;
begin
  eq := case when t.wide_key then '%1$s.gn_rid = %2$s.gn_rid'
             else (select string_agg(format('%%1$s.%1$s = %%2$s.%1$s', k.q), ' AND ') from unnest(_gnomon.keys(cs)) k) end;
  img := (select string_agg(case when c.iskey then case when t.wide_key then 'i.' else 'v.' end || c.q
                                 else _gnomon.rval(c) end || ' AS ' || c.q, ', ' order by c.num) from unnest(cs) c);
  oimg := replace(replace(img, 'k.gn_', 'k2.gn_'), 'v.gn_', 'v2.gn_');
  return _gnomon.tpl($j$
        left join lateral (select k.* from @V@ k
                            where (v.gn_flags & 8) = 0 and @EQ_KV@ and k.gn_part = v.gn_part and (k.gn_flags & 8) <> 0
                              and (k.gn_key, k.gn_lsn) < (v.gn_key, v.gn_lsn)
                            order by k.gn_key desc, k.gn_lsn desc limit 1) k on true
        left join lateral (select @IMG@) gn_img on true@OLDJ@$j$,
    'V', _gnomon.obj(t, 'v'), 'EQ_KV', format(eq, 'k', 'v'), 'IMG', img,
    'OLDJ', case when not with_old then E'\n        left join lateral (select null::jsonb as img) o on true' else _gnomon.tpl($o$
        left join lateral (
          select to_jsonb(gn_oimg) as img
            from (select p.* from @V@ p where @EQ_PV@ and (p.gn_key, p.gn_lsn) < (v.gn_key, v.gn_lsn)
                   order by p.gn_key desc, p.gn_lsn desc limit 1) v2
            left join lateral (select k2.* from @V@ k2
                                where (v2.gn_flags & 8) = 0 and @EQ_K2V2@ and k2.gn_part = v2.gn_part and (k2.gn_flags & 8) <> 0
                                  and (k2.gn_key, k2.gn_lsn) < (v2.gn_key, v2.gn_lsn)
                                order by k2.gn_key desc, k2.gn_lsn desc limit 1) k2 on true
            cross join lateral (select @OIMG@) gn_oimg
           where (v.gn_flags & 1) = 0 and (v2.gn_flags & 4) = 0) o on true$o$,
      'V', _gnomon.obj(t, 'v'), 'EQ_PV', format(eq, 'p', 'v'), 'EQ_K2V2', format(eq, 'k2', 'v2'), 'OIMG', oimg) end);
end $$;

-- The set-based arm for a large window: the partitions that overlap it scanned once,
-- in row-index order, each version rebuilt with window functions instead of index probes: its
-- keyframe is the first row of its group (a running count of keyframes per key and partition),
-- its predecessor the row before it (lag). A partition is self-contained: a key's first write in
-- it carries a keyframe forward, so neither ever lies outside the scan. Same columns and
-- parameters as _gnomon.feed_arm.
create function _gnomon.feed_set_arm(t gnomon.tracked, narrow text default '', with_old bool default true) returns text
language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare cs _gnomon.col[] := _gnomon.tcols(t.id); ks _gnomon.col[]; vs _gnomon.col[]; pk text; kfirst text; nat text;
        lags text; newj text; oldj text; rk text; idj text;
begin
  ks := _gnomon.keys(cs); vs := _gnomon.vals(cs);
  pk := case when t.wide_key then 'v.gn_rid' else _gnomon.lst(ks, 'v.') end;
  kfirst := coalesce((select string_agg(format('first_value(v.gn_c%1$s) over wk as k_gn_c%1$s', c.slot)
                                        || case when c.large then format(', first_value(v.gn_h%1$s) over wk as k_gn_h%1$s', c.slot) else '' end, ', ')
                        from unnest(vs) c), 'null::int as gn_none');
  -- native values of every column (keys from the version, or the id table for wide keys)
  nat := (select string_agg(case when c.iskey then case when t.wide_key then 'i.' else 'v.' end || c.q
                                 else replace(replace(_gnomon.rval(c), 'k.gn_mask', 'v.k_gn_mask'), 'k.gn_', 'v.k_gn_') end
                            || ' AS gn_x' || c.num, ', ' order by c.num) from unnest(cs) c);
  lags := (select string_agg(format('lag(x.gn_x%1$s) over wp as gn_o%1$s', c.num), ', ' order by c.num) from unnest(cs) c);
  -- JSON once, at the end
  newj := 'jsonb_build_object(' || (select string_agg(format('%L, v.gn_x%s', c.raw, c.num), ', ' order by c.num) from unnest(cs) c) || ')';
  oldj := 'jsonb_build_object(' || (select string_agg(format('%L, v.gn_o%s', c.raw, c.num), ', ' order by c.num) from unnest(cs) c) || ')';
  rk := 'jsonb_build_object(' || (select string_agg(format('%L, v.gn_x%s', c.raw, c.num), ', ' order by c.num) from unnest(ks) c) || ')';
  idj := case when t.wide_key then format('LEFT JOIN %s i ON i.gn_rid = v.gn_rid', _gnomon.obj(t, 'id')) else '' end;
  return _gnomon.tpl($q$
      select v.gn_key, v.gn_lsn, @REL@::regclass, @REL@::text, @RK@,
             case when v.gn_flags & 1 <> 0 then 'insert' when v.gn_flags & 4 <> 0 then 'delete' else 'update' end,
             (((v.gn_key & 281474976710655) - v.gn_xoff)::text)::xid8, gn_r.rolname,
             case when v.gn_flags & 4 = 0 then @NEWJ@ end,
             @OLD@
        from (select x.*@LAGS@
                from (select v.gn_key, v.gn_lsn, v.gn_flags, v.gn_xoff, v.gn_role, v.gn_part, v.gn_pk, @NAT@
                        from (select v.*, first_value(v.gn_mask) over wk as k_gn_mask, @KFIRST@
                                from (select v.*, @PKX@ as gn_pk, count(*) filter (where (v.gn_flags & 8) <> 0) over wkf as gn_kg
                                        from @V@ v
                                       where v.gn_part >= gnomon._part($1, @SPAN@) and v.gn_part <= gnomon._part(least($2, 9223372036854775806), @SPAN@)
                                      window wkf as (partition by @PK@, v.gn_part order by v.gn_key, v.gn_lsn rows between unbounded preceding and current row)) v
                              window wk as (partition by @PK@, v.gn_part, v.gn_kg order by v.gn_key, v.gn_lsn rows between unbounded preceding and current row)) v
                        @IDJ@) x
              window wp as (partition by x.gn_pk, x.gn_part order by x.gn_key, x.gn_lsn)) v
        left join pg_catalog.pg_roles gn_r on gn_r.oid = v.gn_role
       where v.gn_key >= $1 and v.gn_key <= $2 and (v.gn_flags & 48) = 0@NARROW@
         and ((v.gn_key >> 48) < $6 or ((v.gn_key >> 48) = $6 and (@X@ < $7 or (@X@ < $8
              and pg_visible_in_snapshot((@X@::text)::xid8, ($4).snap)))))
         and not ((v.gn_key >> 48) < $9 or ((v.gn_key >> 48) = $9 and (@X@ < $10 or (@X@ < $11
              and pg_visible_in_snapshot((@X@::text)::xid8, ($3).snap)))))$q$,
    'REL', quote_literal(t.rel::text), 'RK', rk, 'V', _gnomon.obj(t, 'v'), 'PK', pk,
    'PKX', case when t.wide_key then 'v.gn_rid' else 'row(' || _gnomon.lst(ks, 'v.') || ')' end,
    'KFIRST', kfirst, 'NAT', nat, 'IDJ', idj, 'SPAN', t.part_span::text, 'NEWJ', newj,
    'LAGS', case when with_old then ', lag(x.gn_flags) over wp as gn_pflags, ' || lags else '' end,
    'OLD', case when with_old then 'case when v.gn_flags & 1 = 0 and v.gn_pflags & 4 = 0 then ' || oldj || ' end' else 'null::jsonb' end,
    'NARROW', narrow, 'X', '((v.gn_key & 281474976710655) - v.gn_xoff)');
end $$;

-- The C arm (with the C module): the same partitions scanned partition by
-- partition in row-index order (a carried-forward keyframe shares its version key with the
-- predecessor it copies, so the partition comes first), each version's own values with whether it stores each column and, for a keyframe,
-- whether it had it; _gnomon.c_feed rebuilds the images in one pass, with the keyframe and the
-- previous image per key in memory instead of window functions and their sorts. Same columns and
-- parameters as the other arms.
create function _gnomon.feed_c_arm(t gnomon.tracked, narrow text default '', with_old bool default true) returns text
language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare cs _gnomon.col[] := _gnomon.tcols(t.id); ks _gnomon.col[] := _gnomon.keys(cs); kv text := case when t.wide_key then 'i.' else 'v.' end;
        q text; missing jsonb;
begin
  execute 'select jsonb_build_array(' || (select string_agg(format('to_jsonb((%s)::%s)', coalesce(c.missing, 'NULL'), c.typ), ', ' order by c.num) from unnest(cs) c) || ')'
    into missing;
  q := _gnomon.tpl($q$select v.gn_key, v.gn_lsn, v.gn_flags::int4, v.gn_xoff::int8, gn_r.rolname, v.gn_part::int4, @RK@,
         (v.gn_key >= $1 and v.gn_key <= $2 and (v.gn_flags & 48) = 0@NARROW@
          and ((v.gn_key >> 48) < $6 or ((v.gn_key >> 48) = $6 and (@X@ < $7 or (@X@ < $8
               and pg_visible_in_snapshot((@X@::text)::xid8, ($4).snap)))))
          and not ((v.gn_key >> 48) < $9 or ((v.gn_key >> 48) = $9 and (@X@ < $10 or (@X@ < $11
               and pg_visible_in_snapshot((@X@::text)::xid8, ($3).snap)))))),
         @FIELDS@
    from @V@ v
    @IDJ@
    left join pg_catalog.pg_roles gn_r on gn_r.oid = v.gn_role
   where v.gn_part >= gnomon._part($1, @SPAN@) and v.gn_part <= gnomon._part(least($2, 9223372036854775806), @SPAN@)
   order by v.gn_part, @PK@, v.gn_key, v.gn_lsn$q$,
    'RK', 'jsonb_build_object(' || (select string_agg(format('%L, %s%s', c.raw, kv, c.q), ', ' order by c.num) from unnest(ks) c) || ')',
    'NARROW', narrow, 'X', '((v.gn_key & 281474976710655) - v.gn_xoff)',
    'FIELDS', (select string_agg(case when c.iskey then format('to_jsonb(%s%s)', kv, c.q)
                                      else format('CASE WHEN %1$s OR ((v.gn_flags & 8) <> 0 AND %2$s) THEN to_jsonb(%3$s) END, %1$s, %2$s',
                                                  _gnomon.present(c, 'v'), _gnomon.avail(c, 'v'), _gnomon.sval(c, 'v')) end, ', ' order by c.num)
                 from unnest(cs) c),
    'V', _gnomon.obj(t, 'v'), 'IDJ', case when t.wide_key then format('LEFT JOIN %s i ON i.gn_rid = v.gn_rid', _gnomon.obj(t, 'id')) else '' end,
    'SPAN', t.part_span::text, 'PK', case when t.wide_key then 'v.gn_rid' else _gnomon.lst(ks, 'v.') end);
  return format('select * from _gnomon.c_feed(%L, %L::text[], %L, %L::jsonb, %s, %L::regclass, %L, $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)',
                q, (select array_agg(c.raw::text order by c.num) from unnest(cs) c),
                (select string_agg(case when c.iskey then 'k' else 'v' end, '' order by c.num) from unnest(cs) c),
                missing, case when with_old then 'true' else 'false' end, t.rel::text, t.rel::text);
end $$;

-- The images of one page row p (a version of this table, found again by partition, key and LSN):
-- a lateral arm of _gnomon.changes_page.
create function _gnomon.feed_img_arm(t gnomon.tracked) returns text
language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare cs _gnomon.col[] := _gnomon.tcols(t.id);
begin
  return _gnomon.tpl($q$
      select case when v.gn_flags & 4 = 0 then to_jsonb(gn_img) end as new, o.img as old
        from @FROM@
        @IDJ@
        @IMGJ@
       where p.tname = @REL@ and v.gn_part = p.part and v.gn_key = p.vkey and v.gn_lsn = p.vlsn@RID@$q$,
    'REL', quote_literal(t.rel::text),
    'RID', case when t.wide_key then ' and v.gn_rid = p.rid' else '' end,
    'FROM', case when t.wide_key then format('%s v', _gnomon.obj(t, 'v'))
                 else format('jsonb_to_record(p.key) as gn_rk(%s) join %s v on %s', _gnomon.key_recdef(t), _gnomon.obj(t, 'v'),
                             (select string_agg(format('v.%1$s = gn_rk.%1$s', k.q), ' AND ') from unnest(_gnomon.keys(cs)) k)) end,
    'IDJ', case when t.wide_key then format('LEFT JOIN %s i ON i.gn_rid = v.gn_rid', _gnomon.obj(t, 'id')) else '' end,
    'IMGJ', _gnomon.feed_img_joins(t));
end $$;

-- The candidates of the feed's scan from c1: a version invisible at c1 has its key at or
-- above c1's xmin (claim 3), so that is the range scanned. A transaction running at c1 holds its
-- xmin back, though, and widens the range to everything written since it began. Narrower: a
-- version invisible at c1 was written by a transaction at or past c1's xmax (so its key is too) or
-- by one of c1's in-progress transactions, which the xid index finds. (Up to 64 of them.)
create function _gnomon.feed_narrow(c1 gnomon.coord) returns text language sql immutable as $$
  select case when c1 is null or n = 0 or n > 64 then ''
              else format(' and (v.gn_key >= %s or ((v.gn_key >> 48) = %s and (%s)))', gnomon._kxmax(c1), c1.epoch,
                          (select string_agg(format('((v.gn_key & 281474976710655) - v.gn_xoff) = %s', gnomon._xid(x)), ' or ')
                             from pg_snapshot_xip(c1.snap) x)) end
    from (select count(*) as n from pg_snapshot_xip(c1.snap)) s
$$;

-- The coordinates' integer parts the arms test first.
create function _gnomon.feed_params(c1 gnomon.coord, c2 gnomon.coord) returns int8[] language sql immutable as $$
  select array[c2.epoch, gnomon._xid(pg_snapshot_xmin(c2.snap)), gnomon._xid(pg_snapshot_xmax(c2.snap)),
               c1.epoch, gnomon._xid(pg_snapshot_xmin(c1.snap)), gnomon._xid(pg_snapshot_xmax(c1.snap))]::int8[]
$$;

-- images => false leaves new and old null: the exact change set at the speed of the version scan,
-- for consumers that need keys and operations only (rebuilding row images costs index lookups
-- per version).
-- (work_mem: the feed is one ordered set; with the default 4MB a few hundred thousand versions
-- sort on disk, at a third of the speed)
-- (PL/pgSQL, not SQL: the plain-SQL install checks SQL bodies, and changes_mode comes later)
create function gnomon.changes(since text, until text default null, tables regclass[] default null, images bool default true)
returns table(vkey int8, vlsn pg_lsn, tbl regclass, key jsonb, op text, xid xid8, role name, new jsonb, old jsonb)
language plpgsql volatile as $$
begin
  return query select * from _gnomon.changes_mode(since, until, tables, case when images then 'both' else 'none' end);
end $$;

-- images: none, new (the cheaper half: many consumers need only the new image) or both.
create function gnomon.changes(since text, until text, tables regclass[], images text)
returns table(vkey int8, vlsn pg_lsn, tbl regclass, key jsonb, op text, xid xid8, role name, new jsonb, old jsonb)
language plpgsql volatile as $$
begin
  return query select * from _gnomon.changes_mode(since, until, tables,
    case lower(images) when 'none' then 'none' when 'false' then 'none' when 'f' then 'none' when 'new' then 'new'
                       when 'both' then 'both' when 'true' then 'both' when 't' then 'both'
                       else _gnomon.bad_images(images) end);
end $$;

create function _gnomon.bad_images(v text) returns text language plpgsql immutable as $$
begin
  raise exception 'images must be none, new or both, not %', v using errcode = '22023', hint = '[gnomon:images_must_none_new]';
end $$;

-- A table's window goes set-based when it holds at least feed_setbased_min versions (counted up
-- to that many, through the key index): below it the probes are cheaper.
create function _gnomon.changes_mode(since text, until text, tables regclass[], mode text)
returns table(vkey int8, vlsn pg_lsn, tbl regclass, key jsonb, op text, xid xid8, role name, new jsonb, old jsonb)
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp set work_mem = '64MB' as $$
declare c1 gnomon.coord := gnomon.resolve_coord(since); c2 gnomon.coord := coalesce(gnomon.resolve_coord(until), gnomon.coordinate());
        t gnomon.tracked; parts text[] := '{}'; x int8[] := _gnomon.feed_params(c1, c2); n int;
        thr int := coalesce(nullif(gnomon._cfg('feed_setbased_min'), '')::int, 20000);
        -- the C arm, when asked for and the module is loaded (feed_c = on)
        use_c bool := gnomon._cfg('feed_c') = 'on' and to_regprocedure('_gnomon.c_feed(text, text[], text, jsonb, boolean, regclass, text, '
                        'bigint, bigint, gnomon.coord, gnomon.coord, boolean, bigint, bigint, bigint, bigint, bigint, bigint)') is not null;
begin
  tables := _gnomon.base_rels(tables);
  for t in select * from gnomon.tracked where (tables is null or rel = any(tables)) and _gnomon.can_read(rel) order by id loop
    n := 0;
    if mode <> 'none' and t.mode = 'known' and thr > 0 then
      execute format('select count(*) from (select 1 from %s v where v.gn_key >= $1 and v.gn_key <= $2 limit %s) s', _gnomon.obj(t, 'v'), thr)
        into n using gnomon._kxmin(c1), gnomon._kxmax(c2);
    end if;
    if n >= thr and thr > 0 and use_c then
      parts := parts || _gnomon.feed_c_arm(t, _gnomon.feed_narrow(c1), mode = 'both');
    elsif n >= thr and thr > 0 then
      parts := parts || _gnomon.feed_set_arm(t, _gnomon.feed_narrow(c1), mode = 'both');
    else
      parts := parts || _gnomon.feed_arm(t, mode <> 'none', false, _gnomon.feed_narrow(c1), mode = 'both');
    end if;
  end loop;
  if cardinality(parts) = 0 then return; end if;
  -- TRUNCATEs on main in the window: one change each, with no key
  parts := array_append(parts, $q$select x.key, '0/0'::pg_lsn, t.rel, t.rel::text, '{}'::jsonb, 'truncate', (((x.key & 281474976710655) - x.xoff)::text)::xid8,
                              null::name, null::jsonb, null::jsonb
                         from _gnomon.cleared x join gnomon.tracked t on t.id = x.tbl
                        where x.branch = 0 and gnomon._vis(x.key, x.xoff, $4) and not gnomon._vis(x.key, x.xoff, $3)
                          and ($12::regclass[] is null or t.rel = any($12)) and _gnomon.can_read(t.rel)$q$);
  -- (version key, LSN) orders one row's versions; rows written concurrently can share it, so the
  -- row key completes a total order (feed paging and ledger leaves depend on it)
  -- (the table's name as text is a constant per table, not a lookup per version)
  return query execute 'select u.vkey, u.vlsn, u.tbl, u.key, u.op, u.xid, u.role, u.new, u.old from ('
    || array_to_string(parts, ' union all ')
    || ') u(vkey, vlsn, tbl, tname, key, op, xid, role, new, old) order by u.vkey, u.vlsn, u.tname, u.key::text'
    using gnomon._kxmin(c1), gnomon._kxmax(c2), c1, c2, mode <> 'none', x[1], x[2], x[3], x[4], x[5], x[6], tables;
end $$;

-- One page of the feed between c1 and c2 for feed_poll: the first lim changes in feed order with
-- version keys in [klo, khi] that come after the position (a_key, a_lsn, a_tname, a_rk), the
-- feed-order tuple of the last change already returned. Row images are rebuilt for the page's rows
-- only, after the page is chosen, in the same statement (one snapshot). Each row also carries its
-- tname, the position to continue from.
create function _gnomon.changes_page(c1 gnomon.coord, c2 gnomon.coord, klo int8, khi int8,
    a_key int8, a_lsn pg_lsn, a_tname text, a_rk text, lim int)
returns table(vkey int8, vlsn pg_lsn, tbl regclass, tname text, key jsonb, op text, xid xid8, role name, new jsonb, old jsonb)
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp set work_mem = '64MB' as $$
declare t gnomon.tracked; parts text[] := '{}'; imgs text[] := '{}'; x int8[] := _gnomon.feed_params(c1, c2);
begin
  for t in select * from gnomon.tracked where _gnomon.can_read(rel) order by id loop
    parts := parts || _gnomon.feed_arm(t, false, true, _gnomon.feed_narrow(c1));
    imgs := imgs || _gnomon.feed_img_arm(t);
  end loop;
  if cardinality(parts) = 0 then return; end if;
  return query execute 'with p as materialized (select u.* from ('
    || array_to_string(parts, ' union all ')
    || ') u(vkey, vlsn, tbl, tname, key, op, xid, role, part, rid)
       where $12::int8 is null or (u.vkey, u.vlsn, u.tname, u.key::text) > ($12, $13, $14, $15)
       order by u.vkey, u.vlsn, u.tname, u.key::text limit $16)
     select p.vkey, p.vlsn, p.tbl, p.tname, p.key, p.op, p.xid, p.role, i.new, i.old
       from p left join lateral (' || array_to_string(imgs, ' union all ') || ') i on true
      order by p.vkey, p.vlsn, p.tname, p.key::text'
    using greatest(gnomon._kxmin(c1), klo, a_key), least(gnomon._kxmax(c2), khi), c1, c2, true,
          x[1], x[2], x[3], x[4], x[5], x[6], a_key, a_lsn, a_tname, a_rk, lim;
end $$;

-- Consumers: each poll returns the next batch in feed order and remembers its position. A poll
-- fixes the end of its window (pending_to) and pages through it by position, not by offset: each
-- page reads the versions from the last change returned on, a key range at a time (growing until
-- the page is full), so draining a window reads each version about once.
-- A consumer belongs to the role that created it: only that role (or gnomon_admin) moves or
-- drops it, and each poll returns only the tables the polling role may read.
create function _gnomon.consumer_check(cr gnomon.consumer) returns void language plpgsql stable as $$
begin
  if cr.created_by is distinct from _gnomon.who()::name and not pg_has_role(_gnomon.who(), 'gnomon_admin', 'member') then
    raise exception 'feed consumer "%" belongs to role %', cr.name, cr.created_by using errcode = '42501', hint = '[gnomon:feed_consumer_belongs_role]';
  end if;
end $$;

create function gnomon.feed_create(consumer text, since text default 'now') returns gnomon.coord
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare c gnomon.coord := gnomon.resolve_coord(since); cr gnomon.consumer;
begin
  select * into cr from gnomon.consumer x where x.name = feed_create.consumer for update;
  if cr.name is not null then perform _gnomon.consumer_check(cr); end if;
  insert into gnomon.consumer(name, pos, created_by) values (consumer, c, _gnomon.who())
    on conflict (name) do update set pos = excluded.pos, pending_to = null, pending_off = 0,
      after_key = null, after_lsn = null, after_tbl = null, after_rk = null, updated_at = now();
  return c;
end $$;

-- A consumer keeps the history after its position from retention and dropping
-- (gnomon.history_pins): drop the ones no longer read.
create function gnomon.feed_drop(consumer text) returns bool
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare cr gnomon.consumer;
begin
  select * into cr from gnomon.consumer x where x.name = feed_drop.consumer for update;
  if cr.name is null then return false; end if;
  perform _gnomon.consumer_check(cr);
  delete from gnomon.consumer x where x.name = feed_drop.consumer;
  return true;
end $$;

create function gnomon.feed_poll(consumer text, lim int default 1000)
returns table(vkey int8, vlsn pg_lsn, tbl regclass, key jsonb, op text, xid xid8, role name, new jsonb, old jsonb)
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare cr gnomon.consumer; n int := 0; lo int8; hi int8; top int8; span int8 := 4096; r record;
begin
  select * into cr from gnomon.consumer c where c.name = feed_poll.consumer for update;
  if cr.name is null then raise exception 'unknown feed consumer "%"', consumer using hint = 'Create it with gnomon.feed_create(name, since). [gnomon:unknown_feed_consumer]'; end if;
  perform _gnomon.consumer_check(cr);
  if lim is null or lim < 1 then raise exception 'feed_poll needs a limit of at least 1' using hint = '[gnomon:feed_poll_needs_limit_least]'; end if;
  if cr.pending_to is null then
    cr.pending_to := gnomon.coordinate(); cr.pending_off := 0;
    cr.after_key := null; cr.after_lsn := null; cr.after_tbl := null; cr.after_rk := null;
  end if;
  if cr.pending_off > 0 then
    -- a window an earlier gnomon version was paging by offset: finish it that way
    return query select * from gnomon.changes(gnomon.coord_text(cr.pos), gnomon.coord_text(cr.pending_to)) offset cr.pending_off limit lim;
    get diagnostics n = row_count;
    if n < lim then
      update gnomon.consumer set pos = cr.pending_to, pending_to = null, pending_off = 0, updated_at = now() where name = feed_poll.consumer;
    else
      update gnomon.consumer set pending_to = cr.pending_to, pending_off = cr.pending_off + n, updated_at = now() where name = feed_poll.consumer;
    end if;
    return;
  end if;
  lo := greatest(gnomon._kxmin(cr.pos), cr.after_key);
  top := gnomon._kxmax(cr.pending_to);
  while n < lim and lo <= top loop
    hi := case when top - lo <= span then top else lo + span end;
    for r in select * from _gnomon.changes_page(cr.pos, cr.pending_to, lo, hi, cr.after_key, cr.after_lsn, cr.after_tbl, cr.after_rk, lim - n) loop
      vkey := r.vkey; vlsn := r.vlsn; tbl := r.tbl; key := r.key; op := r.op; xid := r.xid; role := r.role; new := r.new; old := r.old;
      return next;
      n := n + 1;
      cr.after_key := r.vkey; cr.after_lsn := r.vlsn; cr.after_tbl := r.tname; cr.after_rk := r.key::text;
    end loop;
    exit when hi >= top;
    lo := hi + 1;
    span := least(span * 4, 4611686018427387904);
  end loop;
  if n < lim then
    -- the window is drained: the next poll starts a new one
    update gnomon.consumer set pos = cr.pending_to, pending_to = null, pending_off = 0,
           after_key = null, after_lsn = null, after_tbl = null, after_rk = null, updated_at = now()
     where name = feed_poll.consumer;
  else
    update gnomon.consumer set pending_to = cr.pending_to, after_key = cr.after_key, after_lsn = cr.after_lsn,
           after_tbl = cr.after_tbl, after_rk = cr.after_rk, updated_at = now()
     where name = feed_poll.consumer;
  end if;
end $$;

-------------------------------------------------------------------------------
-- History of one row, and blame (5, Commit log and blame)
-------------------------------------------------------------------------------
-- at: when the version was written, as exactly as known: its commit time with
-- track_commit_timestamp on, else the time of its commit-log row (gnomon.xact), else the first
-- tick that saw it (at_tick, to the tick interval; null for a version newer than the last tick).
--
-- On a branch: the row's lineage, oldest first. Each level contributes its own
-- versions, preceded by the level below it as it stood at the cutoff in force when this level
-- first wrote the row (or at its current cutoff, if it never did): main's versions, then each
-- ancestor branch's, then the branch's own. A branch TRUNCATE before the first write hides the
-- levels below. `branch` names the level a version was written on.
create function _gnomon.key_arg(t gnomon.tracked, key jsonb) returns jsonb language plpgsql immutable as $$
begin
  if key is null then raise exception 'a row key is required' using hint = '[gnomon:row_key_required]'; end if;
  if jsonb_typeof(key) = 'object' then return key; end if;
  if cardinality(t.key_cols) = 1 and jsonb_typeof(key) in ('number', 'string', 'boolean') then
    return jsonb_build_object(t.key_cols[1], key);
  end if;
  raise exception 'a row key of % is a JSON object of its key columns (%)', t.rel, array_to_string(t.key_cols, ', ')
    using errcode = '22023', hint = format('For example {"%s": ...}. A bare value works for a single-column key. [gnomon:bad_key]', t.key_cols[1]);
end $$;

-- The first tick that saw a version: an index range on the tick's xmax, then a
-- step forward while the version was still in progress at the tick.
create function gnomon._tick_of(k int8, xoff int4) returns timestamptz language plpgsql stable as $$
declare x int8 := ((k >> 48) << 48) | ((k & 281474976710655) - xoff); r record; n int := 0;
begin
  for r in select tk.at, tk.coord from gnomon.tick tk where tk.kx > x order by tk.kx, tk.id loop
    if gnomon._vis(k, xoff, r.coord) then return r.at; end if;
    n := n + 1;
    exit when n > 10000;
  end loop;
  return null;
end $$;

create function _gnomon.hist_level(tid int, key jsonb, b int, upto gnomon.coord, depth int default 0)
returns table(vkey int8, xid xid8, role name, op text, at_tick timestamptz, actor text, reason text, row_image jsonb, at timestamptz, branch text, lsn pg_lsn)
language plpgsql volatile set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked := _gnomon.trow(tid); vkj jsonb; rid int8; bname text; fk int8; bb gnomon.branch_base; cl int8;
        kwhere text; ts bool := current_setting('track_commit_timestamp') = 'on'; ep int2 := gnomon._epoch_ro();
        lowx xid8 := (greatest(0, greatest(gnomon._xid(pg_current_xact_id_if_assigned()), gnomon._xid(pg_snapshot_xmax(pg_current_snapshot()))) - 2147483647)::text)::xid8;
begin
  if depth > 64 then raise exception 'branch lineage too deep' using hint = '[gnomon:branch_lineage_too_deep]'; end if;
  kwhere := (select string_agg(format('v.%1$I = ($1->>%1$L)::%2$s', a.attname, format_type(a.atttypid, a.atttypmod)), ' and ')
               from unnest(t.key_cols) kc join pg_attribute a on a.attrelid = t.rel and a.attname = kc);
  if b = 0 then
    if t.wide_key then
      execute format('select gn_rid from %s v where %s', _gnomon.obj(t, 'id'), kwhere) into rid using key;
      vkj := jsonb_build_object('gn_rid', rid);
    else
      vkj := key;
    end if;
    return query execute format($q$
     select * from (
      select v.gn_key, g.x, (select rolname from pg_roles where oid = v.gn_role),
             case when v.gn_flags & 32 <> 0 then 'baseline' when v.gn_flags & 1 <> 0 then 'insert' when v.gn_flags & 4 <> 0 then 'delete' else 'update' end,
             gnomon._tick_of(v.gn_key, v.gn_xoff), x.actor, x.reason, %1$s($1, v.gn_key, v.gn_lsn),
             coalesce(case when $2 and (v.gn_key >> 48) = $3 and g.x >= $4 and (v.gn_flags & 32) = 0
                           then pg_xact_commit_timestamp(((g.x::text::int8 %% 4294967296)::text)::xid) end,
                      x.at, gnomon._tick_of(v.gn_key, v.gn_xoff)),
             'main'::text, v.gn_lsn
        from %2$s v
        cross join lateral (select (((v.gn_key & 281474976710655) - v.gn_xoff)::text)::xid8 as x) g
        left join gnomon.xact x on x.epoch = (v.gn_key >> 48)::int2 and x.xid = g.x
       where %3$s and (v.gn_flags & 16) = 0 and ($5::gnomon.coord is null or gnomon._vis(v.gn_key, v.gn_xoff, $5))
      union all
      -- a TRUNCATE on main that removed the row
      select x.key, (((x.key & 281474976710655) - x.xoff)::text)::xid8, xa.role, 'truncate', gnomon._tick_of(x.key, x.xoff),
             xa.actor, xa.reason, null::jsonb, coalesce(xa.at, gnomon._tick_of(x.key, x.xoff)), 'main'::text, '0/0'::pg_lsn
        from _gnomon.cleared x
        join gnomon.history_checkpoint h on h.tbl = x.tbl and h.cleared_key = x.key
        left join gnomon.xact xa on xa.epoch = (x.key >> 48)::int2 and xa.xid = (((x.key & 281474976710655) - x.xoff)::text)::xid8
       where x.tbl = $6 and x.branch = 0 and ($5::gnomon.coord is null or gnomon._vis(x.key, x.xoff, $5))
         and exists (select 1 from %4$s v where v.gn_ck = h.id and %5$s)
     ) z order by 1, 11$q$, _gnomon.obj(t, 'vrow'), _gnomon.obj(t, 'v'),
       case when t.wide_key then 'v.gn_rid = ($1->>''gn_rid'')::int8' else kwhere end,
       case when t.mode = 'known' then _gnomon.obj(t, 'ck') else '(select null::int as gn_ck) ' end,
       case when t.mode = 'known' then replace(kwhere, '($1->>', '($7->>') else 'false' end)
      -- commit timestamps: only for this cluster's xids within the last 2^31 (a 32-bit xid names them)
      using vkj, ts, ep, lowx, upto, tid, key;
    return;
  end if;
  select name into bname from gnomon.branch where id = b;
  -- the first write of the row on this level (visible at upto), and the base in force then
  execute format($q$select min(v.gn_key) from (select * from %1$s union all select * from %2$s) v
                     where v.gn_branch = $2 and %3$s and ($3::gnomon.coord is null or gnomon._vis(v.gn_key, v.gn_xoff, $3))$q$,
                 _gnomon.obj(t, 'bv'), case when pg_is_in_recovery() then _gnomon.obj(t, 'bv') || ' where false' else _gnomon.obj(t, 'bv_u') end, kwhere)
    into fk using key, b, upto;
  select * into bb from gnomon.branch_base x
   where x.branch = b and (x.since_key is null or fk is null or x.since_key <= fk)
     and (upto is null or x.since_key is null or gnomon._vis(x.since_key, x.since_xoff, upto))
   order by x.id desc limit 1;
  -- a TRUNCATE on this level before its first write: nothing below shows through
  select min(c.key) into cl from _gnomon.cleared c
   where c.tbl = tid and c.branch = b and (upto is null or gnomon._vis(c.key, c.xoff, upto)) and (fk is null or c.key <= fk);
  if bb.id is not null and cl is null then
    return query select * from _gnomon.hist_level(tid, key, bb.lin_b[1], bb.lin_c[1], depth + 1);
  end if;
  return query execute format($q$
    select v.gn_key, g.x, (select rolname from pg_roles where oid = v.gn_role),
           case when v.gn_flags & 1 <> 0 then 'insert' when v.gn_flags & 4 <> 0 then 'delete' else 'update' end,
           gnomon._tick_of(v.gn_key, v.gn_xoff), x.actor, x.reason,
           case when v.gn_flags & 4 <> 0 then null
                else to_jsonb(v) - array['gn_branch', 'gn_key', 'gn_xoff', 'gn_lsn', 'gn_role', 'gn_flags'] end,
           coalesce(case when $4 and (v.gn_key >> 48) = $5 and g.x >= $6
                         then pg_xact_commit_timestamp(((g.x::text::int8 %% 4294967296)::text)::xid) end,
                    x.at, gnomon._tick_of(v.gn_key, v.gn_xoff)),
           $7, v.gn_lsn
      from (select * from %1$s union all select * from %2$s) v
      cross join lateral (select (((v.gn_key & 281474976710655) - v.gn_xoff)::text)::xid8 as x) g
      left join gnomon.xact x on x.epoch = (v.gn_key >> 48)::int2 and x.xid = g.x
     where v.gn_branch = $2 and %3$s and (v.gn_flags & 16) = 0 and ($3::gnomon.coord is null or gnomon._vis(v.gn_key, v.gn_xoff, $3))
     order by v.gn_key, v.gn_lsn$q$,
     _gnomon.obj(t, 'bv'), case when pg_is_in_recovery() then _gnomon.obj(t, 'bv') || ' where false' else _gnomon.obj(t, 'bv_u') end, kwhere)
    using key, b, upto, ts, ep, lowx, bname;
end $$;
revoke all on function _gnomon.hist_level(int, jsonb, int, gnomon.coord, int) from public;

create function gnomon.history(tbl regclass, key jsonb, branch text default 'main')
returns table(vkey int8, xid xid8, role name, op text, at_tick timestamptz, actor text, reason text, row_image jsonb, at timestamptz, on_branch text)
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; b gnomon.branch; k jsonb; h record; first bool := true; img jsonb;
begin
  perform _gnomon.require_read(tbl);
  tbl := _gnomon.base_rel(tbl);  select * into t from gnomon.tracked where rel = tbl;
  if t.id is null then
    raise exception '% is not tracked', tbl using errcode = '42P01', hint = format('Track it with gnomon.track(%L). [gnomon:not_tracked]', tbl::text);
  end if;
  b := gnomon._branch_row(coalesce(nullif(history.branch, ''), 'main'));
  if b.id <> 0 and not gnomon._may_read_branch(b.id) then
    raise exception 'role % may not read branch "%"', _gnomon.who(), b.name using errcode = '42501', hint = '[gnomon:branch_not_readable]';
  end if;
  k := _gnomon.key_arg(t, key);
  for h in select * from _gnomon.hist_level(t.id, k, b.id, null) loop
    -- a branch that changed a row main never wrote since tracking: main has no version of it, not
    -- even the baseline its first write would leave, so the row as tracked is main's row now. It
    -- is the baseline here, as on main, so blame credits the branch with what it changed only.
    if first and t.mode = 'known' and h.branch <> 'main' and h.op in ('update', 'delete') then
      execute format('select to_jsonb(x) from only %s x where %s', t.rel,
                     (select string_agg(format('x.%1$I = ($1->>%1$L)::%2$s', a.attname, format_type(a.atttypid, a.atttypmod)), ' and ')
                        from unnest(t.key_cols) kc join pg_attribute a on a.attrelid = t.rel and a.attname = kc))
        into img using k;
      if img is not null then
        if h.row_image is not null then
          img := (select jsonb_object_agg(e.key, e.value) from jsonb_each(img) e where h.row_image ? e.key);
        end if;
        vkey := t.track_key; xid := (((t.track_key & 281474976710655) - t.track_xoff)::text)::xid8;
        role := (select rolname from pg_roles where oid = t.track_role); op := 'baseline';
        at_tick := gnomon._tick_of(t.track_key, t.track_xoff); actor := null; reason := null;
        row_image := img; at := at_tick; on_branch := 'main';
        return next;
      end if;
    end if;
    first := false;
    vkey := h.vkey; xid := h.xid; role := h.role; op := h.op; at_tick := h.at_tick; actor := h.actor; reason := h.reason;
    row_image := h.row_image; at := h.at; on_branch := h.branch;
    return next;
  end loop;
end $$;

-- For each column of a row: the version that last changed it, by whom and when, on main or a branch.
create function gnomon.blame(tbl regclass, key jsonb, branch text default 'main')
returns table(col text, value jsonb, vkey int8, xid xid8, role name, actor text, reason text, at_tick timestamptz, at timestamptz, on_branch text)
language sql volatile as $$
  with h as (select h.*, lag(h.row_image) over (order by h.ord) as prev from gnomon.history(tbl, key, branch) with ordinality as h(vkey, xid, role, op, at_tick, actor, reason, row_image, at, on_branch, ord)),
       ch as (select e.key as col, e.value, h.vkey, h.xid, h.role, h.actor, h.reason, h.at_tick, h.at, h.on_branch, h.ord
                from h cross join lateral jsonb_each(h.row_image) e
               where h.row_image is not null and (h.prev is null or (h.prev -> e.key) is distinct from e.value))
  select distinct on (ch.col) ch.col, ch.value, ch.vkey, ch.xid, ch.role, ch.actor, ch.reason, ch.at_tick, ch.at, ch.on_branch
    from ch order by ch.col, ch.ord desc
$$;

-- The commit log: commits, undos and merges, newest first; a merge is listed once.
-- On a branch: its commits and the merges into or out of it.
-- The commit log. gnomon.xact (who wrote, with actor and reason) is readable by gnomon's roles
-- only; this shows anyone else their own transactions, those on branches they may read, and
-- merges and undos of branches they may read (the person running a merge and its reason
-- included), so it works for every role without exposing main's writers.
create function gnomon.log(branch text default null, lim int default 50)
returns table(at timestamptz, kind text, on_branch text, who name, actor text, reason text, detail jsonb)
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
begin
  return query
  with b as (select case when log.branch is null then null else (gnomon._branch_row(log.branch)).id end as id),
       me as (select _gnomon.who() as who,
                     coalesce((select rolsuper from pg_roles where rolname = _gnomon.who()), false)
                       or pg_has_role(_gnomon.who(), 'gnomon_reader', 'member') or pg_has_role(_gnomon.who(), 'gnomon_merger', 'member')
                       or pg_has_role(_gnomon.who(), 'gnomon_admin', 'member') as all_rows)
  select * from (
    select x.at, case when x.undo_of is not null then 'undo' else 'commit' end,
           coalesce(br.name, 'main'), x.role, x.actor, x.reason,
           jsonb_build_object('xid', x.xid::text) || coalesce(x.meta, '{}') || coalesce(x.undo_of, '{}')
      from gnomon.xact x left join gnomon.branch br on br.id = x.branch and x.branch <> 0, b, me
     where x.merge_id is null and (b.id is null or x.branch = b.id)
       and (me.all_rows or x.role = me.who or x.session_role = me.who or (x.branch <> 0 and gnomon._may_read_branch(x.branch)))
    union all
    select m.created_at, 'merge ' || m.status, s.name || ' -> ' || tg.name, m.created_by, x.actor, x.reason,
           jsonb_build_object('merge', m.id) || m.stats
      from gnomon.merge m join gnomon.branch s on s.id = m.source join gnomon.branch tg on tg.id = m.target
      left join lateral (select x.actor, x.reason from gnomon.xact x where x.merge_id = m.id order by x.at limit 1) x on true, b, me
     where (b.id is null or m.source = b.id or m.target = b.id)
       and (me.all_rows or m.created_by = me.who or gnomon._may_read_branch(m.source))
  ) l order by 1 desc limit lim;
end $$;
