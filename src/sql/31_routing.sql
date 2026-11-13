-- Read side: arm policies, the history arm, routing views, pass-through views.

-- Two routing schemas per user schema: gnomon_r_<schema> for main's past and logged branches
-- (no unlogged table anywhere in it, so a standby can read it), and gnomon_r_<schema>__s for
-- scratch branches (the same arms plus the unlogged branch tables). gnomon.use() picks one.
create function _gnomon.ensure_routing_schema(nsp name) returns text language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare r text := 'gnomon_r_' || nsp; x text;
begin
  foreach x in array array[r, r || '__s'] loop
    if not exists (select 1 from pg_namespace where nspname = x) then
      execute format('create schema %I', x);
      execute format('alter schema %I owner to %I', x, case when x = r then 'gnomon_reader' else 'gnomon_reader_s' end);
      execute format('grant usage on schema %I to public', x);
      execute format('grant create on schema %I to gnomon_admin', x);
    end if;
  end loop;
  return r;
end $$;

-- Logged routing views refuse a scratch context instead of reading it without its rows.
create function gnomon._ctx_logged_view() returns bool language plpgsql stable as $$
declare c _gnomon.ctx := gnomon._ctx();
begin
  if c.kind = 'scratch' then
    raise exception 'scratch branch "%" is read through the gnomon_r_<schema>__s routing schemas', c.name
      using errcode = '55000',
            hint = 'Select the branch with gnomon.use(), which puts the scratch routing schema on the search path. Scratch branches are not replicated, so a standby cannot read them. [gnomon:scratch_branch_read_through]';
  end if;
  return true;
end $$;

-- Has table tid had no version written with a key at or above kxmin? Unknown in the SQL core
-- (false, which the planner folds away); the C module substitutes its shared-memory watermark.
create function _gnomon.unchanged_since(tid int, kxmin int8) returns bool language sql stable
as $$ select false $$;

-- Lineage touch test used by both arm 1 and arm 3: was this key touched at some lineage level
-- before that level's cutoff? ("the same predicate functions are used on both sides")
-- which: 'l' logged touched keys, 'u' unlogged (scratch) ones, 'lu' both.
create function _gnomon.touched_sql(t gnomon.tracked, ks _gnomon.col[], outer_alias text, which text default 'lu') returns text
language sql immutable as $$
  select format($s$EXISTS (SELECT 1 FROM %2$s bk
    WHERE %3$s AND bk.gn_branch = ANY ((SELECT gnomon._ctx_lb())::int[])
      AND gnomon._vis(bk.gn_fkey, bk.gn_fxoff, ((SELECT gnomon._ctx_lc()))[array_position((SELECT gnomon._ctx_lb()), bk.gn_branch)]))$s$,
    _gnomon.lst(ks),
    case which when 'l' then _gnomon.obj(t, 'bk') when 'u' then _gnomon.obj(t, 'bk_u')
      else format('(SELECT gn_branch, %1$s, gn_fkey, gn_fxoff FROM %2$s UNION ALL SELECT gn_branch, %1$s, gn_fkey, gn_fxoff FROM %3$s)',
                  _gnomon.lst(ks), _gnomon.obj(t, 'bk'), _gnomon.obj(t, 'bk_u')) end,
    _gnomon.eqs(ks, 'bk', outer_alias))
$$;

-- Main changed this key since main's cutoff (versions with key >= cutoff.xmin).
create function _gnomon.changed_sql(t gnomon.tracked, ks _gnomon.col[], outer_alias text) returns text
language sql immutable as $$
  select case when t.mode = 'bitemporal' then
    -- bitemporal reads with a time context rebuild every row that has change points
    case when t.wide_key then
      format('EXISTS (SELECT 1 FROM %s i JOIN %s v ON v.gn_rid = i.gn_rid WHERE %s)', _gnomon.obj(t, 'id'), _gnomon.obj(t, 'v'), _gnomon.eqs(ks, 'i', outer_alias))
    else
      format('EXISTS (SELECT 1 FROM %s v WHERE %s)', _gnomon.obj(t, 'v'), _gnomon.eqs(ks, 'v', outer_alias))
    end
  when t.wide_key then
    format($s$EXISTS (SELECT 1 FROM %1$s i JOIN %2$s v ON v.gn_rid = i.gn_rid
      WHERE %3$s AND v.gn_key >= (SELECT gnomon._ctx_main_xmin_t(%5$s)) AND v.gn_part >= gnomon._part((SELECT gnomon._ctx_main_xmin_t(%5$s)), %4$s))$s$,
      _gnomon.obj(t, 'id'), _gnomon.obj(t, 'v'), _gnomon.eqs(ks, 'i', outer_alias), t.part_span, t.id)
  else
    format($s$EXISTS (SELECT 1 FROM %1$s v
      WHERE %2$s AND v.gn_key >= (SELECT gnomon._ctx_main_xmin_t(%4$s)) AND v.gn_part >= gnomon._part((SELECT gnomon._ctx_main_xmin_t(%4$s)), %3$s))$s$,
      _gnomon.obj(t, 'v'), _gnomon.eqs(ks, 'v', outer_alias), t.part_span, t.id)
  end
$$;

-- History arm, branch levels: each touched key at the lowest lineage level that touched it before
-- that level's cutoff, rebuilt from that branch's history. Written with an anti-join rather than
-- DISTINCT ON so that a join key reaches the touched-key index (one probe per outer row).
create function _gnomon.hist_branch_sql(t gnomon.tracked, ks _gnomon.col[], o_list text, scratch bool default true) returns text
language sql immutable as $$
  select _gnomon.tpl($v$SELECT @O_LIST@
  FROM @BKS@ o
  JOIN unnest((SELECT gnomon._ctx_lb())) WITH ORDINALITY AS l(br, ord) ON o.gn_branch = l.br
  CROSS JOIN LATERAL (
        SELECT b.* FROM @BVS@ b
         WHERE b.gn_branch = l.br AND @EQ_BO@
           AND b.gn_key <= gnomon._kxmax(((SELECT gnomon._ctx_lc()))[l.ord])
           AND gnomon._vis(b.gn_key, b.gn_xoff, ((SELECT gnomon._ctx_lc()))[l.ord])
         ORDER BY b.gn_key DESC, b.gn_lsn DESC LIMIT 1) h
 WHERE NOT (SELECT gnomon._ctx_main_now())          -- one-time filter: nothing to do on main
   @GUARD@AND gnomon._vis(o.gn_fkey, o.gn_fxoff, ((SELECT gnomon._ctx_lc()))[l.ord])
   AND (l.ord > 1 OR ((SELECT gnomon._ctx_lc()))[l.ord] IS NOT NULL)
   AND (h.gn_flags & 4) = 0
   AND l.ord <= coalesce((SELECT gnomon._ctx_clear(@TID@)), 2147483647)
   AND NOT EXISTS (
        SELECT 1 FROM @BKS@ o2
          JOIN unnest((SELECT gnomon._ctx_lb())) WITH ORDINALITY AS l2(br, ord) ON o2.gn_branch = l2.br
         WHERE @EQ_O2O@ AND l2.ord < l.ord AND gnomon._vis(o2.gn_fkey, o2.gn_fxoff, ((SELECT gnomon._ctx_lc()))[l2.ord]))$v$,
    'O_LIST', o_list,
    'BKS', case when scratch then format('(SELECT gn_branch, %1$s, gn_fkey, gn_fxoff FROM %2$s UNION ALL SELECT gn_branch, %1$s, gn_fkey, gn_fxoff FROM %3$s)',
                                          _gnomon.lst(ks), _gnomon.obj(t, 'bk'), _gnomon.obj(t, 'bk_u'))
                else _gnomon.obj(t, 'bk') end,
    'BVS', case when scratch then format('(SELECT * FROM %s UNION ALL SELECT * FROM %s)', _gnomon.obj(t, 'bv'), _gnomon.obj(t, 'bv_u'))
                else _gnomon.obj(t, 'bv') end,
    'GUARD', case when scratch then '' else 'AND (SELECT gnomon._ctx_logged_view())' || chr(10) || '   ' end,
    'EQ_BO', _gnomon.eqs(ks, 'b', 'o'),
    'TID', t.id::text, 'EQ_O2O', _gnomon.eqs(ks, 'o2', 'o'))
$$;

-- A version (alias %A%) between main's cutoff and the chosen history checkpoint, or any version
-- when none is chosen.
create function _gnomon.ck_between_sql() returns text language sql immutable as $$
  select '((SELECT gnomon._ctx_ck(%TID%)) IS NULL OR (%A%.gn_key <= gnomon._kxmax((SELECT gnomon._ctx_ck_hi(%TID%)))'
      || ' AND gnomon._vis(%A%.gn_key, %A%.gn_xoff, (SELECT gnomon._ctx_ck_hi(%TID%)))'
      || ' AND NOT gnomon._vis(%A%.gn_key, %A%.gn_xoff, (SELECT gnomon._ctx_ck_lo(%TID%)))))'
$$;

create function _gnomon.gen_read(tid int) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $g$
declare
  t gnomon.tracked := _gnomon.trow(tid);
  cs _gnomon.col[] := _gnomon.tcols(tid);
  ks _gnomon.col[] := _gnomon.keys(cs);
  vs _gnomon.col[] := _gnomon.vals(cs);
  c _gnomon.col;
  q text := _gnomon.qrel(_gnomon.trow(tid));
  rn text := quote_ident(t.relname);
  V text := _gnomon.obj(t, 'v');
  arm1 text; unchanged text := 'false';
  o_list text; m_list text; vrow_list text; h text;
  vk_c text; vk_eq_cv text; vk_eq_vk text; id_join text := ''; key_src text;
  rschema text; sc bool; hist text; rv text;
begin
  rschema := _gnomon.ensure_routing_schema(t.nsp);
  if t.key_index = 'btree' and t.mode = 'known' then
    -- per-statement "has the table changed since C?" probe at the b-tree's right edge
    unchanged := format('(SELECT NOT EXISTS (SELECT 1 FROM %s v WHERE v.gn_key >= (SELECT gnomon._ctx_main_xmin_t(%s))))', V, tid);
  elsif t.mode = 'known' then
    -- with a BRIN key index there is no right edge to probe; the C module answers from its
    -- shared-memory watermark (and the SQL core's constant false folds away)
    unchanged := format('(SELECT _gnomon.unchanged_since(%s, (SELECT gnomon._ctx_main_xmin_t(%s))))', tid, tid);
  end if;

  -- Arm 1: main's rows usable as-is. Restrictive policy scoped to gnomon_reader only, so
  -- application roles keep a plain table (any filtering policy would stop index use for
  -- operators that are not leakproof).
  arm1 := format($p$(SELECT gnomon._ctx_main_now()) OR (
      (SELECT gnomon._check_horizon(%1$s))
      AND (SELECT gnomon._ctx_clear(%1$s)) IS NULL
      AND (SELECT gnomon._ctx_ck(%1$s)) IS NULL
      AND NOT %2$s
      AND (%3$s OR NOT %4$s))$p$,
    tid, _gnomon.touched_sql(t, ks, rn, 'l'), unchanged, _gnomon.changed_sql(t, ks, rn));
  -- the checkpoint arm: the chosen checkpoint's rows, except keys a lineage level
  -- touched and keys main changed between the cutoff and the checkpoint (those are rebuilt)
  if t.mode = 'known' then
    execute format('drop policy if exists gnomon_ck on %s', _gnomon.obj(t, 'ck'));
    execute format($p$create policy gnomon_ck on %1$s for select to gnomon_reader using (
        gn_ck = (SELECT gnomon._ctx_ck(%2$s))
        AND (SELECT gnomon._check_horizon(%2$s))
        AND (SELECT gnomon._ctx_clear(%2$s)) IS NULL
        AND NOT %3$s
        AND NOT EXISTS (SELECT 1 FROM %4$s v WHERE %5$s
              AND v.gn_key >= gnomon._kxmin((SELECT gnomon._ctx_ck_lo(%2$s)))
              AND v.gn_part >= gnomon._part(gnomon._kxmin((SELECT gnomon._ctx_ck_lo(%2$s))), %6$s)
              AND v.gn_key <= gnomon._kxmax((SELECT gnomon._ctx_ck_hi(%2$s)))
              AND gnomon._vis(v.gn_key, v.gn_xoff, (SELECT gnomon._ctx_ck_hi(%2$s)))
              AND NOT gnomon._vis(v.gn_key, v.gn_xoff, (SELECT gnomon._ctx_ck_lo(%2$s)))))$p$,
      _gnomon.obj(t, 'ck'), tid, _gnomon.touched_sql(t, ks, quote_ident(t.base || '__ck'), 'l'), V,
      case when t.wide_key then format('v.gn_rid = (SELECT i.gn_rid FROM %s i WHERE %s)', _gnomon.obj(t, 'id'), _gnomon.eqs(ks, 'i', quote_ident(t.base || '__ck')))
           else _gnomon.eqs(ks, 'v', quote_ident(t.base || '__ck')) end, t.part_span);
    execute format('drop policy if exists gnomon_ck_s on %s', _gnomon.obj(t, 'ck'));
    execute format('create policy gnomon_ck_s on %s as restrictive for select to gnomon_reader_s using (NOT %s)',
                   _gnomon.obj(t, 'ck'), _gnomon.touched_sql(t, ks, quote_ident(t.base || '__ck'), 'u'));
  end if;
  execute format('alter table %s enable row level security', q);
  execute format('drop policy if exists gnomon_arm1 on %s', q);
  execute format('create policy gnomon_arm1 on %s as restrictive for select to gnomon_reader using (%s)', q, arm1);
  -- scratch views (owned by gnomon_reader_s, a member of gnomon_reader) also exclude keys a
  -- scratch level touched; this is the only policy that names an unlogged table
  execute format('drop policy if exists gnomon_arm1_s on %s', q);
  execute format('create policy gnomon_arm1_s on %s as restrictive for select to gnomon_reader_s using ((SELECT gnomon._ctx_main_now()) OR NOT %s)',
                 q, _gnomon.touched_sql(t, ks, rn, 'u'));
  if not t.user_rls then
    execute format('drop policy if exists gnomon_all on %s', q);
    execute format('create policy gnomon_all on %s for all to public using (true) with check (true)', q);
  else
    execute format('drop policy if exists gnomon_all on %s', q);
    perform _gnomon.gen_user_rls(tid);
  end if;

  -- select lists, in the table's column order
  o_list := (select string_agg(case when c2.iskey then 'o.' || c2.q else 'h.' || c2.q end, ', ' order by c2.num) from unnest(cs) c2);
  if t.wide_key then
    key_src := 'i';
    vk_c := 'v.gn_rid'; vk_eq_cv := 'v.gn_rid = c.gn_rid'; vk_eq_vk := 'k.gn_rid = v.gn_rid';
    id_join := format('JOIN %s i ON i.gn_rid = c.gn_rid', _gnomon.obj(t, 'id'));
  else
    key_src := 'c';
    vk_c := _gnomon.lst(ks, 'v.'); vk_eq_cv := _gnomon.eqs(ks, 'v', 'c'); vk_eq_vk := _gnomon.eqs(ks, 'k', 'v');
  end if;
  m_list := (select string_agg(case when c2.iskey then key_src || '.' || c2.q else _gnomon.rval(c2) || ' AS ' || c2.q end, ', ' order by c2.num) from unnest(cs) c2);

  -- Arm 3: rows rebuilt from history. Not flattenable; its size scales with changes.
  -- One history view and one routing view per branch kind: logged (gnomon_r_<schema>) and
  -- scratch (gnomon_r_<schema>__s, which adds the unlogged branch tables).
  foreach sc in array array[false, true] loop
  hist := _gnomon.obj(t, case when sc then 'hist_s' else 'hist' end);
  rv := case when sc then _gnomon.robj_s(t) else _gnomon.robj(t) end;
  execute format('drop view if exists %s cascade', rv);
  execute format('drop view if exists %s cascade', hist);
  if t.mode = 'known' then
    h := _gnomon.tpl($v$
create view @HIST@ as
@BRANCH_ARM@
UNION ALL
SELECT @M_LIST@
  FROM @V@ c
  CROSS JOIN LATERAL (
        SELECT v.* FROM @V@ v
         WHERE @VK_EQ_CV@ AND v.gn_key <= (SELECT gnomon._ctx_main_xmax_t(@TID@))
           AND gnomon._vis(v.gn_key, v.gn_xoff, (SELECT gnomon._ctx_main_cut_t(@TID@)))
         ORDER BY v.gn_key DESC, v.gn_lsn DESC LIMIT 1) v
  LEFT JOIN LATERAL (
        SELECT k.* FROM @V@ k
         WHERE @VK_EQ_VK@ AND k.gn_part = v.gn_part AND (k.gn_flags & 8) <> 0
           AND (k.gn_key, k.gn_lsn) < (v.gn_key, v.gn_lsn)
         ORDER BY k.gn_key DESC, k.gn_lsn DESC LIMIT 1) k ON (v.gn_flags & 8) = 0
  @ID_JOIN@
 WHERE NOT (SELECT gnomon._ctx_main_now())
   AND c.gn_key >= (SELECT gnomon._ctx_hist_xmin_t(@TID@))
   AND c.gn_part >= gnomon._part((SELECT gnomon._ctx_hist_xmin_t(@TID@)), @SPAN@)
   AND @BETWEEN_C@
   -- one row per key: its newest version (no DISTINCT, so join keys reach the index)
   AND NOT EXISTS (SELECT 1 FROM @V@ c2 WHERE @EQ_C2C@ AND c2.gn_part >= c.gn_part
                     AND (c2.gn_key, c2.gn_lsn) > (c.gn_key, c.gn_lsn) AND @BETWEEN_C2@)
   AND (v.gn_flags & 4) = 0
   AND (SELECT gnomon._ctx_clear(@TID@)) IS NULL
   AND NOT @TOUCHED@$v$,
      'HIST', hist, 'O_LIST', o_list, 'KK', _gnomon.lst(ks, 'k.'), 'KS', _gnomon.lst(ks),
      'EQ_BO', _gnomon.eqs(ks, 'b', 'o'), 'TID', tid::text, 'M_LIST', m_list,
      'VK_V', vk_c, 'V', V, 'SPAN', t.part_span::text, 'VK_EQ_CV', vk_eq_cv, 'VK_EQ_VK', vk_eq_vk,
      'ID_JOIN', id_join, 'TOUCHED', _gnomon.touched_sql(t, ks, key_src, case when sc then 'lu' else 'l' end),
      'BRANCH_ARM', _gnomon.hist_branch_sql(t, ks, o_list, sc),
      'EQ_C2C', case when t.wide_key then 'c2.gn_rid = c.gn_rid' else _gnomon.eqs(ks, 'c2', 'c') end,
      -- with a checkpoint chosen, only the versions between the cutoff and it
      'BETWEEN_C', replace(_gnomon.ck_between_sql(), '%A%', 'c'), 'BETWEEN_C2', replace(_gnomon.ck_between_sql(), '%A%', 'c2'));
    h := replace(h, '%TID%', tid::text);
  else
    h := _gnomon.gen_bitemporal_hist(tid, sc);
  end if;
  execute h;
  execute format('alter view %s owner to %I', hist, case when sc then 'gnomon_reader_s' else 'gnomon_reader' end);

  -- Routing view: UNION ALL of bare tables plus the history arm (an arm with a WHERE would stop
  -- join keys being pushed into it); for known-time
  -- tables also the chosen history checkpoint, a bare table too
  execute format($v$create view %1$s as
      SELECT %2$s FROM %3$s
      UNION ALL SELECT %2$s FROM %4$s%5$s%8$s
      UNION ALL SELECT %2$s FROM %6$s%7$s$v$,
    rv, _gnomon.lst(cs), q, _gnomon.obj(t, 'b'),
    case when sc then format(E'\n      UNION ALL SELECT %s FROM %s', _gnomon.lst(cs), _gnomon.obj(t, 'b_u')) else '' end,
    hist,
    case when t.user_rls then ' WHERE ' || _gnomon.user_rls_pred(t.rel) else '' end,
    -- (the checkpoint is chosen in the arm, not only in its policy: a policy's qual does not prune
    -- partitions, a WHERE on a parameter does, at run time)
    case when t.mode = 'known' then format(E'\n      UNION ALL SELECT %s FROM %s WHERE gn_ck = (SELECT gnomon._ctx_ck(%s))%s', _gnomon.lst(cs), _gnomon.obj(t, 'ck'), tid,
                                           case when t.user_rls then ' AND ' || _gnomon.user_rls_pred(t.rel) else '' end) else '' end);
  execute format('alter view %s owner to %I', rv, case when sc then 'gnomon_reader_s' else 'gnomon_reader' end);
  -- the search view beside the logged routing view
  if not sc then perform _gnomon.gen_search(tid, arm1); end if;
  -- column defaults: branches draw from main's sequences
  foreach c in array cs loop
    if c.ident in ('a', 'd') then
      execute format('alter view %s alter column %s set default nextval(%L::regclass)', rv, c.q,
                     pg_get_serial_sequence(q, c.raw));
    elsif c.def is not null and not c.gen then
      execute format('alter view %s alter column %s set default %s', rv, c.q, c.def);
    end if;
  end loop;
  end loop;

  -- Per-version row images (jsonb) for diff, undo, blame and the feed.
  execute _gnomon.tpl($f$
create or replace function @FN@(vk jsonb, at_key int8, at_lsn pg_lsn) returns jsonb
language sql stable security definer set search_path = pg_catalog, pg_temp as $q$
  SELECT CASE WHEN (v.gn_flags & 4) <> 0 THEN NULL ELSE to_jsonb(gn_img) END
    FROM (SELECT v.* FROM @V@ v WHERE @VK_EQ_J@ AND (v.gn_key, v.gn_lsn) <= ($2, $3)
           ORDER BY v.gn_key DESC, v.gn_lsn DESC LIMIT 1) v
    LEFT JOIN LATERAL (SELECT k.* FROM @V@ k WHERE @VK_EQ_VK@ AND k.gn_part = v.gn_part AND (k.gn_flags & 8) <> 0
           AND (k.gn_key, k.gn_lsn) < (v.gn_key, v.gn_lsn) ORDER BY k.gn_key DESC, k.gn_lsn DESC LIMIT 1) k ON (v.gn_flags & 8) = 0
    @ID_JOIN2@
    CROSS JOIN LATERAL (SELECT @R_LIST@) gn_img
   WHERE _gnomon.can_read(@REL@::regclass)
$q$;$f$,
    'FN', _gnomon.obj(t, 'vrow'), 'V', V, 'REL', quote_literal(q),
    'VK_EQ_J', case when t.wide_key then 'v.gn_rid = ($1->>''gn_rid'')::int8'
                    else (select string_agg(format('v.%s = ($1->>%L)::%s', k.q, k.raw, k.typ), ' AND ' order by k.num) from unnest(ks) k) end,
    'VK_EQ_VK', vk_eq_vk,
    'ID_JOIN2', case when t.wide_key then format('JOIN %s i ON i.gn_rid = v.gn_rid', _gnomon.obj(t, 'id')) else '' end,
    'R_LIST', (select string_agg(case when c2.iskey then case when t.wide_key then 'i.' else 'v.' end || c2.q || ' AS ' || c2.q
                                     else _gnomon.rval(c2) || ' AS ' || c2.q end, ', ' order by c2.num) from unnest(cs) c2));
  execute format('alter function %s(jsonb, int8, pg_lsn) owner to gnomon_reader', _gnomon.obj(t, 'vrow'));
  execute format('grant execute on function %s(jsonb, int8, pg_lsn) to public', _gnomon.obj(t, 'vrow'));

  perform _gnomon.gen_write(tid);
  perform _gnomon.sync_grants(tid);
end $g$;

-- Routing-view grants mirror the base table's grants (reads and writes), plus gnomon's roles.
create function _gnomon.sync_grants(tid int) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked := _gnomon.trow(tid); g record; rv text;
begin
  foreach rv in array array[_gnomon.robj(t), _gnomon.robj_s(t)] loop
  -- start from nothing for application roles, so REVOKE on the table reaches the routing view
  for g in select distinct a.grantee from information_schema.role_table_grants a
            where a.table_schema in ('gnomon_r_' || t.nsp, 'gnomon_r_' || t.nsp || '__s') and a.table_name = t.relname
              and a.grantee not in ('gnomon_reader', 'gnomon_reader_s', 'gnomon_writer', 'gnomon_merger', 'gnomon_admin') loop
    execute format('revoke all on %s from %s', rv, case when g.grantee = 'PUBLIC' then 'public' else quote_ident(g.grantee) end);
  end loop;
  for g in
    select a.grantee, a.privilege_type from information_schema.role_table_grants a
     where a.table_schema = t.nsp and a.table_name = t.relname
       and a.privilege_type in ('SELECT','INSERT','UPDATE','DELETE')
       and a.grantee not in ('gnomon_reader', 'gnomon_reader_s')
  loop
    execute format('grant %s on %s to %s', g.privilege_type, rv,
                   case when g.grantee = 'PUBLIC' then 'public' else quote_ident(g.grantee) end);
  end loop;
  -- confined roles get grants on routing views only (5, Isolation)
  for g in select role from gnomon.confined loop
    execute format('grant select, insert, update, delete on %s to %I', rv, g.role);
  end loop;
  execute format('grant select, insert, update, delete on %s to gnomon_writer, gnomon_merger, gnomon_admin', rv);
  end loop;
  -- the scratch views read the unlogged branch tables
  execute format('grant select on %s, %s, %s to gnomon_reader_s', _gnomon.obj(t, 'b_u'), _gnomon.obj(t, 'bk_u'), _gnomon.obj(t, 'bv_u'));
  perform _gnomon.search_grants(tid);
  -- sequences behind column defaults: branch writes (and mirrored triggers) draw from them as gnomon_writer
  for g in
    select distinct d.refobjid::regclass as seq
      from pg_attrdef ad join pg_depend d on d.classid = 'pg_attrdef'::regclass and d.objid = ad.oid
      join pg_class c on c.oid = d.refobjid and c.relkind = 'S'
     where ad.adrelid = t.rel
    union
    select pg_get_serial_sequence(t.rel::text, a.attname)::regclass from pg_attribute a
     where a.attrelid = t.rel and a.attidentity <> '' and not a.attisdropped
  loop
    execute format('grant usage, select on sequence %s to gnomon_writer', g.seq);
    -- a confined role evaluates the routing view's defaults itself
    declare cr record;
    begin
      for cr in select c.role from gnomon.confined c where exists (select 1 from pg_roles where rolname = c.role) loop
        execute format('grant usage on sequence %s to %I', g.seq, cr.role);
      end loop;
    end;
  end loop;
end $$;

-- A write to an untracked table through its pass-through view, on a branch.
create function _gnomon.refuse_untracked_write() returns trigger language plpgsql as $$
declare n text := regexp_replace(tg_table_schema, '^gnomon_r_(.*?)(__s|__m[0-9]+|__v[0-9]+)?$', '\1');
begin
  raise exception '%.% is not tracked, so a branch cannot write it (reads on a branch see main''s rows)', n, tg_table_name
    using errcode = '42501', hint = format('Track it with gnomon.track(%L), or write it on main. [gnomon:not_tracked]', format('%I.%I', n, tg_table_name));
end $$;

-- Pass-through views for untracked tables: reads work, writes are refused by name
-- (by a trigger on the view).
create function _gnomon.passthrough(rel regclass) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare n name; r name; k "char"; rs text;
begin
  select c.relname, ns.nspname, c.relkind into r, n, k from pg_class c join pg_namespace ns on ns.oid = c.relnamespace where c.oid = rel;
  if exists (select 1 from gnomon.tracked where tracked.rel = $1) then return; end if;
  if not exists (select 1 from pg_namespace where nspname = 'gnomon_r_' || n) then return; end if;
  perform _gnomon.ensure_routing_schema(n);
  foreach rs in array array['gnomon_r_' || n, 'gnomon_r_' || n || '__s'] loop
  if k in ('r', 'p', 'f', 'm') then
    execute format('create or replace view %I.%I as select * from %s', rs, r, rel);
    execute format('alter view %I.%I owner to gnomon_reader', rs, r);
    execute format('grant select on %s to gnomon_reader', rel);
    execute format('grant select on %I.%I to public', rs, r);
    if k in ('r', 'p', 'f') then
      execute format('create or replace trigger gnomon_untracked instead of insert or update or delete on %I.%I for each row execute function _gnomon.refuse_untracked_write()', rs, r);
      execute format('grant insert, update, delete on %I.%I to public', rs, r);
    end if;
  elsif k = 'v' then
    -- user views are re-pointed at the routing schema so they read the branch
    perform _gnomon.reroute_view(rel, rs);
  end if;
  end loop;
exception when others then
  raise warning 'gnomon: could not create routing view for %: %', rel, sqlerrm;
end $$;

-- Copy a user view into the routing schema with names resolved through the routing schema.
create function _gnomon.reroute_view(rel regclass, rs text default null) returns void language plpgsql volatile as $$
declare n name; r name; def text; sp text := current_setting('search_path');
begin
  select c.relname, ns.nspname into r, n from pg_class c join pg_namespace ns on ns.oid = c.relnamespace where c.oid = rel;
  rs := coalesce(rs, 'gnomon_r_' || n);
  -- print the definition with the view's own schema visible so names come out unqualified
  perform set_config('search_path', quote_ident(n), true);
  def := pg_get_viewdef(rel, false);
  perform set_config('search_path', quote_ident(rs) || ', ' || quote_ident(n) || ', pg_catalog', true);
  execute format('create or replace view %I.%I as %s', rs, r, def);
  execute format('alter view %I.%I owner to %I', rs, r, case when rs like '%\_\_s' then 'gnomon_reader_s' else 'gnomon_reader' end);
  execute format('grant select on %I.%I to public', rs, r);
  perform set_config('search_path', sp, true);
exception when others then
  perform set_config('search_path', sp, true);
  raise warning 'gnomon: could not re-point view % at branch routing: %', rel, sqlerrm;
end $$;

create function _gnomon.refresh_schema_views(nsp name) returns void language plpgsql volatile as $$
declare r record; prev text := coalesce(current_setting('gnomon._in_ddl', true), '');
begin
  if not exists (select 1 from pg_namespace where nspname = 'gnomon_r_' || nsp) then return; end if;
  -- our own DDL: the event triggers stay out (the caller's state is restored below)
  perform set_config('gnomon._in_ddl', '1', true);
  for r in select c.oid::regclass as rel, c.relkind from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
            where ns.nspname = nsp and c.relkind in ('r','p','f','m','v')
              and not exists (select 1 from gnomon.tracked t where t.rel = c.oid)
              and not exists (select 1 from pg_inherits i where i.inhrelid = c.oid)
            order by c.relkind = 'v', c.oid
  loop
    perform _gnomon.passthrough(r.rel);
  end loop;
  perform set_config('gnomon._in_ddl', prev, true);
end $$;

-------------------------------------------------------------------------------
-- Search views: gnomon_q_<schema>
-------------------------------------------------------------------------------
-- A second view family whose main arm carries the arm-1 test as a WHERE, owned by gnomon_search,
-- which only the permissive policy covers on tracked tables: a restriction with a non-leakproof
-- operator (jsonb @>, LIKE, full text) is pushed into the arm and reaches its index. Join keys
-- are not pushed into an arm that carries a WHERE: these are for searching. The WHERE is an ordinary qual,
-- so a function in the query can be evaluated on a main row the branch does not show: they are
-- granted only to roles that may read the table itself, never to confined or masked roles, and
-- tables with their own row-level security get none.
create function _gnomon.ensure_search_schema(nsp name) returns text language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare q text := 'gnomon_q_' || nsp;
begin
  if not exists (select 1 from pg_namespace where nspname = q) then
    execute format('create schema %I', q);
    execute format('alter schema %I owner to gnomon_search', q);
    execute format('grant usage on schema %I to public', q);
  end if;
  return q;
end $$;

create function gnomon._search_ok(tid int) returns bool language plpgsql stable as $$
begin
  if gnomon._ctx_ck(tid) is not null then
    raise exception 'search views do not read through history checkpoints' using errcode = '0A000',
      hint = 'Read this moment through the routing view (gnomon.use without mode => ''search''). [gnomon:search_checkpoint]';
  end if;
  if exists (select 1 from gnomon.confined c where c.role = _gnomon.who()) then
    raise exception 'search views are not for confined roles' using errcode = '42501', hint = '[gnomon:search_confined]';
  end if;
  return true;
end $$;

create function _gnomon.gen_search(tid int, arm1 text) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked := _gnomon.trow(tid); cs _gnomon.col[] := _gnomon.cols((_gnomon.trow(tid)).rel); sv text; g record; s text;
begin
  sv := quote_ident('gnomon_q_' || t.nsp) || '.' || quote_ident(t.relname);
  if t.mode <> 'known' or t.user_rls then
    if to_regclass(sv) is not null then execute format('drop view %s', sv); end if;
    return;
  end if;
  perform _gnomon.ensure_search_schema(t.nsp);
  execute format('grant select on %s, %s, %s, %s to gnomon_search', t.rel, _gnomon.obj(t, 'b'), _gnomon.obj(t, 'bk'), _gnomon.obj(t, 'hist'));
  execute format('grant select on %s to gnomon_search', _gnomon.obj(t, 'v'));
  if t.wide_key then execute format('grant select on %s to gnomon_search', _gnomon.obj(t, 'id')); end if;
  execute format('drop policy if exists gnomon_search on %s', _gnomon.obj(t, 'b'));
  execute format('create policy gnomon_search on %s for select to gnomon_search using (true)', _gnomon.obj(t, 'b'));
  execute format('drop view if exists %s', sv);
  execute format($v$create view %1$s as
      SELECT %2$s FROM %3$s AS %4$I WHERE (%5$s) AND (SELECT gnomon._search_ok(%8$s))
      UNION ALL SELECT %2$s FROM %6$s b WHERE b.gn_branch = (SELECT gnomon._ctx_branch()) AND (SELECT gnomon._ctx_asof_null())
      UNION ALL SELECT %2$s FROM %7$s$v$,
    sv, _gnomon.lst(cs), t.rel, t.relname, arm1, _gnomon.obj(t, 'b'), _gnomon.obj(t, 'hist'), tid);
  execute format('alter view %s owner to gnomon_search', sv);
  perform _gnomon.search_grants(tid);
end $$;

-- Who may read a table's search view: roles that hold SELECT on the table itself, never a
-- confined one; again on every GRANT and REVOKE (sync_grants), like the routing views.
create function _gnomon.search_grants(tid int) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked := _gnomon.trow(tid); sv text; g record;
begin
  sv := quote_ident('gnomon_q_' || t.nsp) || '.' || quote_ident(t.relname);
  if to_regclass(sv) is null then return; end if;
  for g in select distinct a.grantee from information_schema.role_table_grants a
            where a.table_schema = 'gnomon_q_' || t.nsp and a.table_name = t.relname and a.grantee not in ('gnomon_search') loop
    execute format('revoke all on %s from %s', sv, case when g.grantee = 'PUBLIC' then 'public' else quote_ident(g.grantee) end);
  end loop;
  execute format('revoke all on %s from public', sv);
  for g in select distinct a.grantee, a.privilege_type from information_schema.role_table_grants a
            where a.table_schema = t.nsp and a.table_name = t.relname and a.privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE')
              and a.grantee not in ('gnomon_reader', 'gnomon_reader_s', 'gnomon_search')
              and not exists (select 1 from gnomon.confined c where c.role = a.grantee)
              -- (a role that may write but not read the table gets nothing: reading is the point)
              and exists (select 1 from information_schema.role_table_grants b where b.table_schema = t.nsp and b.table_name = t.relname
                             and b.grantee = a.grantee and b.privilege_type = 'SELECT') loop
    execute format('grant %s on %s to %s', g.privilege_type, sv, case when g.grantee = 'PUBLIC' then 'public' else quote_ident(g.grantee) end);
  end loop;
  execute format('grant select on %s to %I', sv, (select pg_get_userbyid(c.relowner) from pg_class c where c.oid = t.rel));
  for g in select c.role from gnomon.confined c where exists (select 1 from pg_roles r where r.rolname = c.role) loop
    execute format('revoke all on %s from %I', sv, g.role);
  end loop;
end $$;
