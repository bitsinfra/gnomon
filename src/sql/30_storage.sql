-- Storage per tracked table and the versioning triggers on main.

-- Template expansion: tpl('... @A@ ...', 'A', 'x', 'B', 'y').
create function _gnomon.tpl(src text, variadic kv text[]) returns text language plpgsql immutable as $$
declare i int := 1;
begin
  while i < cardinality(kv) loop
    src := replace(src, '@' || kv[i] || '@', coalesce(kv[i+1], ''));
    i := i + 2;
  end loop;
  if src ~ '@[A-Z_0-9]+@' then
    raise exception 'unexpanded template token %', (regexp_match(src, '@[A-Z_0-9]+@'))[1] using hint = '[gnomon:unexpanded_template_token]';
  end if;
  return src;
end $$;

create function _gnomon.trow(tid int) returns gnomon.tracked language sql stable as $$
  select * from gnomon.tracked where id = tid
$$;

-- Columns with value slots. Assigns slots to new value columns (never reuses a slot).
create function _gnomon.tcols(tid int) returns _gnomon.col[] language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked := _gnomon.trow(tid); cs _gnomon.col[]; c _gnomon.col; i int;
        out _gnomon.col[] := '{}'; cm jsonb := t.colmap; ns int := t.nslots;
begin
  cs := _gnomon.cols(t.rel);
  foreach c in array cs loop
    if c.raw like 'gn\_%' then
      raise exception 'column "%" of % uses the prefix gn_, which gnomon reserves for its storage columns', c.raw, t.rel using hint = '[gnomon:column_uses_prefix_gn]';
    end if;
    if not c.iskey then
      if cm ? c.num::text then
        c.slot := (cm ->> c.num::text)::int;
      else
        c.slot := ns; ns := ns + 1;
        cm := cm || jsonb_build_object(c.num::text, c.slot);
      end if;
    end if;
    out := out || c;
  end loop;
  if cm is distinct from t.colmap then
    update gnomon.tracked set colmap = cm, nslots = ns where id = tid;
  end if;
  return out;
end $$;

create function _gnomon.zero(n int) returns text language sql immutable as $$
  select format('B''%s''::varbit', repeat('0', n))
$$;
create function _gnomon.ones(n int) returns text language sql immutable as $$
  select format('B''%s''::varbit', repeat('1', n))
$$;
create function _gnomon.onebit(n int, slot int) returns text language sql immutable as $$
  select format('B''%s''::varbit', overlay(repeat('0', n) placing '1' from slot + 1 for 1))
$$;

-------------------------------------------------------------------------------
-- Storage tables
-------------------------------------------------------------------------------
create function _gnomon.gen_storage(tid int) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $g$
declare
  t gnomon.tracked := _gnomon.trow(tid);
  cs _gnomon.col[] := _gnomon.tcols(tid);
  ks _gnomon.col[] := _gnomon.keys(cs);
  vs _gnomon.col[] := _gnomon.vals(cs);
  c _gnomon.col;
  V text := _gnomon.obj(t, 'v');
  vkdef text; valdef text := '';
  sfx text; logged text;
  pk text := _gnomon.lst(ks);
  con record; n int := 0;
begin
  t := _gnomon.trow(tid);  -- tcols may have updated slots
  -- wide keys: an internal bigint id
  if t.wide_key then
    execute format('create table if not exists %s (gn_rid bigint generated always as identity primary key, %s, unique (%s))',
      _gnomon.obj(t, 'id'),
      (select string_agg(k.q || ' ' || k.typ || ' not null', ', ' order by k.num) from unnest(ks) k), pk);
    vkdef := 'gn_rid int8 not null';
  else
    vkdef := (select string_agg(k.q || ' ' || k.typ || ' not null', ', ' order by k.num) from unnest(ks) k);
  end if;

  -- value columns widest alignment first and variable-length last, so present values pad least
  -- (columns added by later DDL go at the end, as any added column does)
  valdef := (select coalesce(string_agg(format(', gn_c%s %s', x.slot, x.typ) || case when x.large then format(', gn_h%s bytea', x.slot) else '' end, ''
                                        order by y.typlen < 0, case y.typalign when 'd' then 0 when 'i' then 1 when 's' then 2 else 3 end, x.slot), '')
               from unnest(vs) x left join pg_type y on y.oid = x.typoid);

  -- main versions
  if t.mode = 'known' then
    -- the 8-byte stamp columns first, then the key, then the narrower ones: no alignment padding
    -- between them for keys of any width (every version pays for padding; columns are read by name)
    execute format($s$create table if not exists %1$s (
        gn_key int8 not null, gn_lsn pg_lsn not null, %2$s, gn_xoff int4 not null, gn_role oid not null,
        gn_part int4 not null, gn_flags int2 not null, gn_mask varbit %3$s
      ) partition by range (gn_part)$s$, V, vkdef, valdef);
    execute format('create table if not exists %s partition of %s default', _gnomon.obj(t, 'v_d'), V);
    -- no two versions share an entry, so deduplication only costs a pass over every full page
    -- (the leaves take the option from this index)
    execute format('create index if not exists %I on %s (%s, gn_key, gn_lsn) with (deduplicate_items = off)', t.base || '__v_row', V,
                   case when t.wide_key then 'gn_rid' else pk end);
    if t.key_index = 'btree' then
      execute format('create index if not exists %I on %s (gn_key)', t.base || '__v_key', V);
    else
      execute format('create index if not exists %I on %s using brin (gn_key)', t.base || '__v_key', V);
    end if;
    execute format('create index if not exists %I on %s using brin (((gn_key & 281474976710655) - gn_xoff))', t.base || '__v_xid', V);
  else
    -- bitemporal: unpartitioned, full images, valid-from change points
    execute format($s$create table if not exists %1$s (
        %2$s, gn_key int8 not null, gn_xoff int4 not null, gn_lsn pg_lsn not null, gn_role oid not null,
        gn_flags int2 not null, gn_part int4 not null default 0, gn_mask varbit,
        gn_valid_from timestamptz not null, gn_retracts int8 %3$s
      )$s$, V, vkdef, valdef);
    execute format('create index if not exists %I on %s (%s, gn_valid_from desc, gn_key desc, gn_lsn desc)', t.base || '__v_vt', V,
                   case when t.wide_key then 'gn_rid' else pk end);
    execute format('create index if not exists %I on %s (%s, gn_key, gn_lsn)', t.base || '__v_row', V,
                   case when t.wide_key then 'gn_rid' else pk end);
    execute format('create index if not exists %I on %s using brin (gn_key)', t.base || '__v_key', V);
    execute format('create index if not exists %I on %s using brin (((gn_key & 281474976710655) - gn_xoff))', t.base || '__v_xid', V);
    execute format('create table if not exists %s (%s, gn_valid_from timestamptz not null, gn_key int8 not null, primary key (%s, gn_valid_from, gn_key))',
                   _gnomon.obj(t, 'sched'), vkdef, case when t.wide_key then 'gn_rid' else pk end);
  end if;
  -- history checkpoints: full images of the table, a list partition per checkpoint
  if t.mode = 'known' then
    execute format('create table if not exists %s (gn_ck int not null, like %s) partition by list (gn_ck)', _gnomon.obj(t, 'ck'), t.rel);
    execute format('create index if not exists %I on %s (gn_ck, %s)', t.base || '__ck_row', _gnomon.obj(t, 'ck'), pk);
    foreach c in array cs loop
      if not exists (select 1 from pg_attribute where attrelid = _gnomon.obj(t, 'ck')::regclass and attname = c.raw and not attisdropped) then
        execute format('alter table %s add column %s %s%s', _gnomon.obj(t, 'ck'), c.q, c.typ,
                       case when c.missing is not null then ' default ' || c.missing else '' end);
      end if;
    end loop;
    execute format('alter table %s enable row level security', _gnomon.obj(t, 'ck'));
    execute format('grant select on %s to gnomon_reader', _gnomon.obj(t, 'ck'));
  end if;
  -- new value columns after DDL
  foreach c in array vs loop
    execute format('alter table %s add column if not exists gn_c%s %s', V, c.slot, c.typ);
    if c.large then execute format('alter table %s add column if not exists gn_h%s bytea', V, c.slot); end if;
  end loop;
  -- a column whose type changed: its history is converted too (the slot keeps the column)
  foreach c in array vs loop
    if (select format_type(a.atttypid, a.atttypmod) from pg_attribute a where a.attrelid = V::regclass and a.attname = 'gn_c' || c.slot) <> c.typ then
      perform _gnomon.retype_storage(V, 'gn_c' || c.slot, c.typ, t.rel, c.raw);
    end if;
  end loop;
  -- branch storage holds user columns by name: follow renames (by attribute number), retype,
  -- and let columns dropped from the table go empty
  perform _gnomon.follow_columns(t, cs);

  -- branch tables: logged and unlogged (scratch) copies
  foreach sfx in array array['', '_u'] loop
    logged := case when sfx = '' then '' else 'unlogged ' end;
    -- heads: user columns first, so mirrored user triggers see the user's row shape
    execute format('create %stable if not exists %s (like %s including generated including constraints, gn_branch int not null, primary key (gn_branch, %s))',
                   logged, _gnomon.obj(t, 'b' || sfx), t.rel, pk);
    execute format('create %stable if not exists %s (gn_branch int not null, %s, gn_fkey int8 not null, gn_fxoff int4 not null, primary key (gn_branch, %s))',
                   logged, _gnomon.obj(t, 'bk' || sfx),
                   (select string_agg(k.q || ' ' || k.typ || ' not null', ', ' order by k.num) from unnest(ks) k), pk);
    execute format('create index if not exists %I on %s (%s, gn_branch)', t.base || '__bk' || sfx || '_key', _gnomon.obj(t, 'bk' || sfx), pk);
    execute format($s$create %stable if not exists %s (like %s including generated, gn_branch int not null,
                     gn_key int8 not null, gn_xoff int4 not null, gn_lsn pg_lsn not null, gn_role oid not null, gn_flags int2 not null)$s$,
                   logged, _gnomon.obj(t, 'bv' || sfx), t.rel);
    execute format('create index if not exists %I on %s (gn_branch, %s, gn_key, gn_lsn) with (deduplicate_items = off)', t.base || '__bv' || sfx || '_row', _gnomon.obj(t, 'bv' || sfx), pk);
    execute format('create index if not exists %I on %s using brin (gn_key)', t.base || '__bv' || sfx || '_key', _gnomon.obj(t, 'bv' || sfx));
    -- new user columns after DDL
    foreach c in array cs loop
      if not exists (select 1 from pg_attribute where attrelid = _gnomon.obj(t, 'b' || sfx)::regclass and attname = c.raw and not attisdropped) then
        execute format('alter table %s add column %s %s%s', _gnomon.obj(t, 'b' || sfx), c.q, c.typ,
                       case when c.missing is not null then ' default ' || c.missing else '' end);
        execute format('alter table %s add column %s %s%s', _gnomon.obj(t, 'bv' || sfx), c.q, c.typ,
                       case when c.missing is not null then ' default ' || c.missing else '' end);
      end if;
    end loop;
    -- unique constraints are mirrored per branch
    for con in
      select ci.relname as iname, pg_get_indexdef(i.indexrelid) as def, i.indexrelid,
             (select string_agg(quote_ident(a.attname), ', ' order by k.ord)
                from unnest(i.indkey) with ordinality k(attnum, ord)
                join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum) as cols,
             pg_get_expr(i.indpred, i.indrelid) as pred
        from pg_index i join pg_class ci on ci.oid = i.indexrelid
       where i.indrelid = t.rel and i.indisunique and not i.indisprimary and i.indexprs is null
    loop
      n := n + 1;
      execute format('create unique index if not exists %I on %s (gn_branch, %s)%s',
                     left(t.base || '__b' || sfx || '_u' || n, 63), _gnomon.obj(t, 'b' || sfx), con.cols,
                     case when con.pred is not null then ' where ' || con.pred else '' end);
    end loop;
    n := 0;
    -- branch storage is reached only through gnomon's roles
    execute format('alter table %s enable row level security', _gnomon.obj(t, 'b' || sfx));
    execute format('drop policy if exists gnomon_writer on %s', _gnomon.obj(t, 'b' || sfx));
    execute format('create policy gnomon_writer on %s for all to gnomon_writer using (true) with check (true)', _gnomon.obj(t, 'b' || sfx));
    execute format('drop policy if exists gnomon_arm2 on %s', _gnomon.obj(t, 'b' || sfx));
    execute format('create policy gnomon_arm2 on %s for select to gnomon_reader using (gn_branch = (select gnomon._ctx_branch()) and (select gnomon._ctx_asof_null()))',
                   _gnomon.obj(t, 'b' || sfx));
    execute format('grant select on %s, %s, %s to gnomon_reader', _gnomon.obj(t, 'b' || sfx), _gnomon.obj(t, 'bk' || sfx), _gnomon.obj(t, 'bv' || sfx));
    execute format('grant select, insert, update, delete on %s, %s, %s to gnomon_writer', _gnomon.obj(t, 'b' || sfx), _gnomon.obj(t, 'bk' || sfx), _gnomon.obj(t, 'bv' || sfx));
    execute format('grant select, delete on %s, %s, %s to gnomon_admin', _gnomon.obj(t, 'b' || sfx), _gnomon.obj(t, 'bk' || sfx), _gnomon.obj(t, 'bv' || sfx));
  end loop;
  execute format('grant select on %s to gnomon_reader, gnomon_writer, gnomon_admin', V);
  execute format('grant select on %s to gnomon_reader', t.rel);
  if t.wide_key then
    execute format('grant select on %s to gnomon_reader, gnomon_writer, gnomon_admin', _gnomon.obj(t, 'id'));
  end if;
  if t.mode = 'bitemporal' then
    execute format('grant select on %s to gnomon_reader, gnomon_writer', _gnomon.obj(t, 'sched'));
  end if;
  update gnomon.tracked set colnames = (select coalesce(jsonb_object_agg(x.num::text, x.raw), '{}') from unnest(cs) x) where id = tid;
  perform _gnomon.ensure_parts(tid);
end $g$;

-- Convert a storage column to a column's new type, history included. A value the plain cast
-- cannot convert stops the DDL with that reason.
-- A merge that replays a type change on a branch knows its up expression (gnomon._retype_using:
-- the table, the column, the expression): history and other branches convert through it too.
create function _gnomon.retype_storage(rel text, col text, typ text, tbl regclass default null, ucol text default null) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare u jsonb := nullif(current_setting('gnomon._retype_using', true), '')::jsonb; ex text;
begin
  if u is not null and tbl is not null and (u ->> 'rel')::regclass = tbl and u ->> 'column' = ucol and u ->> 'expr' is not null then
    ex := regexp_replace(u ->> 'expr', '(^|[^a-zA-Z0-9_$."])' || quote_ident(ucol) || '($|[^a-zA-Z0-9_$"])', '\1' || quote_ident(col) || '\2', 'g');
    execute format('alter table %s alter column %I type %s using (%s)::%s', rel, col, typ, ex, typ);
    return;
  end if;
  begin
    execute format('alter table %s alter column %I type %s using %I::%s', rel, col, typ, col, typ);
  exception when cannot_coerce or datatype_mismatch then
    execute format('alter table %s alter column %I type %s using %I::text::%s', rel, col, typ, col, typ);
  end;
exception when others then
  raise exception 'gnomon cannot convert the history of a column to %: %', typ, sqlerrm
    using errcode = sqlstate, hint = 'History keeps every past value of the column; a type its values do not cast to cannot hold them. [gnomon:retype_history]';
end $$;

-- Branch storage (heads, history, checkpoints, logged and unlogged) after DDL on the table.
create function _gnomon.follow_columns(t gnomon.tracked, cs _gnomon.col[]) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare c _gnomon.col; prev text; rel text; a record; tbls text[];
begin
  tbls := array[_gnomon.obj(t, 'b'), _gnomon.obj(t, 'bv'), _gnomon.obj(t, 'b_u'), _gnomon.obj(t, 'bv_u')];
  if t.mode = 'known' and to_regclass(_gnomon.obj(t, 'ck')) is not null then tbls := tbls || _gnomon.obj(t, 'ck'); end if;
  foreach rel in array tbls loop
    continue when to_regclass(rel) is null;
    foreach c in array cs loop
      prev := t.colnames ->> c.num::text;
      if prev is not null and prev <> c.raw
         and exists (select 1 from pg_attribute x where x.attrelid = rel::regclass and x.attname = prev and not x.attisdropped)
         and not exists (select 1 from pg_attribute x where x.attrelid = rel::regclass and x.attname = c.raw and not x.attisdropped) then
        execute format('alter table %s rename column %I to %I', rel, prev, c.raw);
      end if;
      if not c.gen and (select format_type(x.atttypid, x.atttypmod) from pg_attribute x where x.attrelid = rel::regclass and x.attname = c.raw and not x.attisdropped) <> c.typ then
        perform _gnomon.retype_storage(rel, c.raw, c.typ, t.rel, c.raw);
      end if;
    end loop;
    -- columns the table no longer has: kept for history, no longer required
    for a in select x.attname from pg_attribute x where x.attrelid = rel::regclass and x.attnum > 0 and not x.attisdropped and x.attnotnull
                and x.attname not like 'gn\_%' and x.attname <> all(select y.raw from unnest(cs) y) loop
      execute format('alter table %s alter column %I drop not null', rel, a.attname);
    end loop;
  end loop;
end $$;

-- Write-time partitions. The current partition and `ahead` more exist; rows that
-- land in the default partition (no heartbeat ran) are moved out when their partition is made.
create function _gnomon.ensure_parts(tid int, ahead int default 2) returns int
language plpgsql volatile set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked := _gnomon.trow(tid); cur int4; p int4; nm text; made int := 0; moved bigint;
        V text; D text;
begin
  if t.mode <> 'known' then return 0; end if;
  V := _gnomon.obj(t, 'v'); D := _gnomon.obj(t, 'v_d');
  cur := gnomon._part((gnomon.current_epoch()::int8 << 48) | gnomon._xid(pg_snapshot_xmax(pg_current_snapshot())), t.part_span);
  -- partitions for parts that already have rows in the default partition
  for p in execute format('select distinct gn_part from %s', D) loop
    nm := t.base || '__v_p' || p;
    if to_regclass('_gnomon.' || quote_ident(nm)) is null then
      execute format('create table _gnomon.%I (like %s including defaults)', nm, V);
      execute format('with m as (delete from %s where gn_part = %s returning *) insert into _gnomon.%I select * from m', D, p, nm);
      execute format('alter table _gnomon.%I add constraint %I check (gn_part >= %s and gn_part < %s)', nm, nm || '_chk', p, p + 1);
      execute format('alter table %s attach partition _gnomon.%I for values from (%s) to (%s)', V, nm, p, p + 1);
      execute format('alter table _gnomon.%I drop constraint %I', nm, nm || '_chk');
      execute format('grant select on _gnomon.%I to gnomon_reader, gnomon_admin', nm);
      execute format('grant select, insert on _gnomon.%I to gnomon_writer', nm);
      made := made + 1;
    end if;
  end loop;
  for p in select generate_series(cur, cur + ahead) loop
    nm := t.base || '__v_p' || p;
    if to_regclass('_gnomon.' || quote_ident(nm)) is null then
      execute format('create table _gnomon.%I partition of %s for values from (%s) to (%s)', nm, V, p, p + 1);
      -- a new partition fills fast: let autoanalyze see it early (a database-wide ANALYZE right
      -- after tracking would otherwise leave "empty" statistics behind)
      execute format('alter table _gnomon.%I set (autovacuum_analyze_threshold = 500, autovacuum_analyze_scale_factor = 0.02)', nm);
      -- direct access to a leaf (the C trigger writes leaves) needs its own grants
      execute format('grant select on _gnomon.%I to gnomon_reader, gnomon_admin', nm);
      execute format('grant select, insert on _gnomon.%I to gnomon_writer', nm);
      made := made + 1;
    end if;
  end loop;
  return made;
end $$;

-------------------------------------------------------------------------------
-- Versioning triggers on main. Row mode (default) and statement mode (bulk).
-------------------------------------------------------------------------------
create function _gnomon.gen_main_trigger(tid int) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $g$
declare
  t gnomon.tracked := _gnomon.trow(tid);
  cs _gnomon.col[] := _gnomon.tcols(tid);
  ks _gnomon.col[] := _gnomon.keys(cs);
  vs _gnomon.col[] := _gnomon.vals(cs);
  c _gnomon.col;
  V text := _gnomon.obj(t, 'v');
  ns int := (select nslots from gnomon.tracked where id = tid);
  nv int := cardinality(vs);
  thr text := t.blob_threshold::text;
  valcols text := ''; vals_new text := ''; vals_old text := ''; vals_delta text := '';
  setbits text := ''; bitexpr text := ''; stamp text; part text;
  vk text; vk_new text; vk_old text; vk_eq_old text; vk_eq_new text; keys_same text; rids text := '';
  carry text; carry_first text; body text; fn text; zero text;
  s_vk_n text; s_vk_o text; s_vk_eq_o text; s_vals_n text := ''; s_vals_o text := ''; s_vals_x text := '';
  trk_xid text;
begin
  zero := _gnomon.zero(ns);
  trk_xid := ((t.track_key & 281474976710655) - t.track_xoff)::text;
  foreach c in array vs loop
    valcols := valcols || format(', gn_c%s', c.slot) || case when c.large then format(', gn_h%s', c.slot) else '' end;
    vals_new := vals_new || ', ' || _gnomon.wval(c, 'NEW') || case when c.large then ', ' || _gnomon.whash(c, 'NEW') else '' end;
    vals_old := vals_old || ', ' || _gnomon.wval(c, 'OLD') || case when c.large then ', ' || _gnomon.whash(c, 'OLD') else '' end;
    vals_delta := vals_delta || format(', CASE WHEN get_bit(m, %s) = 1 THEN %s END', c.slot, _gnomon.wval(c, 'NEW'))
                  || case when c.large then format(', CASE WHEN get_bit(m, %s) = 1 THEN %s END', c.slot, _gnomon.whash(c, 'NEW')) else '' end;
    setbits := setbits || format(E'\n    IF %s THEN m := set_bit(m, %s, 1); END IF;', _gnomon.ne(c, 'NEW.' || c.q, 'OLD.' || c.q), c.slot);
    -- statement mode
    s_vals_n := s_vals_n || ', ' || _gnomon.wval(c, 'n') || case when c.large then ', ' || _gnomon.whash(c, 'n') else '' end;
    s_vals_o := s_vals_o || ', ' || _gnomon.wval(c, 'o') || case when c.large then ', ' || _gnomon.whash(c, 'o') else '' end;
    s_vals_x := s_vals_x || format(', CASE WHEN x.gn_kf OR get_bit(x.gn_m, %s) = 1 THEN %s END', c.slot, _gnomon.wval(c, 'x'))
                || case when c.large then format(', CASE WHEN x.gn_kf OR get_bit(x.gn_m, %s) = 1 THEN %s END', c.slot, _gnomon.whash(c, 'x')) else '' end;
    bitexpr := bitexpr || format(E'\n             | CASE WHEN %s THEN %s ELSE %s END', _gnomon.ne(c, 'n.' || c.q, 'o.' || c.q), _gnomon.onebit(ns, c.slot), zero);
  end loop;
  vals_new := replace(vals_new, '__THR__', thr); vals_old := replace(vals_old, '__THR__', thr);
  vals_delta := replace(vals_delta, '__THR__', thr);
  s_vals_n := replace(s_vals_n, '__THR__', thr); s_vals_o := replace(s_vals_o, '__THR__', thr); s_vals_x := replace(s_vals_x, '__THR__', thr);
  keys_same := _gnomon.eqs(ks, 'NEW', 'OLD');
  -- gnomon._stamp() and gnomon._part() written out: no nested PL/pgSQL call per row, and the
  -- session's cached epoch read directly (gnomon.current_epoch() only when it is not cached yet)
  stamp := $s$gn_x := gnomon._xid(pg_current_xact_id());
  gn_r := greatest(gn_x, gnomon._xid(pg_snapshot_xmax(pg_current_snapshot())));
  st := row((coalesce(nullif(current_setting('gnomon._epoch', true), '')::int2, gnomon.current_epoch())::int8 << 48) | gn_r,
            (gn_r - gn_x)::int4, pg_current_wal_insert_lsn(),
            quote_ident(coalesce(nullif(current_setting('role'), 'none'), session_user::text))::regrole::oid)::gnomon.stamp;$s$;
  part := format('((st.key >> 48) * 1000000 + least((st.key & 281474976710655) / %s, 999999))::int4', greatest(t.part_span, 1));

  if t.wide_key then
    vk := 'gn_rid';
    vk_new := 'rid_n'; vk_old := 'rid_o'; vk_eq_old := 'v.gn_rid = rid_o'; vk_eq_new := 'v.gn_rid = rid_n';
    rids := _gnomon.tpl($r$
  IF TG_OP <> 'DELETE' THEN
    SELECT i.gn_rid INTO rid_n FROM @ID@ i WHERE @EQN@;
    IF NOT FOUND THEN
      INSERT INTO @ID@ (@KS@) VALUES (@KN@) ON CONFLICT DO NOTHING RETURNING gn_rid INTO rid_n;
      IF rid_n IS NULL THEN SELECT i.gn_rid INTO rid_n FROM @ID@ i WHERE @EQN@; END IF;
    END IF;
  END IF;
  IF TG_OP <> 'INSERT' THEN
    SELECT i.gn_rid INTO rid_o FROM @ID@ i WHERE @EQO@;
    IF NOT FOUND THEN
      INSERT INTO @ID@ (@KS@) VALUES (@KO@) ON CONFLICT DO NOTHING RETURNING gn_rid INTO rid_o;
      IF rid_o IS NULL THEN SELECT i.gn_rid INTO rid_o FROM @ID@ i WHERE @EQO@; END IF;
    END IF;
  END IF;$r$, 'ID', _gnomon.obj(t, 'id'), 'KS', _gnomon.lst(ks), 'KN', _gnomon.lst(ks, 'NEW.'), 'KO', _gnomon.lst(ks, 'OLD.'),
      'EQN', _gnomon.eqs(ks, 'i', 'NEW'), 'EQO', _gnomon.eqs(ks, 'i', 'OLD'));
    s_vk_n := format('_gnomon.%I(%s)', t.base || '__rid', _gnomon.lst(ks, 'n.'));
    s_vk_o := format('_gnomon.%I(%s)', t.base || '__rid', _gnomon.lst(ks, 'o.'));
    s_vk_eq_o := format('v.gn_rid = _gnomon.%I(%s)', t.base || '__rid', _gnomon.lst(ks, 'o.'));
    -- get-or-create id for statement mode and other set-based paths
    execute _gnomon.tpl($r$
create or replace function _gnomon.@FN@(@ARGS@) returns int8 language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $f$
#variable_conflict use_variable
declare r int8;
begin
  SELECT i.gn_rid INTO r FROM @ID@ i WHERE @EQ@;
  IF NOT FOUND THEN
    INSERT INTO @ID@ (@KS@) VALUES (@PS@) ON CONFLICT DO NOTHING RETURNING gn_rid INTO r;
    IF r IS NULL THEN SELECT i.gn_rid INTO r FROM @ID@ i WHERE @EQ@; END IF;
  END IF;
  RETURN r;
end $f$;$r$, 'FN', quote_ident(t.base || '__rid'), 'ID', _gnomon.obj(t, 'id'), 'KS', _gnomon.lst(ks),
      'ARGS', (select string_agg(k.typ, ', ' order by k.num) from unnest(ks) k),
      'PS', (select string_agg('$' || o, ', ' order by o) from generate_series(1, cardinality(ks)) o),
      'EQ', (select string_agg(_gnomon.eq(ks[o], 'i.' || (ks[o]).q, '$' || o), ' AND ' order by o) from generate_subscripts(ks, 1) o));
    execute format('alter function _gnomon.%I owner to gnomon_writer', t.base || '__rid');
    execute format('revoke all on function _gnomon.%I(%s) from public', t.base || '__rid', (select string_agg(k.typ, ', ' order by k.num) from unnest(ks) k));
    execute format('grant insert, select on %s to gnomon_writer', _gnomon.obj(t, 'id'));
  else
    vk := _gnomon.lst(ks);
    vk_new := _gnomon.lst(ks, 'NEW.'); vk_old := _gnomon.lst(ks, 'OLD.');
    vk_eq_old := _gnomon.eqs(ks, 'v', 'OLD'); vk_eq_new := _gnomon.eqs(ks, 'v', 'NEW');
    s_vk_n := _gnomon.lst(ks, 'n.'); s_vk_o := _gnomon.lst(ks, 'o.');
    s_vk_eq_o := _gnomon.eqs(ks, 'v', 'o');
  end if;

  if t.mode = 'bitemporal' then
    perform _gnomon.gen_bitemporal_trigger(tid);
    return;
  end if;

  carry := _gnomon.tpl($c$
      SELECT v.gn_key, v.gn_xoff, v.gn_lsn, v.gn_role INTO anyv FROM @V@ v WHERE @VK_EQ_OLD@ ORDER BY v.gn_key DESC, v.gn_lsn DESC LIMIT 1;
      IF FOUND THEN   -- carry-forward keyframe: a copy keeping the original stamp
        INSERT INTO @V@ (@VK@, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_part, gn_mask@VALCOLS@)
        VALUES (@VK_OLD@, anyv.gn_key, anyv.gn_xoff, anyv.gn_lsn, anyv.gn_role, 24, p, @ONES@@VALS_OLD@);
      ELSE            -- lazy baseline: the pre-image, stamped with the tracking transaction
        INSERT INTO @V@ (@VK@, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_part, gn_mask@VALCOLS@)
        VALUES (@VK_OLD@, least(@TKEY@::int8, st.key), ((least(@TKEY@::int8, st.key) & 281474976710655) - @TXID@)::int4,
                '0/0'::pg_lsn, @TROLE@::oid, 40, p, @ONES@@VALS_OLD@);
      END IF;$c$,
    'V', V, 'VK', vk, 'VK_EQ_OLD', vk_eq_old, 'VK_OLD', vk_old, 'VALCOLS', valcols, 'VALS_OLD', vals_old,
    'TKEY', t.track_key::text, 'TXID', trk_xid, 'TROLE', t.track_role::text, 'ONES', _gnomon.ones(ns));

  body := _gnomon.tpl($b$
create or replace function @FN@() returns trigger language plpgsql
security definer set search_path = pg_catalog, pg_temp 
set enable_seqscan = off as $f$
#variable_conflict use_variable
declare
  st gnomon.stamp; p int4; prv record; anyv record; m varbit; rid_o int8; rid_n int8; gn_x int8; gn_r int8;
begin
  -- logical apply workers carry history from their origin; everything else is versioned,
  -- including session_replication_role = replica (the trigger is ENABLE ALWAYS)
  IF _gnomon.is_apply() OR current_setting('gnomon._erasing', true) = '1' THEN RETURN NULL; END IF;
  -- a session on a branch, or reading the past, does not write main by naming the table with its
  -- schema (refused, SQL core); gnomon's own writes to main carry a merge token
  IF (coalesce(current_setting('gnomon.branch', true), '') NOT IN ('', 'main') OR coalesce(current_setting('gnomon.as_of', true), '') <> '')
     AND coalesce(current_setting('gnomon._main_write', true), '') <> '1' THEN
    PERFORM _gnomon.main_write_refused(TG_RELID::regclass);
  END IF;
  @STAMP@
  p := @PART@;
  IF coalesce(current_setting('gnomon.actor', true), '') <> '' OR coalesce(current_setting('gnomon.reason', true), '') <> '' THEN
    PERFORM gnomon._log_xact(0);
  END IF;@RIDS@
  -- An insert can follow a concurrent delete invisible to its transaction snapshot. Every
  -- later update or delete must also stay after that insert's fresh stamp, including our own.
  st := gnomon._stamp_fresh(st); p := @PART@;
  IF TG_OP = 'INSERT' THEN
    INSERT INTO @V@ (@VK@, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_part, gn_mask@VALCOLS@)
    VALUES (@VK_NEW@, st.key, st.xoff, st.lsn, st.role, 9, p, @ONES@@VALS_NEW@);
    RETURN NULL;
  END IF;
  IF TG_OP = 'UPDATE' AND @KEYS_SAME@ THEN
    SELECT v.gn_flags, v.gn_mask INTO prv FROM @V@ v WHERE @VK_EQ_OLD@ AND v.gn_part = p
     ORDER BY v.gn_key DESC, v.gn_lsn DESC LIMIT 1;
    IF NOT FOUND THEN
@CARRY@
      m := @ZERO@;
    ELSIF (prv.gn_flags & 8) <> 0 THEN
      m := @ZERO@;
    ELSE
      m := prv.gn_mask || substring(@ZERO@ from length(prv.gn_mask) + 1);
    END IF;@SETBITS@
    IF bit_count(m) * 2 > @NV@ THEN   -- cumulative delta passed half the row: write a keyframe
      INSERT INTO @V@ (@VK@, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_part, gn_mask@VALCOLS@)
      VALUES (@VK_NEW@, st.key, st.xoff, st.lsn, st.role, 10, p, @ONES@@VALS_NEW@);
    ELSE
      INSERT INTO @V@ (@VK@, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_part, gn_mask@VALCOLS@)
      VALUES (@VK_NEW@, st.key, st.xoff, st.lsn, st.role, 2, p, m@VALS_DELTA@);
    END IF;
    RETURN NULL;
  END IF;
  -- DELETE, or an UPDATE that changed the key (recorded as delete + insert)
  IF NOT EXISTS (SELECT 1 FROM @V@ v WHERE @VK_EQ_OLD@ AND v.gn_part = p) THEN
@CARRY@
  END IF;
  INSERT INTO @V@ (@VK@, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_part, gn_mask)
  VALUES (@VK_OLD@, st.key, st.xoff, st.lsn, st.role, 4, p, @ZERO@);
  IF TG_OP = 'UPDATE' THEN
    INSERT INTO @V@ (@VK@, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_part, gn_mask@VALCOLS@)
    VALUES (@VK_NEW@, st.key, st.xoff, st.lsn, st.role, 9, p, @ONES@@VALS_NEW@);
  END IF;
  RETURN NULL;
end $f$;$b$,
    'FN', _gnomon.obj(t, 'trg'), 'SPAN', t.part_span::text, 'RIDS', rids, 'V', V, 'VK', vk, 'VK_NEW', vk_new,
    'VK_OLD', vk_old, 'VK_EQ_OLD', vk_eq_old, 'VK_EQ_NEW', vk_eq_new, 'VALCOLS', valcols, 'VALS_NEW', vals_new, 'VALS_DELTA', vals_delta,
    'KEYS_SAME', keys_same, 'CARRY', carry, 'ZERO', zero, 'SETBITS', setbits, 'NV', nv::text, 'ONES', _gnomon.ones(ns),
    'STAMP', stamp, 'PART', part);
  execute body;

  -- statement mode: one function per event (transition tables allow one event per trigger)
  carry := _gnomon.tpl($c$
  INSERT INTO @V@ (@VK@, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_part, gn_mask@VALCOLS@)
  SELECT @S_VK_O@, coalesce(a.gn_key, least(@TKEY@::int8, st.key)),
         coalesce(a.gn_xoff, ((least(@TKEY@::int8, st.key) & 281474976710655) - @TXID@)::int4),
         coalesce(a.gn_lsn, '0/0'::pg_lsn), coalesce(a.gn_role, @TROLE@::oid),
         CASE WHEN a.gn_key IS NULL THEN 40 ELSE 24 END, p, @ONES@@S_VALS_O@
    FROM %SRC%
    LEFT JOIN LATERAL (SELECT v.gn_key, v.gn_xoff, v.gn_lsn, v.gn_role FROM @V@ v WHERE @S_VK_EQ_O@
                        ORDER BY v.gn_key DESC, v.gn_lsn DESC LIMIT 1) a ON true$c$,
    'V', V, 'VK', vk, 'VALCOLS', valcols, 'S_VK_O', s_vk_o, 'S_VALS_O', s_vals_o, 'S_VK_EQ_O', s_vk_eq_o,
    'TKEY', t.track_key::text, 'TXID', trk_xid, 'TROLE', t.track_role::text, 'ONES', _gnomon.ones(ns));
  -- (the paired rows' carry-forward comes from their probe; the others test the partition here)
  carry_first := replace(carry, '%SRC%', '(SELECT (x.gn_o).* FROM x WHERE x.gn_first) o');
  carry := carry || format(E'\n   WHERE NOT EXISTS (SELECT 1 FROM %s v WHERE %s AND v.gn_part = p);', V, s_vk_eq_o);

  execute _gnomon.tpl($b$
create or replace function @FN@() returns trigger language plpgsql
security definer set search_path = pg_catalog, pg_temp 
set enable_seqscan = off as $f$
#variable_conflict use_variable
declare st gnomon.stamp; p int4;
begin
  IF _gnomon.is_apply() OR current_setting('gnomon._erasing', true) = '1' THEN RETURN NULL; END IF;
  -- a session on a branch, or reading the past, does not write main by naming the table with its
  -- schema (refused, SQL core); gnomon's own writes to main carry a merge token
  IF (coalesce(current_setting('gnomon.branch', true), '') NOT IN ('', 'main') OR coalesce(current_setting('gnomon.as_of', true), '') <> '')
     AND coalesce(current_setting('gnomon._main_write', true), '') <> '1' THEN
    PERFORM _gnomon.main_write_refused(TG_RELID::regclass);
  END IF;
  st := gnomon._stamp(); p := gnomon._part(st.key, @SPAN@);
  IF coalesce(current_setting('gnomon.actor', true), '') <> '' OR coalesce(current_setting('gnomon.reason', true), '') <> '' THEN
    PERFORM gnomon._log_xact(0);
  END IF;
  -- AFTER triggers run with the rows already written and locked. One fresh stamp covers the
  -- statement, including deletes after an insert or update that advanced the history clock.
  st := gnomon._stamp_fresh(st); p := gnomon._part(st.key, @SPAN@);
  IF TG_OP = 'INSERT' THEN
    INSERT INTO @V@ (@VK@, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_part, gn_mask@VALCOLS@)
    SELECT @S_VK_N@, st.key, st.xoff, st.lsn, st.role, 9, p, @ONES@@S_VALS_N@ FROM n;
  ELSIF TG_OP = 'DELETE' THEN
@CARRY_DEL@
    INSERT INTO @V@ (@VK@, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_part, gn_mask)
    SELECT @S_VK_O@, st.key, st.xoff, st.lsn, st.role, 4, p, @ZERO@ FROM o;
  ELSE
    -- rows whose key changed: delete + insert
@CARRY_UNPAIRED@
    INSERT INTO @V@ (@VK@, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_part, gn_mask)
    SELECT @S_VK_O@, st.key, st.xoff, st.lsn, st.role, 4, p, @ZERO@ FROM o WHERE NOT EXISTS (SELECT 1 FROM n WHERE @EQ_NO@);
    INSERT INTO @V@ (@VK@, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_part, gn_mask@VALCOLS@)
    SELECT @S_VK_N@, st.key, st.xoff, st.lsn, st.role, 9, p, @ONES@@S_VALS_N@ FROM n WHERE NOT EXISTS (SELECT 1 FROM o WHERE @EQ_NO@);
    -- paired rows: one probe each for the partition's latest version; a carry-forward where it has
    -- none, then cumulative deltas (a delta with no version before it in the partition starts from
    -- an empty mask, as one after a carried keyframe would)
    WITH x AS MATERIALIZED (
           SELECT n.*, (coalesce(CASE WHEN (prv.gn_flags & 8) = 0 THEN prv.gn_mask || substring(@ZERO@ from length(prv.gn_mask) + 1) END, @ZERO@)@BITEXPR@) AS gn_m,
                  prv.gn_flags IS NULL AS gn_first, o AS gn_o
             FROM o JOIN n ON @EQ_NO@
             LEFT JOIN LATERAL (SELECT v.gn_flags, v.gn_mask FROM @V@ v WHERE @S_VK_EQ_O@ AND v.gn_part = p
                                 ORDER BY v.gn_key DESC, v.gn_lsn DESC LIMIT 1) prv ON true),
         c AS (@CARRY_FIRST@)
    INSERT INTO @V@ (@VK@, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_part, gn_mask@VALCOLS@)
    SELECT @X_VK@, st.key, st.xoff, st.lsn, st.role, CASE WHEN x.gn_kf THEN 10 ELSE 2 END, p,
           CASE WHEN x.gn_kf THEN @ONES@ ELSE x.gn_m END@S_VALS_X@
      FROM (SELECT y.*, bit_count(y.gn_m) * 2 > @NV@ AS gn_kf FROM x y) x;
  END IF;
  RETURN NULL;
end $f$;$b$,
    'FN', _gnomon.obj(t, 'strg'), 'SPAN', t.part_span::text, 'V', V, 'VK', vk, 'VALCOLS', valcols,
    'S_VK_N', s_vk_n, 'S_VK_O', s_vk_o, 'S_VALS_N', s_vals_n, 'S_VK_EQ_O', s_vk_eq_o, 'ZERO', zero,
    'CARRY_DEL', replace(carry, '%SRC%', 'o'),
    'CARRY_UNPAIRED', replace(replace(carry, '%SRC%', 'o'), 'WHERE NOT EXISTS (SELECT 1 FROM ' || V,
                              'WHERE NOT EXISTS (SELECT 1 FROM n WHERE ' || _gnomon.eqs(ks, 'n', 'o') || ') AND NOT EXISTS (SELECT 1 FROM ' || V),
    'CARRY_FIRST', carry_first,
    'EQ_NO', _gnomon.eqs(ks, 'n', 'o'), 'NV', nv::text, 'BITEXPR', bitexpr,
    'X_VK', case when t.wide_key then format('_gnomon.%I(%s)', t.base || '__rid', _gnomon.lst(ks, 'x.')) else _gnomon.lst(ks, 'x.') end,
    'S_VALS_X', s_vals_x, 'ONES', _gnomon.ones(ns));

  execute format('alter function %s() owner to gnomon_writer', _gnomon.obj(t, 'trg'));
  execute format('alter function %s() owner to gnomon_writer', _gnomon.obj(t, 'strg'));
  execute format('grant insert, select on %s to gnomon_writer', V);
  perform _gnomon.attach_main_triggers(tid);
end $g$;

create function _gnomon.attach_main_triggers(tid int) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked := _gnomon.trow(tid); q text := _gnomon.qrel(_gnomon.trow(tid));
        prev text := coalesce(current_setting('gnomon._in_ddl', true), '');
begin
  perform set_config('gnomon._in_ddl', '1', true);
  execute format('drop trigger if exists gnomon_v on %s', q);
  execute format('drop trigger if exists gnomon_vs_i on %s', q);
  execute format('drop trigger if exists gnomon_vs_u on %s', q);
  execute format('drop trigger if exists gnomon_vs_d on %s', q);
  if t.mode = 'bitemporal' then
    execute format('create trigger gnomon_v before insert or update or delete on %s for each row execute function %s()', q, _gnomon.obj(t, 'trg'));
    execute format('alter table %s enable always trigger gnomon_v', q);
  elsif t.write_mode = 'row' and t.c_trigger and to_regproc('_gnomon.c_version_trigger') is not null then
    execute format('create trigger gnomon_v after insert or update or delete on %s for each row execute function _gnomon.c_version_trigger()', q);
    execute format('alter table %s enable always trigger gnomon_v', q);
  elsif t.write_mode = 'row' then
    execute format('create trigger gnomon_v after insert or update or delete on %s for each row execute function %s()', q, _gnomon.obj(t, 'trg'));
    execute format('alter table %s enable always trigger gnomon_v', q);
  else
    execute format('create trigger gnomon_vs_i after insert on %s referencing new table as n for each statement execute function %s()', q, _gnomon.obj(t, 'strg'));
    execute format('create trigger gnomon_vs_u after update on %s referencing old table as o new table as n for each statement execute function %s()', q, _gnomon.obj(t, 'strg'));
    execute format('create trigger gnomon_vs_d after delete on %s referencing old table as o for each statement execute function %s()', q, _gnomon.obj(t, 'strg'));
    execute format('alter table %s enable always trigger gnomon_vs_i', q);
    execute format('alter table %s enable always trigger gnomon_vs_u', q);
    execute format('alter table %s enable always trigger gnomon_vs_d', q);
  end if;
  execute format('drop trigger if exists gnomon_truncate on %s', q);
  execute format('create trigger gnomon_truncate before truncate on %s for each statement execute function _gnomon.refuse_truncate()', q);
  execute format('alter table %s enable always trigger gnomon_truncate', q);
  execute format('drop trigger if exists gnomon_protect on %s', q);
  if t.protected then
    execute format('create trigger gnomon_protect before insert or update or delete on %s for each statement execute function _gnomon.protect_check()', q);
    execute format('alter table %s enable always trigger gnomon_protect', q);
  end if;
  perform set_config('gnomon._in_ddl', prev, true);
end $$;

-- Commit-log row for the current transaction (4.x, 5 "Commit log"). Idempotent.
create function gnomon._log_xact(branch int, merge_id bigint default null, undo_of jsonb default null, meta jsonb default null)
returns void language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  insert into gnomon.xact(epoch, xid, branch, role, session_role, actor, reason, merge_id, undo_of, meta)
  values (gnomon.current_epoch(), pg_current_xact_id(), branch,
          coalesce(nullif(current_setting('role'), 'none'), session_user::text), session_user,
          nullif(current_setting('gnomon.actor', true), ''), nullif(current_setting('gnomon.reason', true), ''),
          merge_id, undo_of, meta)
  on conflict (epoch, xid) do update set
    merge_id = coalesce(excluded.merge_id, xact.merge_id),
    undo_of  = coalesce(excluded.undo_of, xact.undo_of),
    meta     = coalesce(xact.meta, '{}') || coalesce(excluded.meta, '{}'),
    actor    = coalesce(xact.actor, excluded.actor),
    reason   = coalesce(xact.reason, excluded.reason);
end $$;
grant execute on function gnomon._log_xact(int, bigint, jsonb, jsonb) to public;

create function gnomon.note(actor text, reason text default null, meta jsonb default null) returns void
language plpgsql volatile as $$
begin
  perform set_config('gnomon.actor', coalesce(actor, ''), true);
  perform set_config('gnomon.reason', coalesce(reason, ''), true);
  perform gnomon._log_xact((gnomon._ctx()).branch, null, null, meta);
end $$;

-- Protected tables: writes need a merge token held by this transaction.
create function _gnomon.main_write_refused(rel regclass) returns void language plpgsql stable as $$
declare b text := coalesce(current_setting('gnomon.branch', true), ''); a text := coalesce(current_setting('gnomon.as_of', true), '');
begin
  if a <> '' then
    raise exception 'writes are refused while gnomon.as_of is set (reading the past is read-only): % would change main now', rel
      using errcode = '25006', hint = '[gnomon:writes_refused_while_as_of]';
  end if;
  raise exception 'this session is on branch "%": a write to % names main''s table and would change main', b, rel
    using errcode = '25006',
          hint = 'Write the branch through its routing schema (unqualified names after gnomon.use), or switch to main first. The C module routes schema-qualified names. [gnomon:session_branch_write_names]';
end $$;

create function _gnomon.protect_check() returns trigger language plpgsql
security definer set search_path = pg_catalog, pg_temp as $$
begin
  if not exists (select 1 from _gnomon.merge_txn where xid = pg_current_xact_id() and epoch = gnomon.current_epoch()) then
    raise exception 'table %.% is protected: changes reach it only through gnomon.merge', TG_TABLE_SCHEMA, TG_TABLE_NAME
      using errcode = '42501', hint = 'Make the change on a branch and merge it (requires gnomon_merger). [gnomon:table_protected_changes_reach]';
  end if;
  return null;
end $$;
