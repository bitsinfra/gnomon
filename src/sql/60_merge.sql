-- Three-way merge, rebase and early warning, undo.

-------------------------------------------------------------------------------
-- Line diff (Myers, O((N+M)D)) and diff3 for the text3 strategy
-------------------------------------------------------------------------------
-- For each line of a (1-based), the matching line of b in an LCS, or 0.
create function _gnomon.myers_map(a text[], b text[], max_d int default 4000) returns int[]
language plpgsql immutable as $$
declare n int := coalesce(cardinality(a), 0); m int := coalesce(cardinality(b), 0);
        mx int; off int; v int[]; tr int[] := '{}'; w int; d int; k int; x int; y int; dd int;
        res int[]; pk int; px int; py int; found_d int := -1;
begin
  res := array_fill(0, array[greatest(n, 1)]);
  if n = 0 or m = 0 then return res; end if;
  mx := least(n + m, max_d); off := mx + 1; w := 2 * mx + 3;
  v := array_fill(0, array[w]);
  <<outer>>
  for d in 0..mx loop
    tr := tr || v;                       -- trace row d (flattened, width w)
    k := -d;
    while k <= d loop
      if k = -d or (k <> d and v[k - 1 + off] < v[k + 1 + off]) then
        x := v[k + 1 + off];
      else
        x := v[k - 1 + off] + 1;
      end if;
      y := x - k;
      while x < n and y < m and a[x + 1] is not distinct from b[y + 1] loop
        x := x + 1; y := y + 1;
      end loop;
      v[k + off] := x;
      if x >= n and y >= m then found_d := d; exit outer; end if;
      k := k + 2;
    end loop;
  end loop;
  if found_d < 0 then return null; end if;   -- too different: caller treats as a conflict
  x := n; y := m;
  for dd in reverse found_d..0 loop
    k := x - y;
    if k = -dd or (k <> dd and tr[dd * w + k - 1 + off] < tr[dd * w + k + 1 + off]) then pk := k + 1; else pk := k - 1; end if;
    px := tr[dd * w + pk + off]; py := px - pk;
    while x > px and y > py loop
      res[x] := y; x := x - 1; y := y - 1;
    end loop;
    if dd > 0 then x := px; y := py; end if;
  end loop;
  -- leading snake at d = 0
  while x > 0 and y > 0 and a[x] is not distinct from b[y] loop
    res[x] := y; x := x - 1; y := y - 1;
  end loop;
  return res;
end $$;

-- diff3 over lines. Returns {"v": merged} or {"conflict": true, "hunks": [...]}.
create function _gnomon.diff3(base text, ours text, theirs text) returns jsonb
language plpgsql immutable as $$
declare bl text[] := string_to_array(coalesce(base, ''), E'\n'); ol text[] := string_to_array(coalesce(ours, ''), E'\n');
        tl text[] := string_to_array(coalesce(theirs, ''), E'\n');
        mo int[]; mt int[]; i int := 1; j int := 1; k int := 1; nb int; i2 int; jo int; kt int;
        outl text[] := '{}'; bc text[]; oc text[]; tc text[]; hunks jsonb := '[]';
begin
  nb := coalesce(cardinality(bl), 0);
  mo := _gnomon.myers_map(bl, ol); mt := _gnomon.myers_map(bl, tl);
  if mo is null or mt is null then
    return jsonb_build_object('conflict', true, 'hunks', '[]'::jsonb);
  end if;
  loop
    exit when i > nb and j > coalesce(cardinality(ol), 0) and k > coalesce(cardinality(tl), 0);
    if i <= nb and mo[i] = j and mt[i] = k then        -- stable line
      outl := outl || bl[i]; i := i + 1; j := j + 1; k := k + 1;
      continue;
    end if;
    -- next base line kept by both sides
    i2 := i;
    while i2 <= nb and not (mo[i2] > 0 and mt[i2] > 0 and mo[i2] >= j and mt[i2] >= k) loop i2 := i2 + 1; end loop;
    if i2 <= nb then jo := mo[i2]; kt := mt[i2]; else jo := coalesce(cardinality(ol), 0) + 1; kt := coalesce(cardinality(tl), 0) + 1; end if;
    bc := coalesce(bl[i:i2-1], '{}'); oc := coalesce(ol[j:jo-1], '{}'); tc := coalesce(tl[k:kt-1], '{}');
    if oc = bc then outl := outl || tc;
    elsif tc = bc then outl := outl || oc;
    elsif oc = tc then outl := outl || oc;
    else
      hunks := hunks || jsonb_build_object('base_line', i, 'base', array_to_string(bc, E'\n'),
                                           'ours', array_to_string(oc, E'\n'), 'theirs', array_to_string(tc, E'\n'));
      outl := outl || oc;
    end if;
    i := i2; j := jo; k := kt;
  end loop;
  if jsonb_array_length(hunks) > 0 then
    return jsonb_build_object('conflict', true, 'hunks', hunks, 'v', array_to_string(outl, E'\n'));
  end if;
  return jsonb_build_object('v', array_to_string(outl, E'\n'));
end $$;

-------------------------------------------------------------------------------
-- Value merges. Return {"v": value} or {"c": [conflicts]}; SQL NULL argument = absent.
-------------------------------------------------------------------------------
create function _gnomon.m3_jsonb(b jsonb, o jsonb, t jsonb, path text[]) returns jsonb
language plpgsql immutable as $$
-- {"v": value} when present, {} when absent; conflicting leaves are listed in "c".
declare k text; res jsonb := '{}'; cs jsonb := '[]'; sub jsonb;
begin
  if o is not distinct from t then return case when o is null then '{}' else jsonb_build_object('v', o) end; end if;
  if t is not distinct from b then return case when o is null then '{}' else jsonb_build_object('v', o) end; end if;
  if o is not distinct from b then return case when t is null then '{}' else jsonb_build_object('v', t) end; end if;
  if coalesce(jsonb_typeof(o), 'object') = 'object' and coalesce(jsonb_typeof(t), 'object') = 'object'
     and coalesce(jsonb_typeof(b), 'object') = 'object' and o is not null and t is not null then
    for k in select x from (select jsonb_object_keys(o) x union select jsonb_object_keys(t)
                            union select jsonb_object_keys(coalesce(b, '{}'))) s order by 1 loop
      sub := _gnomon.m3_jsonb(b -> k, o -> k, t -> k, path || k);
      if sub ? 'c' then cs := cs || (sub -> 'c'); end if;
      if sub ? 'v' then res := res || jsonb_build_object(k, sub -> 'v'); end if;
    end loop;
    if jsonb_array_length(cs) > 0 then return jsonb_build_object('c', cs, 'v', res); end if;
    return jsonb_build_object('v', res);
  end if;
  return jsonb_build_object('c', jsonb_build_array(jsonb_build_object('kind', 'jsonb-path', 'path', to_jsonb(path),
                                                                        'base', b, 'ours', o, 'theirs', t)), 'v', o);
end $$;

create function _gnomon.m3_set(b jsonb, o jsonb, t jsonb) returns jsonb language sql immutable as $$
  -- (ours ∪ added_by_theirs) − removed_by_theirs, keeping ours' order
  with be as (select e from jsonb_array_elements(coalesce(b, '[]')) e),
       te as (select e from jsonb_array_elements(coalesce(t, '[]')) e),
       oe as (select e, n from jsonb_array_elements(coalesce(o, '[]')) with ordinality x(e, n)),
       added as (select e from te except select e from be),
       removed as (select e from be except select e from te)
  select jsonb_build_object('v', coalesce(jsonb_agg(e order by n), '[]')) from (
    select oe.e, oe.n from oe where oe.e not in (select e from removed)
    union all
    select a.e, 1000000000 + row_number() over () from added a where a.e not in (select e from oe)) s
$$;

create function _gnomon.m3_value(strategy text, b jsonb, o jsonb, t jsonb, col text) returns jsonb
language plpgsql volatile as $$
declare r jsonb; d jsonb;
begin
  -- counters are deltas: two sides making the same change both apply (two sales of the last item are two sales)
  if strategy = 'counter' and o is not distinct from t and o is distinct from b
     and jsonb_typeof(o) = 'number' and jsonb_typeof(b) = 'number' then
    return jsonb_build_object('v', to_jsonb((o::text)::numeric + ((t::text)::numeric - (b::text)::numeric)));
  end if;
  if o is not distinct from t then return jsonb_build_object('v', o); end if;
  if t is not distinct from b then return jsonb_build_object('v', o); end if;
  if o is not distinct from b then return jsonb_build_object('v', t); end if;
  strategy := coalesce(strategy, 'conflict');
  case strategy
    when 'ours' then return jsonb_build_object('v', o);
    when 'theirs' then return jsonb_build_object('v', t);
    when 'counter' then
      if jsonb_typeof(o) = 'number' and jsonb_typeof(t) = 'number' and jsonb_typeof(b) = 'number' then
        return jsonb_build_object('v', to_jsonb((o::text)::numeric + ((t::text)::numeric - (b::text)::numeric)));
      end if;
    when 'jsonb' then
      r := _gnomon.m3_jsonb(b, o, t, array[col]);
      if r ? 'c' then
        return jsonb_build_object('c', (select jsonb_agg(x || jsonb_build_object('col', col)) from jsonb_array_elements(r -> 'c') x), 'v', r -> 'v');
      end if;
      return r;
    when 'set' then
      if coalesce(jsonb_typeof(o), 'array') = 'array' and coalesce(jsonb_typeof(t), 'array') = 'array' then
        return _gnomon.m3_set(b, o, t);
      end if;
    when 'text3' then
      if coalesce(jsonb_typeof(o), 'string') = 'string' and coalesce(jsonb_typeof(t), 'string') = 'string' then
        d := _gnomon.diff3(b ->> 0, o ->> 0, t ->> 0);
        -- With repeated lines the alignment is ambiguous, and two sides that made the same
        -- insertion can align it differently and get it applied twice. A clean result must be a
        -- fixed point: re-applying either side to it changes nothing. Otherwise the merge is
        -- reported as a conflict rather than guessed (never silently produce another text).
        if not (d ? 'conflict')
           and (_gnomon.diff3(b ->> 0, d ->> 'v', t ->> 0) is distinct from jsonb_build_object('v', d ->> 'v')
                or _gnomon.diff3(b ->> 0, o ->> 0, d ->> 'v') is distinct from jsonb_build_object('v', d ->> 'v')) then
          d := jsonb_build_object('conflict', true, 'hunks', jsonb_build_array(jsonb_build_object('base_line', 1,
                 'base', b ->> 0, 'ours', o ->> 0, 'theirs', t ->> 0, 'ambiguous', true)), 'v', o ->> 0);
        end if;
        if not (d ? 'conflict') then return jsonb_build_object('v', to_jsonb(d ->> 'v')); end if;
        return jsonb_build_object('c', jsonb_build_array(jsonb_build_object('col', col, 'kind', 'text-hunk', 'hunks', d -> 'hunks',
                                                         'base', b, 'ours', o, 'theirs', t)), 'v', o);
      end if;
    when 'conflict' then null;
    else
      -- a user function (base, ours, theirs) -> value; SQL NULL means conflict
      execute format('select %s($1, $2, $3)', strategy::regproc) into r using b, o, t;
      if r is not null then return jsonb_build_object('v', r); end if;
  end case;
  return jsonb_build_object('c', jsonb_build_array(jsonb_build_object('col', col, 'kind', 'value', 'base', b, 'ours', o, 'theirs', t)), 'v', o);
end $$;

-- Row merge. action: none | insert | update | delete. result: the merged row (or null).
create function _gnomon.m3_row(b jsonb, o jsonb, t jsonb, strat jsonb, keycols text[],
                               out action text, out result jsonb, out conflicts jsonb)
language plpgsql volatile as $$
declare k text; r jsonb; v jsonb; base jsonb;
begin
  conflicts := '[]';
  if b is null and t is null then action := 'none'; result := o; return; end if;
  if b is null and o is null then action := 'insert'; result := t; return; end if;
  if t is null then                                  -- theirs deleted
    if o is null then action := 'none'; result := null; return; end if;
    if o = b then action := 'delete'; result := null; return; end if;
    action := 'none'; result := o;
    conflicts := jsonb_build_array(jsonb_build_object('kind', 'delete-update', 'base', b, 'ours', o, 'theirs', null));
    return;
  end if;
  if o is null then                                  -- ours deleted
    if t = b then action := 'none'; result := null; return; end if;
    action := 'none'; result := null;
    conflicts := jsonb_build_array(jsonb_build_object('kind', 'update-delete', 'base', b, 'ours', null, 'theirs', t));
    return;
  end if;
  -- identical sides need no merge, unless a counter column moved on both
  if o = t and not exists (select 1 from jsonb_each_text(coalesce(strat, '{}')) st
                            where st.value = 'counter' and (b -> st.key) is distinct from (o -> st.key)) then
    action := 'none'; result := o; return;
  end if;
  base := b;
  result := o;
  for k in select jsonb_object_keys(o) loop
    if k = any(keycols) then continue; end if;
    if base is null then
      -- insert on both sides: only ours/theirs/custom strategies resolve differing values
      if (o -> k) is distinct from (t -> k) then
        if coalesce(strat ->> k, 'conflict') in ('ours', 'conflict', 'counter', 'jsonb', 'set', 'text3') then
          if coalesce(strat ->> k, 'conflict') = 'ours' then continue; end if;
          conflicts := conflicts || jsonb_build_object('col', k, 'kind', 'insert-insert', 'base', null, 'ours', o -> k, 'theirs', t -> k);
        else
          r := _gnomon.m3_value(strat ->> k, 'null'::jsonb, o -> k, t -> k, k);
          if r ? 'c' then conflicts := conflicts || (r -> 'c'); else result := jsonb_set(result, array[k], r -> 'v'); end if;
        end if;
      end if;
      continue;
    end if;
    r := _gnomon.m3_value(strat ->> k, base -> k, o -> k, t -> k, k);
    if r ? 'c' then conflicts := conflicts || (r -> 'c'); end if;
    if r ? 'v' then result := jsonb_set(result, array[k], coalesce(r -> 'v', 'null'::jsonb)); end if;
  end loop;
  action := case when result = o then 'none' else 'update' end;
end $$;

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
-- Tracked tables, parents before children by the FK graph.
create function _gnomon.fk_order() returns int[] language sql stable as $$
  with recursive e as (
    select c.conrelid as child, c.confrelid as parent from pg_constraint c
     where c.contype = 'f' and c.conrelid <> c.confrelid
       and c.conrelid in (select rel from gnomon.tracked) and c.confrelid in (select rel from gnomon.tracked)
  ), d as (
    select t.rel, 0 as depth from gnomon.tracked t
    union all
    select e.child, d.depth + 1 from e join d on d.rel = e.parent where d.depth < 50
  )
  select coalesce(array_agg(t.id order by x.depth, t.id), '{}')
    from (select rel, max(depth) depth from d group by rel) x join gnomon.tracked t on t.rel = x.rel
$$;

-- Where a merge's candidate keys start: the branch's last merge, or its fork. Not its last
-- rebase: a rebase moves the base the three-way merge compares with, but what the branch changed
-- before it is still unmerged.
create function _gnomon.merge_since(br int) returns gnomon.coord language sql stable as $$
  select bb.at from gnomon.branch_base bb where bb.branch = br and bb.reason <> 'rebase' order by bb.id desc limit 1
$$;

-- Keys a branch touched since a coordinate (every lineage write not visible at it).
create function _gnomon.touched_since(tid int, br int, since gnomon.coord) returns jsonb language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked := _gnomon.trow(tid); res jsonb;
begin
  -- (gnomon._vis(..., since) with the coordinate's epoch and xmin/xmax as integers first: most
  -- versions are past its xmax and need no xid8 conversion)
  execute format($q$select coalesce(jsonb_agg(distinct %1$s), '[]') from (
      select gn_key, gn_xoff, %4$s from %2$s where gn_branch = $1
      union all select gn_key, gn_xoff, %4$s from %3$s where gn_branch = $1) b
     where not ((b.gn_key >> 48) < $3 or ((b.gn_key >> 48) = $3
                and (((b.gn_key & 281474976710655) - b.gn_xoff) < $4
                     or (((b.gn_key & 281474976710655) - b.gn_xoff) < $5
                         and pg_visible_in_snapshot(((((b.gn_key & 281474976710655) - b.gn_xoff))::text)::xid8, ($2).snap)))))$q$,
                 _gnomon.key_sql(t, 'b'), _gnomon.obj(t, 'bv'), _gnomon.obj(t, 'bv_u'),
                 (select string_agg(quote_ident(k), ', ') from unnest(t.key_cols) k))
    into res using br, since, since.epoch, gnomon._xid(pg_snapshot_xmin(since.snap)), gnomon._xid(pg_snapshot_xmax(since.snap));
  -- reading a table's changes takes the right to read it; a table the branch did not touch
  -- takes nothing (merging a branch needs no rights on the tables it left alone)
  if jsonb_array_length(res) > 0 then perform _gnomon.require_read(t.rel); end if;
  -- a branch TRUNCATE since the base: every target row is a candidate
  if exists (select 1 from _gnomon.cleared c where c.tbl = tid and c.branch = br and not gnomon._vis(c.key, c.xoff, since)) then
    perform _gnomon.require_read(t.rel);
    select jsonb_agg(distinct x.k) into res
      from (select jsonb_array_elements(res) k union all select r.k from _gnomon.read_rows(tid, row('main', gnomon.coord_text(since))::gnomon.ref) r) x;
  end if;
  return res;
end $$;

-- Keys (of <keys>) that main changed since <since>: a version with a key at or above the
-- coordinate's xmin (a superset of the changes it did not see). One pass over the versions written
-- since, not one probe per key.
create function _gnomon.main_changed_keys(tid int, since gnomon.coord, keys jsonb) returns jsonb
language plpgsql stable as $$
declare t gnomon.tracked := _gnomon.trow(tid); res jsonb; km int8 := gnomon._kxmin(since);
begin
  execute format($q$select coalesce(jsonb_agg(c.k), '[]') from (select distinct %1$s as k from %2$s v
                     where v.gn_key >= $1 and v.gn_part >= gnomon._part($1, %3$s)) c
                    where c.k in (select e.value from jsonb_array_elements($2) e)$q$,
                 _gnomon.key_sql(t, 'v'), _gnomon.obj(t, 'v'), t.part_span)
    into res using km, keys;
  return res;
end $$;

-- A merge into main of keys main has not changed since the branch's base: the result is the
-- branch's row (none, if the branch deleted it), so it is applied straight from the branch's
-- head table, set-based, with no row images and no per-row plan (the one-sided case).
create function _gnomon.merge_fast(tid int, br int, sfx text, keys jsonb, action text) returns bigint
language plpgsql volatile as $$
declare t gnomon.tracked := _gnomon.trow(tid); cs _gnomon.col[] := _gnomon.cols((_gnomon.trow(tid)).rel);
        ng _gnomon.col[] := _gnomon.nongen(_gnomon.cols((_gnomon.trow(tid)).rel)); ks _gnomon.col[]; upd _gnomon.col[];
        q text := _gnomon.qrel(_gnomon.trow(tid)); B text := _gnomon.obj(_gnomon.trow(tid), 'b' || sfx); n bigint; ch text;
begin
  if keys is null or jsonb_array_length(keys) = 0 then return 0; end if;
  ks := _gnomon.keys(cs);
  upd := (select coalesce(array_agg(x order by x.num), '{}') from unnest(ng) x where x.ident is distinct from 'a' and not x.iskey);
  if action = 'insert' then
    execute format('insert into %1$s (%2$s) overriding system value select %3$s from jsonb_to_recordset($1) as kk(%4$s)
                      join %5$s b on b.gn_branch = $2 and %6$s where not exists (select 1 from %1$s t where %7$s)',
                   q, _gnomon.lst(ng), _gnomon.lst(ng, 'b.'), _gnomon.key_recdef(t), B, _gnomon.eqs(ks, 'b', 'kk'), _gnomon.eqs(ks, 't', 'b'))
      using keys, br;
  elsif action = 'update' then
    if cardinality(upd) = 0 then return 0; end if;
    ch := (select string_agg(_gnomon.ne(c, 't.' || c.q, 'b.' || c.q), ' OR ' order by c.num) from unnest(upd) c);
    execute format('update %1$s t set (%2$s) = row(%3$s) from jsonb_to_recordset($1) as kk(%4$s)
                      join %5$s b on b.gn_branch = $2 and %6$s where %7$s and (%8$s)',
                   q, _gnomon.lst(upd), _gnomon.lst(upd, 'b.'), _gnomon.key_recdef(t), B, _gnomon.eqs(ks, 'b', 'kk'),
                   _gnomon.eqs(ks, 't', 'b'), ch)
      using keys, br;
  else
    -- touched on the branch with no head row: the branch deleted it
    execute format('delete from %1$s t using jsonb_to_recordset($1) as kk(%2$s)
                     where %3$s and not exists (select 1 from %4$s b where b.gn_branch = $2 and %5$s)',
                   q, _gnomon.key_recdef(t), _gnomon.eqs(ks, 't', 'kk'), B, _gnomon.eqs(ks, 'b', 't'))
      using keys, br;
  end if;
  get diagnostics n = row_count;
  return n;
end $$;

-- The one-sided keys sorted, in one pass, by what the merge does with them: the branch has a head row
-- and main has none (insert), both have one (update, where a column differs), only main has one
-- (the branch deleted it). Each action then reads only its own keys.
create function _gnomon.merge_fast_split(tid int, br int, sfx text, keys jsonb,
                                         out ins jsonb, out upd jsonb, out del jsonb)
language plpgsql stable as $$
declare t gnomon.tracked := _gnomon.trow(tid); ks _gnomon.col[] := _gnomon.keys(_gnomon.cols((_gnomon.trow(tid)).rel));
begin
  if keys is null or jsonb_array_length(keys) = 0 then ins := '[]'; upd := '[]'; del := '[]'; return; end if;
  execute format($q$select coalesce(jsonb_agg(e.value) filter (where b.gn_branch is not null and t.ctid is null), '[]'),
                           coalesce(jsonb_agg(e.value) filter (where b.gn_branch is not null and t.ctid is not null), '[]'),
                           coalesce(jsonb_agg(e.value) filter (where b.gn_branch is null and t.ctid is not null), '[]')
                      from jsonb_array_elements($1) e
                      cross join lateral jsonb_to_record(e.value) as kk(%1$s)
                      left join %2$s b on b.gn_branch = $2 and %3$s
                      left join %4$s t on %5$s$q$,
                 _gnomon.key_recdef(t), _gnomon.obj(t, 'b' || sfx), _gnomon.eqs(ks, 'b', 'kk'),
                 _gnomon.qrel(t), _gnomon.eqs(ks, 't', 'kk'))
    into ins, upd, del using keys, br;
end $$;

-- Write a planned row change to a target (main or a branch). Main: set-based per batch.
create function _gnomon.apply_main(tid int, action text, rows jsonb) returns bigint
language plpgsql volatile as $$
declare t gnomon.tracked := _gnomon.trow(tid); cs _gnomon.col[] := _gnomon.cols((_gnomon.trow(tid)).rel);
        ng _gnomon.col[] := _gnomon.nongen(cs); upd _gnomon.col[]; n bigint; q text := _gnomon.qrel(_gnomon.trow(tid));
begin
  if rows is null or jsonb_array_length(rows) = 0 then return 0; end if;
  upd := (select coalesce(array_agg(x order by x.num), '{}') from unnest(ng) x where x.ident is distinct from 'a' and not x.iskey);
  if action = 'insert' then
    execute format('insert into %s (%s) overriding system value select %s from jsonb_populate_recordset(null::%s, $1) r',
                   q, _gnomon.lst(ng), _gnomon.lst(ng, 'r.'), q) using rows;
  elsif action = 'update' then
    if cardinality(upd) = 0 then return 0; end if;
    execute format('update %s t set (%s) = row(%s) from jsonb_populate_recordset(null::%s, $1) r where %s',
                   q, _gnomon.lst(upd), _gnomon.lst(upd, 'r.'), q, _gnomon.eqs(_gnomon.keys(cs), 't', 'r')) using rows;
  else
    execute format('delete from %s t using jsonb_populate_recordset(null::%s, $1) r where %s',
                   q, q, _gnomon.eqs(_gnomon.keys(cs), 't', 'r')) using rows;
  end if;
  get diagnostics n = row_count;
  return n;
end $$;

create function _gnomon.apply_branch(tid int, c _gnomon.ctx, action text, ours jsonb, result jsonb) returns void
language plpgsql volatile as $$
declare t gnomon.tracked := _gnomon.trow(tid); fn text := _gnomon.obj(_gnomon.trow(tid), 'bwi') || case when c.kind = 'scratch' then '_u' else '' end;
        q text := _gnomon.qrel(_gnomon.trow(tid));
begin
  execute format('select %s($1, jsonb_populate_record(null::%s, $2), jsonb_populate_record(null::%s, $3), $4, null)', fn, q, q)
    using case action when 'insert' then 'INSERT' when 'update' then 'UPDATE' else 'DELETE' end,
          ours, result, c;
end $$;

-- (also lets this transaction's writes reach main's tables from a session on a branch: the
-- main-write guard of the versioning triggers)
create function _gnomon.merge_token(mid bigint) returns void language sql volatile security definer
set search_path = pg_catalog, pg_temp as $$
  insert into _gnomon.merge_txn(xid, merge_id, epoch) values (pg_current_xact_id(), mid, gnomon.current_epoch())
    on conflict (xid) do update set merge_id = coalesce(merge_txn.merge_id, excluded.merge_id), epoch = excluded.epoch;
  select set_config('gnomon._main_write', '1', true);
$$;
revoke all on function _gnomon.merge_token(bigint) from public;
grant execute on function _gnomon.merge_token(bigint) to gnomon_merger;

create function _gnomon.who() returns text language sql stable as $$
  select coalesce(nullif(current_setting('role'), 'none'), session_user::text)
$$;

-- A branch's lineage: itself (read now), then each ancestor with the cutoff it is
-- read at, main last. Main's lineage is main now.
create function _gnomon.lineage(b int) returns table(lvl int, br int, cut gnomon.coord) language sql stable as $$
  select 0, b, null::gnomon.coord where b = 0
  union all
  select 0, b, null::gnomon.coord where b <> 0
  union all
  select u.o::int, u.br, (bb.lin_c)[u.o]
    from (select * from gnomon.branch_base x where x.branch = b and b <> 0 order by x.id desc limit 1) bb
    cross join lateral unnest(bb.lin_b) with ordinality u(br, o)
$$;

-- Is coordinate a no later than b (a sees nothing b does not)? For cutoffs on one branch's
-- lineage the snapshots are nested, so comparing xmax then xmin orders them.
create function _gnomon.coord_le(a gnomon.coord, b gnomon.coord) returns bool language sql immutable as $$
  select case when a is null then b is null
              when b is null then true
              else (gnomon._kxmax(a), gnomon._kxmin(a)) <= (gnomon._kxmax(b), gnomon._kxmin(b)) end
$$;

-- The merge base of two branches: their lowest common ancestor and the earlier of
-- the two cutoffs on it. A branch and its parent: the parent at the branch's cutoff (what merges
-- have always used). Two siblings: their parent at the earlier fork.
create function _gnomon.merge_base(source text, target text, out branch int, out coord gnomon.coord)
language plpgsql stable as $$
declare s int := (gnomon._branch_row(source)).id; tg int := (gnomon._branch_row(target)).id; r record;
begin
  for r in select ls.lvl, ls.br, ls.cut as scut, lt.cut as tcut
             from _gnomon.lineage(s) ls join _gnomon.lineage(tg) lt on lt.br = ls.br
            order by ls.lvl, lt.lvl limit 1 loop
    branch := r.br;
    coord := case when r.scut is null then r.tcut when r.tcut is null then r.scut
                  when _gnomon.coord_le(r.scut, r.tcut) then r.scut else r.tcut end;
  end loop;
  if branch is null then raise exception 'branches "%" and "%" share no ancestor', source, target using hint = '[gnomon:branches_share_no_ancestor]'; end if;
end $$;

-- The keys of a table that can differ between two references (the candidates a diff or a merge
-- reads; cost follows the changes).
create function _gnomon.changed_keys(tid int, base_ref gnomon.ref, ref gnomon.ref) returns jsonb language sql volatile as $$
  select _gnomon.candidate_keys(tid, base_ref, ref)
$$;

-- The base a merge of s into tg compares with. Into the parent: the parent at the
-- source's cutoff. Into any other branch (a sibling, or main past the parent): the first time,
-- the lowest common ancestor at the earlier cutoff (_gnomon.merge_base); after that, the source
-- as of what the previous merge of the pair read of it (the merge record keeps it), which both
-- sides contain. carries: the source forked later on the base than the target did, so the merge
-- also carries the base branch's changes in between (strict merges refuse that).
create function _gnomon.merge_refs(s gnomon.branch, tg gnomon.branch, exclude bigint default null,
                                   out sib bool, out base_ref gnomon.ref, out base gnomon.coord, out carries bool)
language plpgsql stable as $$
declare sb gnomon.branch_base := gnomon._base_at(s.id, null); last gnomon.merge; mb record; scut gnomon.coord;
begin
  sib := tg.id <> sb.lin_b[1]; carries := false;
  if not sib then
    base := sb.lin_c[1]; base_ref := row(tg.name, gnomon.coord_text(base))::gnomon.ref;
    return;
  end if;
  select * into last from gnomon.merge m
   where m.source = s.id and m.target = tg.id and m.status = 'applied' and m.source_at is not null and m.id is distinct from exclude
   order by m.id desc limit 1;
  if last.id is not null then
    base := last.source_at; base_ref := row(s.name, gnomon.coord_text(last.source_at))::gnomon.ref;
    return;
  end if;
  select * into mb from _gnomon.merge_base(s.name, tg.name);
  base := mb.coord;
  base_ref := row(case when mb.branch = 0 then 'main' else (select x.name from gnomon.branch x where x.id = mb.branch) end,
                  gnomon.coord_text(mb.coord))::gnomon.ref;
  scut := (select l.cut from _gnomon.lineage(s.id) l where l.br = mb.branch order by l.lvl limit 1);
  carries := scut is not null and mb.coord is not null and gnomon.coord_text(scut) <> gnomon.coord_text(mb.coord);
end $$;

-------------------------------------------------------------------------------
-- The merge engine
-------------------------------------------------------------------------------
-- Plan (and optionally apply) a merge of source into target. Shared by merge, preview,
-- incremental batches, rebase (target = the branch itself) and watch.
create function _gnomon.plan_row(br jsonb, orr jsonb, trr jsonb, strat jsonb, keycols text[], tbl text, k jsonb, resolutions jsonb,
                                  out action text, out result jsonb, out conflicts jsonb)
language plpgsql volatile as $$
declare m record; c jsonb; rs jsonb; res jsonb; unresolved jsonb := '[]';
begin
  select * into m from _gnomon.m3_row(br, orr, trr, strat, keycols);
  res := m.result;
  -- recorded resolutions (gnomon.resolve) apply when ours and theirs are unchanged
  for c in select * from jsonb_array_elements(m.conflicts) loop
    select x into rs from jsonb_array_elements(resolutions) x
     where x ->> 'tbl' = tbl and x -> 'key' = k and (x ->> 'col') is not distinct from (c ->> 'col')
       and (x -> 'ours') is not distinct from (c -> 'ours') and (x -> 'theirs') is not distinct from (c -> 'theirs')
     limit 1;
    if rs is null then
      unresolved := unresolved || c;
    elsif c ->> 'col' is null then
      res := case rs ->> 'resolution' when 'ours' then orr when 'theirs' then trr when 'base' then br else rs -> 'value' end;
    else
      res := jsonb_set(coalesce(res, orr), array[c ->> 'col'],
             coalesce(case rs ->> 'resolution' when 'ours' then c -> 'ours' when 'theirs' then c -> 'theirs'
                                               when 'base' then c -> 'base' else rs -> 'value' end, 'null'::jsonb));
    end if;
  end loop;
  if jsonb_array_length(m.conflicts) > 0 and jsonb_array_length(unresolved) = 0 then
    m.action := case when res is null and orr is null then 'none' when res is null then 'delete'
                     when orr is null then 'insert' when res = orr then 'none' else 'update' end;
  end if;
  action := m.action; result := res; conflicts := unresolved;
end $$;

-- Plan a three-way merge for a set of keys. Rows where only one side changed (the common case)
-- are decided set-based; only rows both sides changed go through the per-row merge.
create function _gnomon.plan(mid bigint, tid int, keys jsonb, base_ref gnomon.ref, ours_ref gnomon.ref, theirs_ref gnomon.ref,
                             resolutions jsonb default '[]')
returns table(k jsonb, b jsonb, o jsonb, t jsonb, action text, result jsonb, conflicts jsonb)
language plpgsql volatile as $$
declare tr gnomon.tracked := _gnomon.trow(tid);
begin
  -- the three sides grouped by key, not joined: set-returning functions carry no row estimates,
  -- and a nested loop over 50,000 keys a side was minutes where grouping is linear
  return query
    with u as (select e.value as k, 3 as side, null::jsonb as r from jsonb_array_elements(keys) e
               union all select x.k, 0, x.r from _gnomon.read_rows(tid, base_ref, keys) x
               union all select x.k, 1, x.r from _gnomon.read_rows(tid, ours_ref, keys) x
               union all select x.k, 2, x.r from _gnomon.read_rows(tid, theirs_ref, keys) x),
         j as (select u.k, (array_agg(u.r) filter (where u.side = 0))[1] as br,
                      (array_agg(u.r) filter (where u.side = 1))[1] as orr,
                      (array_agg(u.r) filter (where u.side = 2))[1] as trr
                 from u group by u.k having bool_or(u.side = 3))
    select j.k, j.br, j.orr, j.trr,
           case when j.orr is not distinct from j.br then        -- only theirs changed: take theirs
                  case when j.trr is not distinct from j.orr then 'none' when j.trr is null then 'delete'
                       when j.orr is null then 'insert' else 'update' end
                when j.trr is not distinct from j.br then 'none'   -- only ours changed: keep ours
                else (m).action end,
           case when j.orr is not distinct from j.br then j.trr
                when j.trr is not distinct from j.br then j.orr
                else (m).result end,
           case when j.orr is not distinct from j.br or j.trr is not distinct from j.br then '[]'::jsonb
                else (m).conflicts end
      from j
      left join lateral (select _gnomon.plan_row(j.br, j.orr, j.trr, tr.merge, tr.key_cols, tr.rel::text, j.k, resolutions) as m
                          where j.orr is distinct from j.br and j.trr is distinct from j.br) pr on true
     order by j.k;
end $$;

-- Resolve branch (or 'main') into (id, ctx-ref) and merge permissions.
create function _gnomon.merge_target_check(target gnomon.branch) returns void language plpgsql stable as $$
declare who text := _gnomon.who();
begin
  if target.id = 0 then
    if not pg_has_role(who, 'gnomon_merger', 'member') then
      raise exception 'merging into main requires membership in gnomon_merger' using errcode = '42501', hint = '[gnomon:merging_into_main_requires]';
    end if;
  elsif target.status <> 'open' then
    raise exception 'target branch "%" is %', target.name, target.status using hint = '[gnomon:target_branch]';
  elsif exists (select 1 from gnomon.confined c where c.role = who)
        and not exists (select 1 from gnomon.acl a where a.role = who and a.branch = target.id and a.can_write) then
    raise exception 'role % may not write branch "%"', who, target.name using errcode = '42501', hint = '[gnomon:role_may_not_write]';
  end if;
end $$;

create function gnomon.merge(
  source text, target text default null, mode text default 'atomic',
  tables regclass[] default null, keys jsonb default null, resume bigint default null, close bool default false,
  strict bool default false
) returns bigint
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare s gnomon.branch := gnomon._branch_row(source); tg gnomon.branch; sb gnomon.branch_base; base gnomon.coord;
        mid bigint; tid int; ks jsonb; p record; nconf int := 0; resol jsonb := '[]'; st_out jsonb := '{}'; stats jsonb := '{}';
        ins jsonb; upd jsonb; del jsonb; ord int[]; partial bool := tables is not null or keys is not null;
        tctx _gnomon.ctx; sctx _gnomon.ctx; resc gnomon.coord; tb gnomon.branch_base; st gnomon.stamp; refresh jsonb := '[]'; r record;
        n_ins bigint := 0; n_upd bigint := 0; n_del bigint := 0; chg jsonb; fast jsonb; tr gnomon.tracked;
        ssfx text := case when s.kind = 'scratch' then '_u' else '' end;
        mr record; pol gnomon.merge_policy; viol text[]; src_at gnomon.coord; who text := _gnomon.who();
begin

  tables := _gnomon.base_rels(tables);  if s.id = 0 then raise exception 'cannot merge main into another branch; rebase the branch instead' using hint = '[gnomon:cannot_merge_main_into]'; end if;
  if mode not in ('atomic', 'incremental') then raise exception 'mode must be atomic or incremental' using hint = '[gnomon:mode_must_atomic_incremental]'; end if;
  if mode = 'incremental' then
    raise exception 'incremental merges commit per batch: use CALL gnomon.merge_incremental(%L, %L)', source, coalesce(target, '')
      using hint = 'A function cannot commit; the procedure can.';
  end if;
  sb := gnomon._base_at(s.id, null);
  tg := case when target is null then (select b from gnomon.branch b where b.id = sb.lin_b[1]) else gnomon._branch_row(target) end;
  if tg.id = s.id then raise exception 'a branch cannot be merged into itself' using hint = '[gnomon:branch_cannot_merged_into]'; end if;
  if not gnomon._may_read_branch(s.id) then
    raise exception 'role % may not read branch "%"', who, s.name using errcode = '42501', hint = '[gnomon:branch_not_readable]';
  end if;
  -- into main without gnomon_merger: only where an auto-merge policy covers the caller
  if tg.id = 0 and not pg_has_role(who, 'gnomon_merger', 'member') then
    pol := _gnomon.policy_for(who, 0);
  end if;
  if pol.name is null then perform _gnomon.merge_target_check(tg); end if;
  -- the parent, or any other open branch (siblings, or main past the parent)
  select * into mr from _gnomon.merge_refs(s, tg, resume);
  if mr.sib and strict and mr.carries then
    raise exception 'branch "%" forked later than "%" and would carry its parent''s changes in between', s.name, tg.name
      using hint = 'Rebase the target first, or merge without strict. [gnomon:merge_carries]';
  end if;
  base := mr.base;
  if resume is not null then
    select coalesce(jsonb_agg(jsonb_build_object('tbl', c.tbl::text, 'key', c.key, 'col', c.col, 'ours', c.ours, 'theirs', c.theirs,
                                                 'resolution', c.resolution, 'value', c.value)), '[]')
      into resol from gnomon.conflict c where c.merge_id = resume and c.resolution is not null;
    mid := resume;
    delete from gnomon.conflict where merge_id = resume;
    update gnomon.merge set status = 'planned' where id = mid;
  else
    insert into gnomon.merge(source, target, base, mode, filter)
    values (s.id, tg.id, base, mode, jsonb_build_object('tables', tables, 'keys', keys)) returning id into mid;
  end if;
  if tg.id = 0 then perform _gnomon.merge_token(mid); end if;
  tctx := gnomon._ctx_compute(case when tg.id = 0 then '' else tg.name end, null, null);
  sctx := gnomon._ctx_compute(s.name, null, null);
  src_at := gnomon.coordinate();   -- what this merge reads of the source (the base of the pair's next merge)
  -- a branch on a schema version: its DDL reaches main first, before any data is planned
  if s.schema_version is not null then
    if not _gnomon.merge_schema_gate(s, tg, mid) then
      update gnomon.merge set status = 'conflicts', stats = jsonb_build_object('conflicts', (select count(*) from gnomon.conflict where merge_id = mid)) where id = mid;
      return mid;
    end if;
    s := gnomon._branch_row(source);
  end if;

  create temp table if not exists gnomon_mplan (m_id bigint, t_id int, k jsonb, b jsonb, o jsonb, t jsonb, action text, result jsonb) on commit drop;
  delete from gnomon_mplan where gnomon_mplan.m_id = mid;
  create temp table if not exists gnomon_mfast (m_id bigint, t_id int, ins jsonb, upd jsonb, del jsonb) on commit drop;
  delete from gnomon_mfast where gnomon_mfast.m_id = mid;
  ord := _gnomon.fk_order();
  foreach tid in array ord loop
    if tables is not null and (select rel from gnomon.tracked where id = tid) <> all(tables) then continue; end if;
    if mr.sib then
      ks := _gnomon.changed_keys(tid, mr.base_ref, row(s.name, null)::gnomon.ref);
    else
      ks := _gnomon.touched_since(tid, s.id, coalesce(_gnomon.merge_since(s.id), base));
    end if;
    if keys is not null then
      ks := (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(ks) x
              where x in (select y from jsonb_array_elements(case when jsonb_typeof(keys) = 'object'
                                                                  then coalesce(keys -> (select rel::text from gnomon.tracked where id = tid), '[]')
                                                                  else keys end) y));
    end if;
    if jsonb_array_length(ks) = 0 then continue; end if;
    if tg.id = 0 then  -- lock target rows in a fixed key order before reading ours
      execute format('select 1 from %s t join jsonb_to_recordset($1) as kk(%s) on %s order by %s for update of t',
                     (select _gnomon.qrel(x) from gnomon.tracked x where x.id = tid),
                     _gnomon.key_recdef(_gnomon.trow(tid)),
                     (select string_agg(format('t.%1$I = kk.%1$I', c), ' and ') from unnest((select key_cols from gnomon.tracked where id = tid)) c),
                     (select string_agg(format('t.%I', c), ', ') from unnest((select key_cols from gnomon.tracked where id = tid)) c))
        using ks;
      -- keys main has not changed since the base take the branch's row: applied set-based from
      -- the branch's head table; only the others are planned three-way (after the lock, so the
      -- check sees every change committed before it)
      tr := _gnomon.trow(tid);
      -- a policy merge plans every key three-way (what it checks is what it applies), with the
      -- branch's keys locked against its own writers meanwhile
      if pol.name is not null then
        execute format('select 1 from %s k join jsonb_to_recordset($1) as kk(%s) on %s where k.gn_branch = $2 for share of k',
                       _gnomon.obj(tr, 'bk' || ssfx), _gnomon.key_recdef(tr),
                       (select string_agg(format('k.%1$I = kk.%1$I', c), ' and ') from unnest(tr.key_cols) c)) using ks, s.id;
      end if;
      if tr.mode = 'known' and not tr.wide_key and not mr.sib and pol.name is null
         and not exists (select 1 from _gnomon.cleared c where c.tbl = tid and c.branch = s.id) then
        chg := _gnomon.main_changed_keys(tid, base, ks);
        fast := case when jsonb_array_length(chg) = 0 then ks
                     else (select coalesce(jsonb_agg(x.v), '[]') from (select e.value as v from jsonb_array_elements(ks) e
                                                                       except select e.value from jsonb_array_elements(chg) e) x) end;
        insert into gnomon_mfast select mid, tid, x.ins, x.upd, x.del from _gnomon.merge_fast_split(tid, s.id, ssfx, fast) x;
        ks := chg;
      end if;
    end if;
    if jsonb_array_length(ks) = 0 then continue; end if;
    create temp table if not exists gnomon_pl (k jsonb, b jsonb, o jsonb, t jsonb, action text, result jsonb, conflicts jsonb) on commit drop;
    truncate gnomon_pl;
    insert into gnomon_pl
    select * from _gnomon.plan(mid, tid, ks, mr.base_ref,
                               row(tg.name, null)::gnomon.ref, row(s.name, null)::gnomon.ref, resol);
    insert into gnomon.conflict(merge_id, tbl, key, col, kind, path, base, ours, theirs)
    select mid, (select rel from gnomon.tracked where id = tid), gp.k, c ->> 'col', c ->> 'kind',
           case when c ? 'path' then array(select jsonb_array_elements_text(c -> 'path')) end,
           coalesce(c -> 'base', case when c ->> 'col' is null then gp.b end),
           coalesce(c -> 'ours', case when c ->> 'col' is null then gp.o end),
           coalesce(c -> 'theirs', case when c ->> 'col' is null then gp.t end)
      from gnomon_pl gp cross join lateral jsonb_array_elements(gp.conflicts) c;
    get diagnostics n_ins = row_count;
    nconf := nconf + n_ins; n_ins := 0;
    insert into gnomon_mplan
    select mid, tid, gp.k, gp.b, gp.o, gp.t, gp.action, gp.result from gnomon_pl gp
     where jsonb_array_length(gp.conflicts) = 0 and gp.action <> 'none';
    refresh := refresh || coalesce((select jsonb_agg(jsonb_build_object('tid', tid, 'theirs', gp.t, 'result', gp.result))
                                      from gnomon_pl gp where gp.result is distinct from gp.t and jsonb_array_length(gp.conflicts) = 0), '[]');
  end loop;

  if nconf > 0 then
    update gnomon.merge set status = 'conflicts', stats = jsonb_build_object('conflicts', nconf) where id = mid;
    drop table if exists gnomon_mplan;
    drop table if exists gnomon_mfast;
    return mid;
  end if;

  -- stale reads (C module read-set tracking): keys the branch read that the target changed since its base
  insert into gnomon.warning(branch, tbl, key, col, kind, detail)
  select s.id, sr.tbl, sr.key, '', 'stale-read', jsonb_build_object('read_at', sr.read_at, 'merge', mid)
    from gnomon.stale_reads(s.name) sr
  on conflict (branch, tbl, key, col) do update set kind = excluded.kind, detail = excluded.detail, at = now();
  get diagnostics n_ins = row_count;
  if n_ins > 0 and gnomon._cfg('stale_reads') = 'refuse' then
    raise exception 'merge of "%" refused: % key(s) were read on the branch and changed on the target since', s.name, n_ins
      using errcode = '40001', hint = 'See gnomon.warning (kind stale-read); rebase and re-run, or set gnomon.setting stale_reads to warn.';
  end if;
  stats := jsonb_build_object('stale_reads', n_ins);
  n_ins := 0;
  -- an auto-merge policy: every rule holds for the plan about to be applied, or nothing is
  if pol.name is not null then
    viol := _gnomon.policy_violations(pol, s.id,
              (select coalesce(jsonb_agg(jsonb_build_object('tbl', (select rel::text from gnomon.tracked where id = x.t_id),
                                                            'action', x.action, 'o', x.o, 'result', x.result)), '[]')
                 from gnomon_mplan x where x.m_id = mid));
    if cardinality(viol) > 0 then
      raise exception 'merge of "%" refused by policy %: %', s.name, pol.name, array_to_string(viol, '; ')
        using errcode = '42501', hint = 'See gnomon.policy_eval(branch). [gnomon:policy_refused]';
    end if;
    stats := stats || jsonb_build_object('policy', pol.name);
    insert into gnomon.review(cr, reviewer, verdict, body, coord)
    select x.id, ('policy:' || pol.name)::name, 'approve', 'auto-merge policy ' || pol.name, gnomon._coordinate_self()
      from gnomon.change_request x where x.branch = s.id and x.status in ('open', 'approved');
  end if;
  update gnomon.merge set status = 'applying' where id = mid;
  -- inserts and updates parents first, deletes children first
  foreach tid in array ord loop
    if tg.id = 0 then
      n_ins := n_ins + _gnomon.merge_fast(tid, s.id, ssfx, (select f.ins from gnomon_mfast f where f.m_id = mid and f.t_id = tid), 'insert');
      n_upd := n_upd + _gnomon.merge_fast(tid, s.id, ssfx, (select f.upd from gnomon_mfast f where f.m_id = mid and f.t_id = tid), 'update');
      select jsonb_agg(x.result) filter (where x.action = 'insert'), jsonb_agg(x.result) filter (where x.action = 'update')
        into ins, upd from gnomon_mplan x where x.m_id = mid and x.t_id = tid;
      n_ins := n_ins + _gnomon.apply_main(tid, 'insert', ins);
      n_upd := n_upd + _gnomon.apply_main(tid, 'update', upd);
    else
      for r in select * from gnomon_mplan x where x.m_id = mid and x.t_id = tid and x.action in ('insert', 'update') order by x.k loop
        perform _gnomon.apply_branch(tid, tctx, r.action, r.o, r.result);
        if r.action = 'insert' then n_ins := n_ins + 1; else n_upd := n_upd + 1; end if;
      end loop;
    end if;
  end loop;
  foreach tid in array (select array_agg(x order by o desc) from unnest(ord) with ordinality u(x, o)) loop
    if tg.id = 0 then
      n_del := n_del + _gnomon.merge_fast(tid, s.id, ssfx, (select f.del from gnomon_mfast f where f.m_id = mid and f.t_id = tid), 'delete');
      select jsonb_agg(x.o) into del from gnomon_mplan x where x.m_id = mid and x.t_id = tid and x.action = 'delete';
      n_del := n_del + _gnomon.apply_main(tid, 'delete', del);
    else
      for r in select * from gnomon_mplan x where x.m_id = mid and x.t_id = tid and x.action = 'delete' order by x.k loop
        perform _gnomon.apply_branch(tid, tctx, 'delete', r.o, null);
        n_del := n_del + 1;
      end loop;
    end if;
  end loop;
  perform gnomon._log_xact(tg.id, mid);

  -- change-request checks run inside the merge transaction against the merged state
  perform gnomon._merge_checks(mid, s.id, tg.id);

  resc := gnomon._coordinate_self();
  if not partial and not mr.sib then
    -- the source's base moves to the merge result; later merges are incremental
    st := gnomon._stamp();
    tb := gnomon._base_at(tg.id, null);
    insert into gnomon.branch_base(branch, since_key, since_xoff, at, lin_b, lin_c, reason, main_seq)
    values (s.id, st.key, st.xoff, resc,
            array[tg.id] || coalesce(case when tg.id = 0 then '{}' else tb.lin_b end, '{}'),
            array[resc] || coalesce(case when tg.id = 0 then '{}' else tb.lin_c end, '{}'), 'merge', _gnomon.main_changes());
    perform gnomon._bump();
    delete from _gnomon.read_set where branch = s.id;   -- what it read is merged: later reads start afresh
    -- the source keeps reading what was merged for keys whose merged value differs from its own
    for r in select e.value as x from jsonb_array_elements(refresh) e loop
      perform _gnomon.apply_branch((r.x ->> 'tid')::int, gnomon._ctx_compute(s.name, null, null),
              case when r.x -> 'result' = 'null'::jsonb then 'delete' when r.x -> 'theirs' = 'null'::jsonb then 'insert' else 'update' end,
              nullif(r.x -> 'theirs', 'null'::jsonb), nullif(r.x -> 'result', 'null'::jsonb));
    end loop;
  end if;
  st_out := jsonb_build_object('inserted', n_ins, 'updated', n_upd, 'deleted', n_del) || stats;
  -- indexes the schema step left for CREATE INDEX CONCURRENTLY after the merge
  if coalesce(current_setting('gnomon._deferred_indexes', true), '') not in ('', '[]') then
    st_out := st_out || jsonb_build_object('indexes_to_build', current_setting('gnomon._deferred_indexes')::jsonb);
    perform set_config('gnomon._deferred_indexes', '', true);
  end if;
  update gnomon.merge set status = 'applied', result = resc, stats = st_out, finished_at = clock_timestamp(),
         xids = array[pg_current_xact_id()], source_at = src_at where id = mid;
  if close then update gnomon.branch set status = 'merged' where id = s.id; perform gnomon._bump(); end if;
  update gnomon.change_request set status = 'merged', merge_id = mid where branch = s.id and change_request.target = tg.id and status in ('open', 'approved');
  perform gnomon._do_tick(true);
  drop table if exists gnomon_mplan;
  drop table if exists gnomon_mfast;
  return mid;
end $$;
grant execute on function gnomon.merge(text, text, text, regclass[], jsonb, bigint, bool, bool) to public;

-- Preview: the same computation, changing nothing. keys as for gnomon.merge.
create function gnomon.merge_preview(source text, target text default null, tables regclass[] default null, keys jsonb default null)
returns table(tbl regclass, key jsonb, action text, base jsonb, ours jsonb, theirs jsonb, result jsonb, conflicts jsonb)
language plpgsql volatile as $$
declare s gnomon.branch := gnomon._branch_row(source); sb gnomon.branch_base := gnomon._base_at((gnomon._branch_row(source)).id, null);
        tg gnomon.branch; tid int; ks jsonb; mr record;
begin

  tables := _gnomon.base_rels(tables);  tg := case when target is null then (select b from gnomon.branch b where b.id = sb.lin_b[1]) else gnomon._branch_row(target) end;
  select * into mr from _gnomon.merge_refs(s, tg);
  foreach tid in array _gnomon.fk_order() loop
    if tables is not null and (select rel from gnomon.tracked where id = tid) <> all(tables) then continue; end if;
    if mr.sib then
      ks := _gnomon.changed_keys(tid, mr.base_ref, row(s.name, null)::gnomon.ref);
    else
      ks := _gnomon.touched_since(tid, s.id, coalesce(_gnomon.merge_since(s.id), sb.lin_c[1]));
    end if;
    if keys is not null then
      ks := (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(ks) x
              where x in (select y from jsonb_array_elements(case when jsonb_typeof(keys) = 'object'
                                                                  then coalesce(keys -> (select rel::text from gnomon.tracked where id = tid), '[]')
                                                                  else keys end) y));
    end if;
    if jsonb_array_length(ks) = 0 then continue; end if;
    return query select (select rel from gnomon.tracked where id = tid), p.k, p.action, p.b, p.o, p.t, p.result, p.conflicts
      from _gnomon.plan(null, tid, ks, mr.base_ref, row(tg.name, null)::gnomon.ref, row(s.name, null)::gnomon.ref) p;
  end loop;
end $$;

-- Partial merge by a key predicate: the keys of tbl the branch changed for which predicate
-- (SQL over the key columns, as in a WHERE clause) holds, merged as gnomon.merge(keys => ...).
-- The predicate is evaluated here, with the caller's rights; the merge then gets only a list of keys.
create function gnomon.merge_where(source text, tbl regclass, predicate text, target text default null, preview bool default false)
returns jsonb language plpgsql volatile as $$
declare t gnomon.tracked; ks jsonb; m bigint;
begin
  tbl := _gnomon.base_rel(tbl);
  select * into t from gnomon.tracked where rel = tbl;
  if t.id is null then raise exception '% is not tracked', tbl using hint = '[gnomon:not_tracked]'; end if;
  ks := (select coalesce(jsonb_agg(distinct d.key), '[]') from gnomon.diff(source, null, array[tbl]) d);
  execute format('select coalesce(jsonb_agg(gn_k), ''[]'') from jsonb_array_elements($1) gn_k, jsonb_populate_record(null::%s, gn_k) as %I where (%s)',
                 tbl, t.relname, predicate) into ks using ks;
  if preview then
    return (select coalesce(jsonb_agg(to_jsonb(p)), '[]') from gnomon.merge_preview(source, target, array[tbl], ks) p);
  end if;
  m := gnomon.merge(source, target, 'atomic', array[tbl], ks);
  return jsonb_build_object('merge', m, 'keys', ks);
end $$;

-- Who may settle a conflict: whoever may finish its merge (the target check gnomon.merge makes,
-- and the source readable), or for a rebase conflict whoever may write the branch. The conflict
-- table is gnomon's own, so resolve and resolve_all write it with gnomon's rights after this.
create function _gnomon.resolve_check(merge_id bigint, branch int) returns void language plpgsql stable
set search_path = pg_catalog, pg_temp as $$
declare m gnomon.merge; b gnomon.branch;
begin
  if merge_id is not null then
    select * into m from gnomon.merge x where x.id = resolve_check.merge_id;
    if m.id is null then raise exception 'no merge %', merge_id using hint = '[gnomon:no_merge]'; end if;
    perform _gnomon.merge_target_check((select x from gnomon.branch x where x.id = m.target));
    if not gnomon._may_read_branch(m.source) then
      raise exception 'role % may not read branch "%"', _gnomon.who(), (select x.name from gnomon.branch x where x.id = m.source)
        using errcode = '42501', hint = '[gnomon:branch_not_readable]';
    end if;
  else
    select * into b from gnomon.branch x where x.id = resolve_check.branch;
    if b.id is null or not gnomon._may_write(b) then
      raise exception 'role % may not write branch "%"', _gnomon.who(), coalesce(b.name, branch::text)
        using errcode = '42501', hint = '[gnomon:role_may_not_write]';
    end if;
  end if;
end $$;
revoke all on function _gnomon.resolve_check(bigint, int) from public;

create function gnomon.resolve(conflict_id bigint, choice text, value jsonb default null) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare c gnomon.conflict;
begin
  if choice not in ('ours', 'theirs', 'base', 'value') then raise exception 'choice must be ours, theirs, base or value' using hint = '[gnomon:choice_must_ours_theirs]'; end if;
  select * into c from gnomon.conflict x where x.id = conflict_id;
  if c.id is null then raise exception 'no conflict %', conflict_id using hint = '[gnomon:no_conflict]'; end if;
  perform _gnomon.resolve_check(c.merge_id, c.branch);
  update gnomon.conflict set resolution = choice, value = resolve.value, resolved_by = _gnomon.who()::name, resolved_at = now()
   where id = conflict_id;
end $$;

create function gnomon.resolve_all(merge_id bigint, choice text) returns int
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare n int;
begin
  if choice not in ('ours', 'theirs', 'base') then raise exception 'choice must be ours, theirs or base' using hint = '[gnomon:choice_must_ours_theirs]'; end if;
  perform _gnomon.resolve_check(resolve_all.merge_id, null);
  update gnomon.conflict set resolution = choice, resolved_by = _gnomon.who()::name, resolved_at = now()
   where conflict.merge_id = resolve_all.merge_id and resolution is null;
  get diagnostics n = row_count;
  return n;
end $$;

-- Incremental mode: a commit per batch. Readers can see a partly applied merge, and a
-- cancel or a crash resumes from the merge record (CALL gnomon.merge_incremental(source,
-- resume => id)). The procedure only commits; the work is done by the definer functions below,
-- with the rights and checks of gnomon.merge(), and the merge record holds its state:
--   1. upsert: table by table, parents first, keys in order, a batch at a time: the batch's
--      target rows are locked, then it is planned three-way, then applied, only if it has no
--      conflicts (a batch is applied once: planning an applied key again would apply a counter
--      delta twice). Its inserts and updates are applied now; its deletes wait.
--   2. delete: the waiting deletes, children first, each batch locked and planned again (they
--      were never applied, so planning them twice is safe) and applied.
--   3. the checks of change requests on the merged state, then the source's base moves.
-- The approval of a change request and stale reads are checked before anything is applied.
-- Conflicts stop it with nothing of their batch applied: resolve them and resume.
create function gnomon._minc_auth(mid bigint, lck bool default false) returns gnomon.merge
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare m gnomon.merge;
begin
  if lck then select * into m from gnomon.merge where id = mid for update;
  else select * into m from gnomon.merge where id = mid; end if;
  if m.id is null or m.mode <> 'incremental' then raise exception 'merge % is not an incremental merge', mid using hint = '[gnomon:merge_not_incremental_merge]'; end if;
  perform _gnomon.merge_target_check((select b from gnomon.branch b where b.id = m.target));
  return m;
end $$;

create function gnomon._minc_start(source text, target text) returns bigint
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare s gnomon.branch := gnomon._branch_row(source); sb gnomon.branch_base; tg gnomon.branch; mid bigint; n bigint;
begin
  if s.id = 0 then raise exception 'cannot merge main into another branch; rebase the branch instead' using hint = '[gnomon:cannot_merge_main_into]'; end if;
  sb := gnomon._base_at(s.id, null);
  tg := case when coalesce(target, '') = '' then (select b from gnomon.branch b where b.id = sb.lin_b[1]) else gnomon._branch_row(target) end;
  if tg.id <> sb.lin_b[1] then
    raise exception 'branch "%" can be merged into its parent "%" only', s.name, (select name from gnomon.branch where id = sb.lin_b[1])
      using hint = 'Merge into the parent first, or rebase. [gnomon:branch_can_merged_into]';
  end if;
  perform _gnomon.merge_target_check(tg);
  perform gnomon._merge_gate(s.id, tg.id);
  insert into gnomon.merge(source, target, base, mode, status, stats)
  values (s.id, tg.id, sb.lin_c[1], 'incremental', 'applying', jsonb_build_object('phase', 'upsert', 'pos', 1, 'applied', 0))
  returning id into mid;
  insert into gnomon.warning(branch, tbl, key, col, kind, detail)
  select s.id, sr.tbl, sr.key, '', 'stale-read', jsonb_build_object('read_at', sr.read_at, 'merge', mid)
    from gnomon.stale_reads(s.name) sr
  on conflict (branch, tbl, key, col) do update set kind = excluded.kind, detail = excluded.detail, at = now();
  get diagnostics n = row_count;
  if n > 0 and gnomon._cfg('stale_reads') = 'refuse' then
    raise exception 'merge of "%" refused: % key(s) were read on the branch and changed on the target since', s.name, n
      using errcode = '40001', hint = 'See gnomon.warning (kind stale-read); rebase and re-run, or set gnomon.setting stale_reads to warn.';
  end if;
  update gnomon.merge set stats = stats || jsonb_build_object('stale_reads', n) where id = mid;
  -- a branch on a schema version: the DDL and the values commit first, with the start
  if s.schema_version is not null and not _gnomon.merge_schema_gate(s, tg, mid) then
    update gnomon.merge set status = 'conflicts', stats = stats || jsonb_build_object('conflicts', (select count(*) from gnomon.conflict where merge_id = mid)) where id = mid;
    raise notice 'merge % stopped at schema conflicts (gnomon.conflict, kind schema)', mid;
    return null;
  end if;
  return mid;
end $$;

-- Resume: resolutions recorded since the stop are kept for the rest of the merge. Returns null
-- when the merge is already applied.
create function gnomon._minc_resume(mid bigint, source text) returns bigint
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare m gnomon.merge := gnomon._minc_auth(mid, true); resol jsonb; ord int[] := _gnomon.fk_order(); ks jsonb;
begin
  if m.source <> (gnomon._branch_row(source)).id then raise exception 'merge % is not a merge of branch "%"', mid, source using hint = '[gnomon:merge_not_merge_branch]'; end if;
  if m.status = 'applied' then return null; end if;
  if m.status not in ('applying', 'conflicts', 'failed') then raise exception 'merge % is %', mid, m.status using hint = '[gnomon:merge]'; end if;
  perform gnomon._merge_gate(m.source, m.target);
  select coalesce(jsonb_agg(jsonb_build_object('tbl', c.tbl::text, 'key', c.key, 'col', c.col, 'ours', c.ours, 'theirs', c.theirs,
                                               'resolution', c.resolution, 'value', c.value)), '[]')
    into resol from gnomon.conflict c where c.merge_id = mid and c.resolution is not null;
  delete from gnomon.conflict where merge_id = mid;
  if not m.stats ? 'phase' then
    -- started by an earlier gnomon (stats tid and off): its position as a key in this one's order
    ks := (select coalesce(jsonb_agg(x order by x), '[]') from jsonb_array_elements(_gnomon.touched_since((m.stats ->> 'tid')::int, m.source, coalesce(_gnomon.merge_since(m.source), m.base))) x);
    m.stats := m.stats || jsonb_build_object('phase', 'upsert', 'pos', coalesce(array_position(ord, (m.stats ->> 'tid')::int), 1),
                                             'last', case when coalesce((m.stats ->> 'off')::int, 0) > 0 then ks -> ((m.stats ->> 'off')::int - 1) end);
  end if;
  update gnomon.merge set status = 'applying',
         stats = m.stats || jsonb_build_object('resolutions', coalesce(m.stats -> 'resolutions', '[]') || resol)
   where id = mid;
  return mid;
end $$;

-- The tables in the current phase's order, and the current table.
create function gnomon._minc_tables(m gnomon.merge) returns int[] language sql stable as $$
  select case when m.stats ->> 'phase' = 'delete'
              then (select array_agg(x order by o desc) from unnest(_gnomon.fk_order()) with ordinality u(x, o))
              else _gnomon.fk_order() end
$$;

-- The current table's keys still to do, in order: touched by the source since the base (upsert),
-- or waiting to be deleted (delete).
create function gnomon._minc_keys(mid bigint) returns jsonb
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare m gnomon.merge := gnomon._minc_auth(mid); t_id int; lastk jsonb;
begin
  if m.stats ->> 'phase' not in ('upsert', 'delete') then return '[]'; end if;
  t_id := (gnomon._minc_tables(m))[(m.stats ->> 'pos')::int];
  if t_id is null then return '[]'; end if;
  lastk := m.stats -> 'last';
  if m.stats ->> 'phase' = 'upsert' then
    return (select coalesce(jsonb_agg(x order by x), '[]') from jsonb_array_elements(_gnomon.touched_since(t_id, m.source, coalesce(_gnomon.merge_since(m.source), m.base))) x
             where lastk is null or x > lastk);
  end if;
  return (select coalesce(jsonb_agg(p.k order by p.k), '[]') from _gnomon.merge_pending p
           where p.merge_id = mid and p.tid = t_id and (lastk is null or p.k > lastk));
end $$;

-- One batch of the current table: the keys given after the merge's position, in order. Returns
-- 'conflicts' (nothing applied) or 'ok'.
create function gnomon._minc_step(mid bigint, keys jsonb) returns text
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare m gnomon.merge := gnomon._minc_auth(mid, true); tabs int[]; t_id int; ks jsonb; lastk jsonb := m.stats -> 'last';
        tg gnomon.branch; s gnomon.branch; tr gnomon.tracked; tctx _gnomon.ctx; sctx _gnomon.ctx; nconf int; n bigint := 0;
        ups bool := m.stats ->> 'phase' = 'upsert'; r record; ins jsonb; upd jsonb; del jsonb;
begin
  if m.status <> 'applying' then raise exception 'merge % is %', mid, m.status using hint = '[gnomon:merge]'; end if;
  tabs := gnomon._minc_tables(m);
  t_id := tabs[(m.stats ->> 'pos')::int];
  -- only keys after the position: a batch is never applied twice
  ks := (select coalesce(jsonb_agg(x order by x), '[]') from (select distinct x from jsonb_array_elements(keys) x
                                                              where lastk is null or x > lastk) y);
  if t_id is null or jsonb_array_length(ks) = 0 then return 'ok'; end if;
  tr := _gnomon.trow(t_id);
  select * into tg from gnomon.branch where id = m.target;
  select * into s from gnomon.branch where id = m.source;
  tctx := gnomon._ctx_compute(case when tg.id = 0 then '' else tg.name end, null, null);
  if tg.id = 0 then
    perform _gnomon.merge_token(mid);
    -- lock the target rows in key order before reading ours
    execute format('select 1 from %s t join jsonb_to_recordset($1) as kk(%s) on %s order by %s for update of t',
                   _gnomon.qrel(tr), _gnomon.key_recdef(tr),
                   (select string_agg(format('t.%1$I = kk.%1$I', c), ' and ') from unnest(tr.key_cols) c),
                   (select string_agg(format('t.%I', c), ', ') from unnest(tr.key_cols) c))
      using ks;
  end if;
  create temp table if not exists gnomon_ipl (k jsonb, b jsonb, o jsonb, t jsonb, action text, result jsonb, conflicts jsonb) on commit drop;
  truncate gnomon_ipl;
  insert into gnomon_ipl
  select * from _gnomon.plan(mid, t_id, ks, row(tg.name, gnomon.coord_text(m.base))::gnomon.ref,
                             row(tg.name, null)::gnomon.ref, row(s.name, null)::gnomon.ref, coalesce(m.stats -> 'resolutions', '[]'));
  insert into gnomon.conflict(merge_id, tbl, key, col, kind, path, base, ours, theirs)
  select mid, tr.rel, gp.k, c ->> 'col', c ->> 'kind',
         case when c ? 'path' then array(select jsonb_array_elements_text(c -> 'path')) end,
         coalesce(c -> 'base', case when c ->> 'col' is null then gp.b end),
         coalesce(c -> 'ours', case when c ->> 'col' is null then gp.o end),
         coalesce(c -> 'theirs', case when c ->> 'col' is null then gp.t end)
    from gnomon_ipl gp cross join lateral jsonb_array_elements(gp.conflicts) c;
  get diagnostics nconf = row_count;
  if nconf > 0 then
    update gnomon.merge set status = 'conflicts', stats = stats || jsonb_build_object('conflicts', nconf) where id = mid;
    return 'conflicts';
  end if;
  if ups then
    -- deletes wait for the delete phase (children first)
    insert into _gnomon.merge_pending(merge_id, tid, k) select mid, t_id, gp.k from gnomon_ipl gp where gp.action = 'delete'
      on conflict do nothing;
  end if;
  if tg.id = 0 then
    select jsonb_agg(x.result) filter (where x.action = 'insert'), jsonb_agg(x.result) filter (where x.action = 'update'),
           jsonb_agg(x.o) filter (where x.action = 'delete')
      into ins, upd, del from gnomon_ipl x;
    n := n + _gnomon.apply_main(t_id, 'insert', ins) + _gnomon.apply_main(t_id, 'update', upd);
    if not ups then n := n + _gnomon.apply_main(t_id, 'delete', del); end if;
  else
    for r in select * from gnomon_ipl x where x.action in ('insert', 'update') or (not ups and x.action = 'delete') order by x.k loop
      perform _gnomon.apply_branch(t_id, tctx, r.action, r.o, r.result);
      n := n + 1;
    end loop;
  end if;
  -- the source keeps reading what was merged where the merged value differs from its own
  sctx := gnomon._ctx_compute(s.name, null, null);
  for r in select * from gnomon_ipl gp where gp.result is distinct from gp.t and gp.action <> 'none'
                                          and (gp.action = 'delete') = not ups order by gp.k loop
    perform _gnomon.apply_branch(t_id, sctx, case when r.result is null then 'delete' when r.t is null then 'insert' else 'update' end,
                                 r.t, r.result);
  end loop;
  if not ups then
    delete from _gnomon.merge_pending p where p.merge_id = mid and p.tid = t_id and p.k in (select x from jsonb_array_elements(ks) x);
  end if;
  perform gnomon._log_xact(tg.id, mid);
  update gnomon.merge set stats = stats || jsonb_build_object('last', ks -> (jsonb_array_length(ks) - 1),
                                                              'applied', coalesce((stats ->> 'applied')::bigint, 0) + n),
                          xids = xids || pg_current_xact_id()
   where id = mid;
  return 'ok';
end $$;

-- On to the next table, or the next phase. False when both phases are done.
create function gnomon._minc_next(mid bigint) returns bool
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare m gnomon.merge := gnomon._minc_auth(mid, true); pos int := (m.stats ->> 'pos')::int + 1; ph text := m.stats ->> 'phase';
begin
  if ph not in ('upsert', 'delete') then return false; end if;
  if pos > cardinality(_gnomon.fk_order()) then
    pos := 1; ph := case when ph = 'upsert' then 'delete' else 'done' end;
  end if;
  update gnomon.merge set stats = (stats - 'last') || jsonb_build_object('phase', ph, 'pos', pos) where id = mid;
  return ph <> 'done';
end $$;

-- The checks on the merged state and the base move: the end of the merge.
create function gnomon._minc_finish(mid bigint) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare m gnomon.merge := gnomon._minc_auth(mid, true); resc gnomon.coord; st gnomon.stamp; tg gnomon.branch;
begin
  if m.stats ->> 'phase' <> 'done' then raise exception 'merge % is not fully applied', mid using hint = '[gnomon:merge_not_fully_applied]'; end if;
  select * into tg from gnomon.branch where id = m.target;
  if tg.id = 0 then perform _gnomon.merge_token(mid); end if;
  perform gnomon._merge_checks(mid, m.source, m.target);
  resc := gnomon._coordinate_self();
  st := gnomon._stamp();
  insert into gnomon.branch_base(branch, since_key, since_xoff, at, lin_b, lin_c, reason, main_seq)
  select m.source, st.key, st.xoff, resc, array[tg.id] || case when tg.id = 0 then '{}'::int[] else tb.lin_b end,
         array[resc] || case when tg.id = 0 then '{}'::gnomon.coord[] else tb.lin_c end, 'merge', _gnomon.main_changes()
    from (select (gnomon._base_at(tg.id, null)).*) tb;
  perform gnomon._bump();
  delete from _gnomon.merge_pending where merge_id = mid;
  delete from _gnomon.read_set where branch = m.source;
  update gnomon.merge set status = 'applied', result = resc, finished_at = clock_timestamp(),
         stats = stats - 'resolutions' - 'last', xids = xids || pg_current_xact_id() where id = mid;
  update gnomon.change_request set status = 'merged', merge_id = mid where branch = m.source and status in ('open', 'approved');
  perform gnomon._do_tick(true);
end $$;

-- A merge whose checks failed after its batches were applied: applied in part, resumable once
-- the target is fixed (the checks run again), or revertible with gnomon.undo_merge.
create function gnomon._minc_failed(mid bigint, detail text) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform gnomon._minc_auth(mid, true);
  update gnomon.merge set status = 'failed', stats = stats || jsonb_build_object('checks', detail) where id = mid;
end $$;

create procedure gnomon.merge_incremental(source text, target text default null, batch int default null, resume bigint default null)
language plpgsql as $$
declare mid bigint; ks jsonb; n int; i int; chunk jsonb; bsz int := coalesce(batch, gnomon._cfg('merge_batch')::int);
        failed text; fstate text;
begin
  if bsz is null or bsz < 1 then raise exception 'batch must be at least 1' using hint = '[gnomon:batch_must_least]'; end if;
  if resume is null then mid := gnomon._minc_start(source, target); else mid := gnomon._minc_resume(resume, source); end if;
  commit;
  if mid is null then return; end if;   -- already applied
  loop
    ks := gnomon._minc_keys(mid);
    n := jsonb_array_length(ks); i := 0;
    while i < n loop
      chunk := (select jsonb_agg(x order by o) from jsonb_array_elements(ks) with ordinality e(x, o) where o > i and o <= i + bsz);
      if gnomon._minc_step(mid, chunk) = 'conflicts' then
        commit;
        raise notice 'merge % stopped at conflicts: resolve them (gnomon.conflict), then CALL gnomon.merge_incremental(%L, resume => %)',
          mid, source, mid;
        return;
      end if;
      commit;
      i := i + bsz;
    end loop;
    exit when not gnomon._minc_next(mid);
    commit;
  end loop;
  commit;
  begin
    perform gnomon._minc_finish(mid);
  exception when others then
    failed := regexp_replace(sqlerrm, '^merge [0-9]+ rolled back: ', ''); fstate := sqlstate;
  end;
  if failed is not null then
    perform gnomon._minc_failed(mid, failed);
    commit;
    raise exception 'merge % stopped after its batches were applied: %', mid, failed using errcode = fstate,
      hint = format('Fix the target and resume with CALL gnomon.merge_incremental(%L, resume => %s), or revert with gnomon.undo_merge(%s).', source, mid, mid);
  end if;
  commit;
end $$;

-------------------------------------------------------------------------------
-- Rebase: carry a branch onto its parent's current state
-------------------------------------------------------------------------------
-- dry_run: what a rebase would merge and which conflicts it would record, with
-- nothing changed.
create function gnomon.rebase(branch text, at text default null, dry_run bool default false) returns jsonb
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare s gnomon.branch := gnomon._branch_row(branch); sb gnomon.branch_base; p gnomon.branch; oldc gnomon.coord; newc gnomon.coord;
        tid int; ks jsonb; pl record; sctx _gnomon.ctx; nconf int := 0; nmerged int := 0; st gnomon.stamp; pb gnomon.branch_base; res jsonb;
begin
  if dry_run then
    begin
      res := gnomon.rebase(branch, at, false);
      raise sqlstate 'GNDRY';
    exception when sqlstate 'GNDRY' then
      return res || jsonb_build_object('dry_run', true);
    end;
  end if;
  if s.id = 0 then raise exception 'main has no base' using hint = '[gnomon:main_no_base]'; end if;
  if not gnomon._may_write(s) then
    raise exception 'role % may not rebase branch "%"', _gnomon.who(), s.name using errcode = '42501', hint = '[gnomon:role_may_not_rebase]';
  end if;
  sb := gnomon._base_at(s.id, null);
  p := (select b from gnomon.branch b where b.id = sb.lin_b[1]);
  oldc := sb.lin_c[1];
  newc := coalesce(gnomon.resolve_coord(at), gnomon.coordinate());
  sctx := gnomon._ctx_compute(s.name, null, null);
  delete from gnomon.conflict c where c.branch = s.id and c.merge_id is null and c.resolution is null;
  foreach tid in array _gnomon.fk_order() loop
    execute format('select coalesce(jsonb_agg(%s), ''[]'') from (select * from %s where gn_branch = $1 union all select * from %s where gn_branch = $1) k',
                   _gnomon.key_sql(_gnomon.trow(tid), 'k'), _gnomon.obj(_gnomon.trow(tid), 'bk'), _gnomon.obj(_gnomon.trow(tid), 'bk_u'))
      into ks using s.id;
    if jsonb_array_length(ks) = 0 then continue; end if;
    for pl in select * from _gnomon.plan(null, tid, ks, row(p.name, gnomon.coord_text(oldc))::gnomon.ref,
                                          row(s.name, null)::gnomon.ref, row(p.name, gnomon.coord_text(newc))::gnomon.ref) loop
      if pl.b is not distinct from pl.t then continue; end if;   -- only the parent changed nothing here
      if jsonb_array_length(pl.conflicts) > 0 then
        insert into gnomon.conflict(branch, tbl, key, col, kind, base, ours, theirs)
        select s.id, (select rel from gnomon.tracked where id = tid), pl.k, c ->> 'col', c ->> 'kind', c -> 'base', c -> 'ours', c -> 'theirs'
          from jsonb_array_elements(pl.conflicts) c;
        nconf := nconf + 1;
      elsif pl.action <> 'none' then
        perform _gnomon.apply_branch(tid, sctx, pl.action, pl.o, pl.result);
        nmerged := nmerged + 1;
      end if;
    end loop;
  end loop;
  st := gnomon._stamp();
  pb := gnomon._base_at(p.id, newc);
  insert into gnomon.branch_base(branch, since_key, since_xoff, at, lin_b, lin_c, reason, main_seq)
  values (s.id, st.key, st.xoff, newc,
          array[p.id] || case when p.id = 0 then '{}'::int[] else pb.lin_b end,
          array[newc] || case when p.id = 0 then '{}'::gnomon.coord[] else pb.lin_c end, 'rebase', _gnomon.main_changes());
  delete from gnomon.warning where warning.branch = s.id;
  perform gnomon._bump();
  perform gnomon._do_tick(true);
  return jsonb_build_object('merged', nmerged, 'conflicts', nconf, 'base', gnomon.coord_text(newc));
end $$;
grant execute on function gnomon.rebase(text, text, bool) to public;

-------------------------------------------------------------------------------
-- Early warning: main's changes since the last watch, tested against branches
-------------------------------------------------------------------------------
create function gnomon.watch() returns int language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp as $$
declare w gnomon.coord; nowc gnomon.coord := gnomon.coordinate(); t gnomon.tracked; pr record; pl record; n int := 0;
        ks jsonb; br gnomon.branch; bb gnomon.branch_base; nseen int8 := 0; nv int8; thr int8; cnt int8; r record;
begin
  w := (select gnomon.coord(value) from gnomon.setting where name = 'watch_coord');
  if w is null then
    insert into gnomon.setting(name, value, doc) values ('watch_coord', gnomon.coord_text(nowc), 'Last coordinate gnomon.watch() examined.')
      on conflict (name) do update set value = excluded.value;
    return 0;
  end if;
  for t in select * from gnomon.tracked loop
    -- main's versions in the window: for the change counter (and whether anything changed at all)
    execute format('select count(*) from %s v where v.gn_key >= $1 and (v.gn_flags & 48) = 0 and gnomon._vis(v.gn_key, v.gn_xoff, $2) and not gnomon._vis(v.gn_key, v.gn_xoff, $3)',
                   _gnomon.obj(t, 'v')) into nv using gnomon._kxmin(w), nowc, w;
    nseen := nseen + nv;
    for pr in execute format($q$
        select k.gn_branch as br, jsonb_agg(distinct %1$s) as keys
          from (select * from %2$s v where v.gn_key >= $1 and gnomon._vis(v.gn_key, v.gn_xoff, $2) and not gnomon._vis(v.gn_key, v.gn_xoff, $3)) v
          %5$s
          join (select * from %3$s union all select * from %4$s) k on %6$s
          join gnomon.branch b on b.id = k.gn_branch and b.status = 'open'
         group by k.gn_branch$q$,
        _gnomon.key_sql(t, 'k'), _gnomon.obj(t, 'v'), _gnomon.obj(t, 'bk'), _gnomon.obj(t, 'bk_u'),
        case when t.wide_key then format('join %s i on i.gn_rid = v.gn_rid', _gnomon.obj(t, 'id')) else '' end,
        (select string_agg(format('k.%1$I = %2$s.%1$I', c, case when t.wide_key then 'i' else 'v' end), ' and ') from unnest(t.key_cols) c))
      using gnomon._kxmin(w), nowc, w
    loop
      select * into br from gnomon.branch where id = pr.br;
      bb := gnomon._base_at(br.id, null);
      for pl in select * from _gnomon.plan(null, t.id, pr.keys, row('main', gnomon.coord_text(bb.lin_c[cardinality(bb.lin_c)]))::gnomon.ref,
                                            row('main', null)::gnomon.ref, row(br.name, null)::gnomon.ref) loop
        if jsonb_array_length(pl.conflicts) > 0 then
          insert into gnomon.warning(branch, tbl, key, col, kind, detail)
          select br.id, t.rel, pl.k, coalesce(c ->> 'col', ''), c ->> 'kind', c
            from jsonb_array_elements(pl.conflicts) c
          on conflict (branch, tbl, key, col) do update set kind = excluded.kind, detail = excluded.detail, at = now();
          n := n + 1;
        end if;
      end loop;
    end loop;
  end loop;
  -- the watch point moves only past changes: an idle database takes no xid here (ticks stay off)
  if nseen > 0 then
    update gnomon.setting set value = gnomon.coord_text(nowc) where name = 'watch_coord';
    insert into gnomon.setting(name, value, doc) values ('main_changes', nseen::text, 'Versions gnomon.watch() has seen main write (branch distance).')
      on conflict (name) do update set value = (setting.value::int8 + nseen)::text;
    -- branches whose base main has left far behind: a warning, or a rebase (auto_rebase)
    thr := gnomon._cfg('warn_changes_since_base')::int8; cnt := _gnomon.main_changes();
    for r in select b2.id, b2.name, cnt - bq.main_seq as behind
               from gnomon.branch_base bq join gnomon.branch b2 on b2.id = bq.branch and b2.status = 'open'
              where bq.main_seq < cnt - thr
                and bq.id = (select max(x.id) from gnomon.branch_base x where x.branch = bq.branch)
                and not exists (select 1 from gnomon.warning w2 where w2.branch = b2.id and w2.kind = 'behind-base') loop
      if gnomon._cfg('auto_rebase') = 'on' then
        perform gnomon.rebase(r.name);
      else
        insert into gnomon.warning(branch, tbl, key, col, kind, detail)
        values (r.id, 'gnomon.branch'::regclass, jsonb_build_object('branch', r.name), '', 'behind-base',
                jsonb_build_object('behind', r.behind, 'threshold', thr, 'hint', format('select gnomon.rebase(%L)', r.name)))
        on conflict (branch, tbl, key, col) do update set kind = excluded.kind, detail = excluded.detail, at = now();
        n := n + 1;
      end if;
    end loop;
  end if;
  return n;
end $$;

-------------------------------------------------------------------------------
-- Undo: revert transactions through the merge engine
-------------------------------------------------------------------------------
-- Before and after images of transactions: for each row a set of transactions
-- wrote on a branch (or main), the state before the first of those writes and after the last.
-- Undo applies them backwards, cherry-pick forwards, bisect lists them. Rows come table by table
-- in foreign-key order. On a branch, the state before a row's first write there is its
-- ancestor's at the branch's current cutoff (what the branch reads for a row it never wrote).
create function _gnomon.xid_images(xids xid8[], branch text default 'main')
returns table(tid int, key jsonb, before jsonb, after jsonb)
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch := gnomon._branch_row(branch); t gnomon.tracked; r record; ctx _gnomon.ctx;
        xs int8[] := array(select x::text::int8 from unnest(xids) x); vkj text; id int;
        strip text[] := array['gn_branch','gn_key','gn_xoff','gn_lsn','gn_role','gn_flags'];
        pref gnomon.ref;
begin
  if b.id <> 0 and not gnomon._may_read_branch(b.id) then
    raise exception 'role % may not read branch "%"', _gnomon.who(), b.name using errcode = '42501', hint = '[gnomon:branch_not_readable]';
  end if;
  ctx := gnomon._ctx_compute(case when b.id = 0 then '' else b.name end, null, null);
  if b.id <> 0 then
    pref := case when cardinality(ctx.lb) >= 2
                 then row((select x.name from gnomon.branch x where x.id = ctx.lb[2]), gnomon.coord_text(ctx.lc[2]))::gnomon.ref
                 else row('main', gnomon.coord_text(ctx.main_cut))::gnomon.ref end;
  end if;
  foreach id in array _gnomon.fk_order() loop
    t := _gnomon.trow(id);
    if b.id = 0 then
      vkj := case when t.wide_key then 'jsonb_build_object(''gn_rid'', v.gn_rid)' else _gnomon.key_sql(t, 'v') end;
      for r in execute format($q$
          with x as (select v.*, %1$s as vk from %2$s v
                      where ((v.gn_key & 281474976710655) - v.gn_xoff) = any($1) and (v.gn_flags & 48) = 0),
               g as (select vk,
                            (array_agg(gn_key order by gn_key, gn_lsn))[1] as fk, (array_agg(gn_lsn order by gn_key, gn_lsn))[1] as fl,
                            (array_agg(gn_key order by gn_key desc, gn_lsn desc))[1] as lk, (array_agg(gn_lsn order by gn_key desc, gn_lsn desc))[1] as ll
                       from x group by vk)
          select g.vk,
                 (select %3$s(g.vk, p.gn_key, p.gn_lsn) from %2$s p where %4$s and (p.gn_key, p.gn_lsn) < (g.fk, g.fl)
                   order by p.gn_key desc, p.gn_lsn desc limit 1) as before,
                 %3$s(g.vk, g.lk, g.ll) as after
            from g order by g.vk$q$,
          vkj, _gnomon.obj(t, 'v'), _gnomon.obj(t, 'vrow'),
          case when t.wide_key then 'p.gn_rid = (g.vk->>''gn_rid'')::int8' else
            (select string_agg(format('p.%1$I = (g.vk->>%1$L)::%2$s', a.attname, format_type(a.atttypid, a.atttypmod)), ' and ')
               from unnest(t.key_cols) k join pg_attribute a on a.attrelid = t.rel and a.attname = k) end)
        using xs
      loop
        tid := id; key := coalesce(_gnomon.keyj(t, coalesce(r.after, r.before)), r.vk); before := r.before; after := r.after;
        return next;
      end loop;
    else
      for r in execute format($q$
          with gn_x as (select v.* from (select * from %1$s union all select * from %2$s) v
                      where v.gn_branch = $2 and ((v.gn_key & 281474976710655) - v.gn_xoff) = any($1)),
               g as (select %3$s as vk, (array_agg(to_jsonb(gn_x) order by gn_key, gn_lsn))[1] as first,
                            (array_agg(to_jsonb(gn_x) order by gn_key desc, gn_lsn desc))[1] as last
                       from gn_x group by 1)
          select g.vk, g.first, g.last,
                 (select to_jsonb(gn_p) from (select * from %1$s union all select * from %2$s) gn_p
                   where gn_p.gn_branch = $2 and %4$s and (gn_p.gn_key, gn_p.gn_lsn) < ((g.first->>'gn_key')::int8, (g.first->>'gn_lsn')::pg_lsn)
                   order by gn_p.gn_key desc, gn_p.gn_lsn desc limit 1) as prev
            from g order by g.vk$q$,
          _gnomon.obj(t, 'bv'), _gnomon.obj(t, 'bv_u'), _gnomon.key_sql(t, 'gn_x'),
          (select string_agg(format('gn_p.%1$I = (g.vk->>%1$L)::%2$s', a.attname, format_type(a.atttypid, a.atttypmod)), ' and ')
             from unnest(t.key_cols) k join pg_attribute a on a.attrelid = t.rel and a.attname = k))
        using xs, b.id
      loop
        tid := id; key := r.vk;
        after := case when (r.last ->> 'gn_flags')::int & 4 <> 0 then null else r.last - strip end;
        if r.prev is not null then
          before := case when (r.prev ->> 'gn_flags')::int & 4 <> 0 then null else r.prev - strip end;
        else
          before := (select x.r from _gnomon.read_rows(t.id, pref, jsonb_build_array(r.vk)) x limit 1);
        end if;
        return next;
      end loop;
    end if;
  end loop;
end $$;
revoke all on function _gnomon.xid_images(xid8[], text) from public;

create function gnomon.undo_xids(xids xid8[], branch text default 'main', why text default null) returns jsonb
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch := gnomon._branch_row(branch); t gnomon.tracked; r record; m record; ctx _gnomon.ctx;
        n_rev int := 0; n_conf int := 0; conf jsonb := '[]';
        cur jsonb; ins jsonb; upd jsonb; del jsonb; tid int; ord int[] := _gnomon.fk_order();
        pm jsonb := '{}'; pb jsonb := '[]'; e jsonb;
begin
  if b.id = 0 then
    if not pg_has_role(_gnomon.who(), 'gnomon_merger', 'member') then
      raise exception 'undo on main requires membership in gnomon_merger' using errcode = '42501', hint = '[gnomon:merger_required]';
    end if;
    perform _gnomon.merge_token(null);
  elsif not gnomon._may_write(b) then
    raise exception 'role % may not write branch "%"', _gnomon.who(), b.name using errcode = '42501', hint = '[gnomon:branch_not_writable]';
  end if;
  ctx := gnomon._ctx_compute(case when b.id = 0 then '' else b.name end, null, null);
  create temp table if not exists gnomon_ximg (tid int, key jsonb, before jsonb, after jsonb) on commit drop;
  truncate gnomon_ximg;
  insert into gnomon_ximg select * from _gnomon.xid_images(xids, b.name);
  -- plan every table first, then apply: deletes children first, inserts and updates parents first
  foreach tid in array ord loop
    t := _gnomon.trow(tid);
    ins := '[]'; upd := '[]'; del := '[]';
    for r in select * from gnomon_ximg x where x.tid = t.id loop
      cur := (select x.r from _gnomon.read_rows(t.id, row(b.name, null)::gnomon.ref, jsonb_build_array(r.key)) x limit 1);
      select * into m from _gnomon.m3_row(r.after, cur, r.before, t.merge, t.key_cols);
      if jsonb_array_length(m.conflicts) > 0 then
        n_conf := n_conf + 1;
        conf := conf || jsonb_build_object('tbl', t.rel::text, 'key', r.key, 'conflicts', m.conflicts);
      elsif b.id = 0 then
        if m.action = 'insert' then ins := ins || m.result; n_rev := n_rev + 1;
        elsif m.action = 'update' then upd := upd || m.result; n_rev := n_rev + 1;
        elsif m.action = 'delete' then del := del || cur; n_rev := n_rev + 1;
        end if;
      elsif m.action <> 'none' then
        pb := pb || jsonb_build_object('tid', t.id, 'action', m.action, 'cur', cur, 'result', m.result);
        n_rev := n_rev + 1;
      end if;
    end loop;
    if b.id = 0 then pm := pm || jsonb_build_object(t.id::text, jsonb_build_object('ins', ins, 'upd', upd, 'del', del)); end if;
  end loop;
  if n_conf > 0 then
    raise exception 'undo would overwrite later changes to % row(s); nothing was undone', n_conf
      using errcode = '40001', detail = conf::text, hint = 'Undo the later transactions too, or resolve by hand. [gnomon:undo_conflict]';
  end if;
  foreach tid in array (select array_agg(x order by o desc) from unnest(ord) with ordinality u(x, o)) loop
    if b.id = 0 then
      perform _gnomon.apply_main(tid, 'delete', pm -> tid::text -> 'del');
    else
      for e in select x from jsonb_array_elements(pb) x where (x ->> 'tid')::int = tid and x ->> 'action' = 'delete' loop
        perform _gnomon.apply_branch(tid, ctx, 'delete', e -> 'cur', null);
      end loop;
    end if;
  end loop;
  foreach tid in array ord loop
    if b.id = 0 then
      perform _gnomon.apply_main(tid, 'update', pm -> tid::text -> 'upd');
      perform _gnomon.apply_main(tid, 'insert', pm -> tid::text -> 'ins');
    else
      for e in select x from jsonb_array_elements(pb) x where (x ->> 'tid')::int = tid and x ->> 'action' in ('update', 'insert') loop
        perform _gnomon.apply_branch(tid, ctx, e ->> 'action', nullif(e -> 'cur', 'null'), nullif(e -> 'result', 'null'));
      end loop;
    end if;
  end loop;
  perform gnomon._log_xact(b.id, null, jsonb_build_object('xids', to_jsonb(xids), 'why', why));
  perform gnomon._do_tick(true);
  return jsonb_build_object('reverted', n_rev, 'undo_xid', pg_current_xact_id()::text);
end $$;
grant execute on function gnomon.undo_xids(xid8[], text, text) to public;

create function gnomon.undo(xid xid8, branch text default 'main') returns jsonb language sql volatile as $$
  select gnomon.undo_xids(array[xid], branch, 'transaction')
$$;

-- (a definer; undo_xids checks the caller: a merger for main, a writer for a branch)
create function gnomon.undo_merge(merge_id bigint) returns jsonb language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
declare m gnomon.merge; r jsonb;
begin
  select * into m from gnomon.merge where id = merge_id;
  if m.id is null or not (m.status = 'applied' or (m.status in ('failed', 'applying', 'conflicts') and cardinality(m.xids) > 0)) then
    raise exception 'merge % is not applied', merge_id using hint = '[gnomon:merge_not_applied]';
  end if;
  r := gnomon.undo_xids(m.xids, (select name from gnomon.branch where id = m.target), 'merge ' || merge_id);
  update gnomon.merge set status = 'undone' where id = merge_id;
  return r;
end $$;

-- Every transaction a role wrote between two times (bounded by ticks), reverted together.
create function gnomon.undo_role(role name, since timestamptz, until timestamptz default now(), branch text default 'main') returns jsonb
language plpgsql volatile as $$
declare c1 gnomon.coord := gnomon.resolve_coord(since::text); c2 gnomon.coord := gnomon.coordinate(); xs xid8[] := '{}'; t gnomon.tracked; more xid8[];
begin
  if until < now() then c2 := gnomon.resolve_coord(until::text); end if;
  for t in select * from gnomon.tracked loop
    execute format($q$select coalesce(array_agg(distinct (((v.gn_key & 281474976710655) - v.gn_xoff)::text)::xid8), '{}')
                        from %s v where v.gn_role = $1::regrole::oid and v.gn_key >= $2 and (v.gn_flags & 48) = 0
                         and gnomon._vis(v.gn_key, v.gn_xoff, $3) and not gnomon._vis(v.gn_key, v.gn_xoff, $4)$q$,
                   case when branch = 'main' then _gnomon.obj(t, 'v') else _gnomon.obj(t, 'bv') end)
      into more using role, gnomon._kxmin(c1), c2, c1;
    xs := xs || more;
  end loop;
  if cardinality(xs) = 0 then return jsonb_build_object('reverted', 0); end if;
  return gnomon.undo_xids(array(select distinct x from unnest(xs) x), branch, format('role %s window %s..%s', role, since, until));
end $$;
