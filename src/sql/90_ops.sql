-- History management and operations: ledger, retention, archive manifest,
-- erasure, the heartbeat, gnomon doctor, and tables that already use RLS.

-------------------------------------------------------------------------------
-- Tables that already use row-level security
-------------------------------------------------------------------------------
-- The user's SELECT policies compiled into one predicate that is evaluated for the caller
-- (current_user inside a policy reached through a view is the caller).
create function _gnomon.user_rls_pred(rel regclass) returns text language sql stable as $$
  with p as (
    select pol.polpermissive as perm,
           case when 0 = any(pol.polroles) then 'true'
                else '(' || (select string_agg(format('pg_has_role(current_user, %L, ''member'')', r.rolname), ' OR ')
                               from pg_roles r where r.oid = any(pol.polroles)) || ')' end as rolechk,
           coalesce(pg_get_expr(pol.polqual, pol.polrelid), 'true') as qual
      from pg_policy pol
     where pol.polrelid = rel and pol.polcmd in ('r', '*') and pol.polname not like 'gnomon\_%'
  ), owner as (
    select r.rolname, c.relforcerowsecurity as forced from pg_class c join pg_roles r on r.oid = c.relowner where c.oid = rel
  )
  select format('((SELECT r.rolsuper OR r.rolbypassrls FROM pg_roles r WHERE r.rolname = current_user)%s OR ((%s)%s))',
                case when (select forced from owner) then '' else format(' OR current_user = %L', (select rolname from owner)) end,
                coalesce((select string_agg(format('(%s AND (%s))', rolechk, qual), ' OR ') from p where perm), 'false'),
                coalesce((select string_agg(format(' AND (NOT %s OR (%s))', rolechk, qual), '') from p where not perm), ''))
$$;

-- The user's policies for one write command, as one predicate over the row's columns, for the
-- caller: cmd INSERT, UPDATE or DELETE; part 'using' (which existing rows the command may touch)
-- or 'check' (which new rows it may write; for ALL and UPDATE policies without WITH CHECK, their
-- USING). Combined as PostgreSQL combines them: superusers, BYPASSRLS roles and an owner of a
-- table without FORCE pass; otherwise at least one permissive policy and every restrictive one.
create function _gnomon.user_rls_wpred(rel regclass, cmd text, part text) returns text language sql stable as $$
  with p as (
    select pol.polpermissive as perm,
           case when 0 = any(pol.polroles) then 'true'
                else '(' || (select string_agg(format('pg_has_role(current_user, %L, ''member'')', r.rolname), ' OR ')
                               from pg_roles r where r.oid = any(pol.polroles)) || ')' end as rolechk,
           coalesce(case when part = 'check' then pg_get_expr(coalesce(pol.polwithcheck, pol.polqual), pol.polrelid)
                         else pg_get_expr(pol.polqual, pol.polrelid) end, 'true') as qual
      from pg_policy pol
     where pol.polrelid = rel and pol.polname not like 'gnomon\_%'
       and pol.polcmd in ('*', case cmd when 'INSERT' then 'a' when 'UPDATE' then 'w' when 'DELETE' then 'd' end)
  ), owner as (
    select r.rolname, c.relforcerowsecurity as forced from pg_class c join pg_roles r on r.oid = c.relowner where c.oid = rel
  )
  select format('((SELECT r.rolsuper OR r.rolbypassrls FROM pg_roles r WHERE r.rolname = current_user)%s OR ((%s)%s))',
                case when (select forced from owner) then '' else format(' OR current_user = %L', (select rolname from owner)) end,
                coalesce((select string_agg(format('(%s AND (%s))', rolechk, qual), ' OR ') from p where perm), 'false'),
                coalesce((select string_agg(format(' AND (NOT %s OR (%s))', rolechk, qual), '') from p where not perm), ''))
$$;

-- Whether the table's own row-level security is in force, brought up to date before its
-- objects are generated. gnomon keeps RLS enabled on every tracked table for its arm policies,
-- so: RLS found disabled means the user turned it off; a policy of the user's own, or a statement
-- enabling RLS on it, means the user's policies govern it (with none, nobody but its owner and
-- BYPASSRLS roles sees a row). Otherwise it stays as it was when tracked.
create function _gnomon.refresh_user_rls(tid int) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked := _gnomon.trow(tid); now_rls bool; q text := lower(coalesce(current_query(), ''));
begin
  select case when not c.relrowsecurity then false
              when exists (select 1 from pg_policy p where p.polrelid = c.oid and p.polname not like 'gnomon\_%') then true
              when q ~ 'enable\s+row\s+level\s+security' and _gnomon.mentions(q, t.relname) then true
              else t.user_rls end
    into now_rls from pg_class c where c.oid = t.rel;
  if now_rls is distinct from t.user_rls then
    update gnomon.tracked set user_rls = now_rls where id = tid;
  end if;
end $$;

create function _gnomon.gen_user_rls(tid int) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked := _gnomon.trow(tid); pred text := _gnomon.user_rls_pred((_gnomon.trow(tid)).rel); sfx text;
begin
  execute format('drop policy if exists gnomon_user_arm1 on %s', _gnomon.qrel(t));
  execute format('create policy gnomon_user_arm1 on %s for select to gnomon_reader using (%s)', _gnomon.qrel(t), pred);
  foreach sfx in array array['', '_u'] loop
    execute format('drop policy if exists gnomon_arm2 on %s', _gnomon.obj(t, 'b' || sfx));
    execute format('create policy gnomon_arm2 on %s for select to gnomon_reader using (gn_branch = (select gnomon._ctx_branch()) and (select gnomon._ctx_asof_null()) and (%s))',
                   _gnomon.obj(t, 'b' || sfx), pred);
  end loop;
end $$;

-------------------------------------------------------------------------------
-- History horizon: reads older than dropped or archived history fail clearly (5, Cold storage)
-------------------------------------------------------------------------------
-- What still needs main's history (retention, archiving and dropping respect these):
--   state: main's state at the coordinate must stay readable exactly: every branch's main cutoff
--     (its current base), and the base of every merge not yet applied;
--   all: every change after the coordinate must stay: each feed consumer's position, the last
--     sealed ledger block, the early-warning watch point.
create function gnomon.history_pins() returns table(kind text, what text, coord gnomon.coord, all_after bool)
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select 'branch', b.name, bb.lin_c[cardinality(bb.lin_c)], false
    from gnomon.branch b cross join lateral (select (gnomon._base_at(b.id, null)).*) bb
   where b.id <> 0 and cardinality(bb.lin_c) > 0
  union all
  select 'merge', m.id::text, m.base, false from gnomon.merge m
   where m.status in ('planned', 'conflicts', 'applying', 'failed') and m.base is not null
  union all
  select 'feed consumer', c.name, c.pos, true from gnomon.consumer c
  union all
  select 'ledger', 'last sealed block', l.to_coord, true from (select to_coord from gnomon.ledger_block order by id desc limit 1) l
  union all
  select 'watch', 'gnomon.watch()', gnomon.coord(s.value), true from gnomon.setting s where s.name = 'watch_coord'
$$;

-- The read horizon of a table: below it, past reads fail (gnomon._check_horizon). The highest
-- of what drop_history_before dropped and what is archived and not restored.
create function _gnomon.set_horizon(tid int) returns void language sql volatile as $$
  update gnomon.tracked t
     set retention = case when h is null then coalesce(t.retention, '{}') - 'horizon_key'
                          else coalesce(t.retention, '{}') || jsonb_build_object('horizon_key', h) end
    from (select nullif(greatest(coalesce((t2.retention ->> 'dropped_below')::int8, 0),
                                 coalesce((select max(a.key_hi) + 1 from gnomon.archive a where a.tbl = t2.rel and not a.restored), 0)), 0) as h
            from gnomon.tracked t2 where t2.id = tid) x
   where t.id = tid
$$;

create function gnomon._check_horizon(tid int) returns bool language plpgsql stable as $$
declare t gnomon.tracked := _gnomon.trow(tid); h int8; a gnomon.archive; mx int8 := gnomon._ctx_main_xmin();
begin
  if mx is null then return true; end if;
  if (gnomon._ctx()).asof is not null and (gnomon._ctx()).branch = 0
     and not gnomon._vis(t.track_key, t.track_xoff, gnomon._ctx_main_cut()) and t.mode = 'known' then
    raise exception 'gnomon has no history of % before it was tracked at %', t.rel, gnomon.coord_text(t.track_coord)
      using errcode = '22023', hint = '[gnomon:no_history_before_tracked]';
  end if;
  h := (t.retention ->> 'horizon_key')::int8;
  if h is not null and mx < h then
    -- an archive read in place through its foreign partition counts as here when cold_scans allows
    select * into a from gnomon.archive where tbl = t.rel and not restored and not thinned and key_hi >= mx
       and (foreign_rel is null or gnomon._cfg('cold_scans') <> 'allow') order by key_lo limit 1;
    if a.id is not null and a.foreign_rel is not null and gnomon._cfg('cold_scans') = 'refuse' then
      raise exception 'history of % at this coordinate is in archives read in place, and cold_scans is refuse', t.rel
        using errcode = '55000', hint = 'Set cold_scans to allow (scans through the archive are slow) or thaw, or gnomon restore. [gnomon:cold_scans]';
    end if;
    if a.id is null and mx >= coalesce((t.retention ->> 'dropped_below')::int8, 0) then
      return true;   -- everything this read needs is attached in place
    end if;
    if a.id is not null then
      -- being thawed: gnomon.use asked for it and the job loop restores it
      if exists (select 1 from gnomon.thaw_request r where r.tbl = t.rel and r.status in ('pending', 'thawing')) then
        raise exception 'history of % at this coordinate is being thawed from the archive: % partition(s), % row(s); retry shortly', t.rel,
              (select count(*) from gnomon.thaw_request r where r.tbl = t.rel and r.status in ('pending', 'thawing')),
              (select coalesce(sum(x.rows), 0) from gnomon.archive x join gnomon.thaw_request r on r.tbl = x.tbl and r.part = x.part
                where r.tbl = t.rel and r.status in ('pending', 'thawing'))
          using errcode = '55000', hint = 'gnomon daemon restores thaw requests; gnomon.thaw_status() shows them. [gnomon:thawing]';
      end if;
      raise exception 'history of % at this coordinate is archived in %', t.rel, a.uri
        using errcode = '55000', hint = format('gnomon.use() with this coordinate asks for a thaw (the daemon restores it), or: gnomon restore %s %s [gnomon:archived]', t.rel, a.part);
    end if;
    raise exception 'history of % before the retention horizon has been dropped', t.rel using errcode = '22023', hint = '[gnomon:history_before_retention_horizon]';
  end if;
  -- thinned by retention: exact only at the coordinates it kept (tags, the day's or month's last
  -- tick, branch cutoffs and merge bases at the time)
  h := (t.retention ->> 'thinned_below')::int8;
  if h is not null and mx < h and not coalesce(t.retention -> 'retained' ? gnomon.coord_text(gnomon._ctx_main_cut()), false) then
    raise exception 'history of % at this coordinate was thinned by retention', t.rel
      using errcode = '22023',
            hint = format('Read at a tag or a tick retention kept (policy %s), or after %s.', t.retention - 'retained' - 'thinned_below' - 'horizon_key' - 'dropped_below',
                          (select min(k.at) from gnomon.tick k where gnomon._kxmin(k.coord) >= h));
  end if;
  return true;
end $$;

-------------------------------------------------------------------------------
-- Tamper-evident ledger: a Merkle block per tick interval, chained by hash
-------------------------------------------------------------------------------
create table _gnomon.ledger_leaf (
  block bigint not null references gnomon.ledger_block on delete cascade,
  tbl   regclass not null,
  vkey  int8 not null,
  vlsn  pg_lsn not null,
  key   jsonb not null,          -- format 2: the key's values in key-column order
  leaf  bytea not null,
  tid   int,                     -- format 2: the tracked table's id (stable across renames)
  primary key (block, tbl, vkey, vlsn, key)
);
create table _gnomon.history_removed (
  tbl   regclass not null,
  vkey  int8 not null,
  vlsn  pg_lsn not null,
  why   text not null,
  primary key (tbl, vkey, vlsn)
);

-- Format 1 leaves (blocks sealed before format 2): the table's name, the key and the row image by
-- column names. Renames and new columns changed them; kept to verify those blocks.
create function _gnomon.leaf(tbl regclass, key jsonb, vkey int8, vlsn pg_lsn, xid xid8, op text, img jsonb) returns bytea
language sql immutable as $$
  select sha256(convert_to(concat_ws('|', tbl::text, key::text, vkey, vlsn, xid, op,
                                     encode(sha256(convert_to(coalesce(img::text, ''), 'UTF8')), 'hex')), 'UTF8'))
$$;

-- Format 2 leaves: what stays the same across DDL. The table by its tracked id, the key by its
-- values in key-column order, and a hash per value by its storage slot (slots survive renames
-- and are never reused; a column dropped keeps its slot, and a slot a version predates has
-- no value in it). A value's hash is sha256 of its text, which is also a large value's blob
-- reference, so it does not matter whether a value is stored inline or as a blob. Text forms are
-- taken under fixed settings (the SET clauses of seal_ledger, verify_ledger and erase).
create function _gnomon.leaf2(tid int, kv jsonb, vkey int8, vlsn pg_lsn, xid xid8, op text, vh jsonb) returns bytea
language sql immutable as $$
  select sha256(convert_to(concat_ws('|', '2', tid, kv::text, vkey, vlsn, xid, op,
           (select coalesce(string_agg(e.key || '=' || e.value, ',' order by e.key::int), '') from jsonb_each_text(vh) e)), 'UTF8'))
$$;

-- The value slots a version table holds, dropped columns' included.
create function _gnomon.phys_slots(t gnomon.tracked) returns table(slot int, has_h bool) language sql stable as $$
  select substring(a.attname from '^gn_c([0-9]+)$')::int,
         exists (select 1 from pg_attribute h where h.attrelid = a.attrelid and h.attname = 'gn_h' || substring(a.attname from '^gn_c([0-9]+)$')
                   and h.attnum > 0 and not h.attisdropped)
    from pg_attribute a
   where a.attrelid = _gnomon.obj(t, 'v')::regclass and a.attname ~ '^gn_c[0-9]+$' and a.attnum > 0 and not a.attisdropped
$$;

-- The value hashes of version v (keyframe k joined beside it) as {slot: hash}, for the slots in
-- pick (all when null). A delete has none.
create function _gnomon.vh_sql(t gnomon.tracked, pick int[] default null) returns text language sql stable as $$
  select '(SELECT coalesce(jsonb_object_agg(gn_x.s, gn_x.h), ''{}'') FROM (VALUES ' ||
         coalesce(string_agg(format($e$(%1$s, CASE WHEN (v.gn_flags & 4) <> 0 THEN NULL
                   WHEN (v.gn_flags & 8) <> 0 THEN CASE WHEN coalesce(length(v.gn_mask) > %1$s, true) THEN %2$s END
                   WHEN length(v.gn_mask) > %1$s AND get_bit(v.gn_mask, %1$s) = 1 THEN %2$s
                   WHEN coalesce(length(k.gn_mask) > %1$s, true) THEN %3$s END)$e$,
                   p.slot,
                   format('encode(coalesce(sha256(convert_to((v.gn_c%1$s)::text, ''UTF8''))%2$s), ''hex'')', p.slot,
                          case when p.has_h then format(', v.gn_h%s', p.slot) else '' end),
                   format('encode(coalesce(sha256(convert_to((k.gn_c%1$s)::text, ''UTF8''))%2$s), ''hex'')', p.slot,
                          case when p.has_h then format(', k.gn_h%s', p.slot) else '' end)),
                   ', ' order by p.slot), '(0, NULL::text)')
         || ') gn_x(s, h) WHERE gn_x.h IS NOT NULL)'
    from _gnomon.phys_slots(t) p where pick is null or p.slot = any(pick)
$$;

-- The leaf inputs of every version of a table visible at c2 and not at c1 (the feed's set),
-- in format 2, or of every version of one key (by its key values key_vals) when c1 and c2 are null.
create function _gnomon.leaf2_rows(tid int, c1 gnomon.coord, c2 gnomon.coord, key_vals jsonb default null, pick int[] default null)
returns table(vkey int8, vlsn pg_lsn, kv jsonb, op text, xid xid8, vh jsonb)
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked := _gnomon.trow(tid); cs _gnomon.col[] := _gnomon.tcols(tid); ks _gnomon.col[]; ksrc text; eq text;
begin
  ks := _gnomon.keys(cs);
  ksrc := case when t.wide_key then 'i' else 'v' end;
  eq := case when t.wide_key then 'k.gn_rid = v.gn_rid'
             else (select string_agg(format('k.%1$s = v.%1$s', k.q), ' AND ') from unnest(ks) k) end;
  return query execute _gnomon.tpl($q$
    select v.gn_key, v.gn_lsn, jsonb_build_array(@KV@),
           case when v.gn_flags & 64 <> 0 then 'retract' when v.gn_flags & 1 <> 0 then 'insert' when v.gn_flags & 4 <> 0 then 'delete' else 'update' end
             @VT@,
           (((v.gn_key & 281474976710655) - v.gn_xoff)::text)::xid8,
           @VH@
      from @V@ v
      @IDJ@
      left join lateral (select k.* from @V@ k
                          where (v.gn_flags & 8) = 0 and @EQ@ and k.gn_part = v.gn_part and (k.gn_flags & 8) <> 0
                            and (k.gn_key, k.gn_lsn) < (v.gn_key, v.gn_lsn)
                          order by k.gn_key desc, k.gn_lsn desc limit 1) k on true
     where (v.gn_flags & 48) = 0
       and case when $1 is null then @KVEQ@
                else v.gn_key >= gnomon._kxmin($1) and v.gn_key <= gnomon._kxmax($2)
                     and gnomon._vis(v.gn_key, v.gn_xoff, $2) and not gnomon._vis(v.gn_key, v.gn_xoff, $1) end$q$,
    -- one key, by its values in key-column order (an index probe)
    'KVEQ', case when t.wide_key
                 then format('v.gn_rid = (select i2.gn_rid from %s i2 where %s)', _gnomon.obj(t, 'id'),
                             (select string_agg(format('i2.%s = ($3->>%s)::%s', k.q, o - 1, k.typ), ' AND ')
                                from unnest(t.key_cols) with ordinality u(kc, o) join unnest(ks) k on k.raw = u.kc))
                 else (select string_agg(format('v.%s = ($3->>%s)::%s', k.q, o - 1, k.typ), ' AND ')
                         from unnest(t.key_cols) with ordinality u(kc, o) join unnest(ks) k on k.raw = u.kc) end,
    'KV', (select string_agg(ksrc || '.' || k.q, ', ' order by o) from unnest(t.key_cols) with ordinality u(kc, o)
             join unnest(ks) k on k.raw = u.kc),
    'VT', case when t.mode = 'bitemporal'
               then $v$ || ';vf=' || coalesce(extract(epoch from v.gn_valid_from)::text, '') || ';r=' || coalesce(v.gn_retracts::text, '')$v$
               else '' end,
    'VH', _gnomon.vh_sql(t, pick), 'V', _gnomon.obj(t, 'v'), 'EQ', eq,
    'IDJ', case when t.wide_key then format('LEFT JOIN %s i ON i.gn_rid = v.gn_rid', _gnomon.obj(t, 'id')) else '' end)
    using c1, c2, key_vals;
end $$;
revoke all on function _gnomon.leaf2_rows(int, gnomon.coord, gnomon.coord, jsonb, int[]) from public;

create function _gnomon.merkle(leaves bytea[]) returns bytea language plpgsql immutable as $$
declare lvl bytea[] := leaves; nxt bytea[]; i int;
begin
  if leaves is null or cardinality(leaves) = 0 then return sha256(''::bytea); end if;
  while cardinality(lvl) > 1 loop
    nxt := '{}'; i := 1;
    while i <= cardinality(lvl) loop
      nxt := nxt || sha256(lvl[i] || coalesce(lvl[i + 1], lvl[i]));
      i := i + 2;
    end loop;
    lvl := nxt;
  end loop;
  return lvl[1];
end $$;

create function gnomon.seal_ledger() returns bigint language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp
set timezone = 'UTC' set datestyle = 'ISO, YMD' set intervalstyle = 'postgres' set extra_float_digits = 1 set bytea_output = 'hex' as $$
declare last gnomon.ledger_block; fromc gnomon.coord; toc gnomon.coord := gnomon.coordinate(); bid bigint; leaves bytea[]; n bigint; root bytea;
        t gnomon.tracked; lv jsonb := '[]';
begin
  select * into last from gnomon.ledger_block order by id desc limit 1;
  fromc := coalesce(last.to_coord, (select track_coord from gnomon.tracked order by id limit 1));
  if fromc is null then return null; end if;
  -- (collected in a variable, not a temp table: with nothing to seal, nothing is written and no xid
  -- is taken, so an idle database's heartbeat leaves no trace)
  for t in select * from gnomon.tracked order by id loop
    lv := lv || coalesce((select jsonb_agg(jsonb_build_object('tbl', t.rel::oid, 'tid', t.id, 'vkey', r.vkey, 'vlsn', r.vlsn::text, 'key', r.kv,
                                                             'leaf', encode(_gnomon.leaf2(t.id, r.kv, r.vkey, r.vlsn, r.xid, r.op, r.vh), 'hex')))
                            from _gnomon.leaf2_rows(t.id, fromc, toc) r), '[]');
  end loop;
  n := jsonb_array_length(lv);
  if n = 0 then return null; end if;
  select array_agg(decode(e ->> 'leaf', 'hex') order by (e ->> 'vkey')::int8, (e ->> 'vlsn')::pg_lsn, (e ->> 'tid')::int, (e -> 'key')::text)
    into leaves from jsonb_array_elements(lv) e;
  root := _gnomon.merkle(leaves);
  insert into gnomon.ledger_block(from_coord, to_coord, n_changes, root, prev_hash, hash, leaf_format)
  values (fromc, toc, n, root, last.hash,
          sha256(coalesce(last.hash, ''::bytea) || root || convert_to(gnomon.coord_text(toc) || '|' || n, 'UTF8')), 2)
  returning id into bid;
  insert into _gnomon.ledger_leaf(block, tbl, vkey, vlsn, key, leaf, tid)
  select bid, (e ->> 'tbl')::oid::regclass, (e ->> 'vkey')::int8, (e ->> 'vlsn')::pg_lsn, e -> 'key', decode(e ->> 'leaf', 'hex'), (e ->> 'tid')::int
    from jsonb_array_elements(lv) e on conflict do nothing;
  return bid;
end $$;

-- Recompute every block: the chain, the roots, and each still-present version's leaf. Versions
-- removed by retention or archiving are accounted for, and so are values replaced by erasure:
-- an erased value's leaf input is the hash erase() recorded before replacing it (format 2), so
-- the rest of the erased row's history is still checked.
create function gnomon.verify_ledger() returns table(block bigint, ok bool, detail text)
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp
set timezone = 'UTC' set datestyle = 'ISO, YMD' set intervalstyle = 'postgres' set extra_float_digits = 1 set bytea_output = 'hex' as $$
declare b gnomon.ledger_block; prev bytea; bad bigint; missing bigint; extra bigint; leaves bytea[]; t gnomon.tracked;
        nblocks int := 0; nfailed int := 0; firstbad bigint;
begin
  create temp table if not exists gnomon_vleaves (tid int, vkey int8, vlsn pg_lsn, key jsonb, leaf bytea, leaf_er bytea, legacy_erased bool) on commit drop;
  for b in select * from gnomon.ledger_block order by id loop
    block := b.id; ok := true; detail := 'ok';
    if b.prev_hash is distinct from prev then ok := false; detail := 'chain broken: prev_hash does not match the previous block'; end if;
    if b.leaf_format = 1 then
      select array_agg(l.leaf order by l.vkey, l.vlsn, l.tbl::text, l.key::text) into leaves from _gnomon.ledger_leaf l where l.block = b.id;
    else
      select array_agg(l.leaf order by l.vkey, l.vlsn, l.tid, l.key::text) into leaves from _gnomon.ledger_leaf l where l.block = b.id;
    end if;
    if ok and _gnomon.merkle(leaves) <> b.root then ok := false; detail := 'stored leaves do not match the block root'; end if;
    if ok and b.hash <> sha256(coalesce(b.prev_hash, ''::bytea) || b.root || convert_to(gnomon.coord_text(b.to_coord) || '|' || b.n_changes, 'UTF8')) then
      ok := false; detail := 'block hash mismatch';
    end if;
    if ok and b.leaf_format = 1 then
      with now_leaves as (
        select c.tbl, c.vkey, c.vlsn, c.key, _gnomon.leaf(c.tbl, c.key, c.vkey, c.vlsn, c.xid, c.op, c.new) as leaf
          from gnomon.changes(gnomon.coord_text(b.from_coord), gnomon.coord_text(b.to_coord)) c where c.op <> 'truncate')
      select count(*) filter (where n.leaf is not null and n.leaf <> l.leaf
                                and not exists (select 1 from gnomon.erasure e where e.tbl = l.tbl and e.key = l.key)),
             count(*) filter (where n.leaf is null
                                and not exists (select 1 from _gnomon.history_removed h where h.tbl = l.tbl and h.vkey = l.vkey and h.vlsn = l.vlsn)
                                and not exists (select 1 from gnomon.archive a where a.tbl = l.tbl and not a.restored and l.vkey between a.key_lo and a.key_hi))
        into bad, missing
        from _gnomon.ledger_leaf l left join now_leaves n on n.tbl = l.tbl and n.vkey = l.vkey and n.vlsn = l.vlsn and n.key = l.key
       where l.block = b.id;
      if bad > 0 then ok := false; detail := format('%s version(s) changed after sealing', bad);
      elsif missing > 0 then ok := false; detail := format('%s version(s) missing without a retention or archive record', missing);
      elsif exists (select 1 from gnomon.changes(gnomon.coord_text(b.from_coord), gnomon.coord_text(b.to_coord), null, false) c
                     where c.op <> 'truncate' and not exists (select 1 from _gnomon.ledger_leaf l where l.block = b.id and l.tbl = c.tbl and l.vkey = c.vkey and l.vlsn = c.vlsn and l.key = c.key)) then
        ok := false; detail := 'versions present that the block does not cover';
      end if;
    elsif ok then
      truncate gnomon_vleaves;
      for t in select * from gnomon.tracked order by id loop
        insert into gnomon_vleaves
        select t.id, r.vkey, r.vlsn, r.kv, _gnomon.leaf2(t.id, r.kv, r.vkey, r.vlsn, r.xid, r.op, r.vh),
               case when er.h is not null then _gnomon.leaf2(t.id, r.kv, r.vkey, r.vlsn, r.xid, r.op, r.vh || er.h) end,
               -- erasures recorded before format 2 hashed values by column: the key's leaves are not checked
               exists (select 1 from gnomon.erasure e where e.tbl = t.rel and not (e.hashes ? 'format')
                         and (select jsonb_agg(e.key -> kc order by o) from unnest(t.key_cols) with ordinality u(kc, o)) = r.kv)
          from _gnomon.leaf2_rows(t.id, b.from_coord, b.to_coord) r
          left join lateral (select jsonb_object_agg(x.key, x.value) as h
                               from gnomon.erasure e cross join lateral jsonb_each(e.hashes -> 'versions' -> (r.vkey || '/' || r.vlsn)) x
                              where e.tbl = t.rel and e.hashes ->> 'format' = '2') er on true;
      end loop;
      select count(*) filter (where n.tid is not null and n.leaf <> l.leaf and n.leaf_er is distinct from l.leaf and not n.legacy_erased),
             count(*) filter (where n.tid is null
                                and not exists (select 1 from _gnomon.history_removed h where h.tbl = l.tbl and h.vkey = l.vkey and h.vlsn = l.vlsn)
                                and not exists (select 1 from gnomon.archive a where a.tbl = l.tbl and not a.restored and l.vkey between a.key_lo and a.key_hi))
        into bad, missing
        from _gnomon.ledger_leaf l left join gnomon_vleaves n on n.tid = l.tid and n.vkey = l.vkey and n.vlsn = l.vlsn and n.key = l.key
       where l.block = b.id;
      select count(*) into extra from gnomon_vleaves n
       where not exists (select 1 from _gnomon.ledger_leaf l where l.block = b.id and l.tid = n.tid and l.vkey = n.vkey and l.vlsn = n.vlsn and l.key = n.key);
      if bad > 0 then ok := false; detail := format('%s version(s) changed after sealing', bad);
      elsif missing > 0 then ok := false; detail := format('%s version(s) missing without a retention or archive record', missing);
      elsif extra > 0 then ok := false; detail := 'versions present that the block does not cover';
      end if;
    end if;
    prev := b.hash;
    nblocks := nblocks + 1;
    if not ok then nfailed := nfailed + 1; firstbad := coalesce(firstbad, b.id); end if;
    return next;
  end loop;
  -- the result, for gnomon.metrics() (not on a standby or in a read-only transaction)
  if not pg_is_in_recovery() and current_setting('transaction_read_only') = 'off' then
    insert into gnomon.ledger_verification(blocks, failed, first_failed) values (nblocks, nfailed, firstbad);
    delete from gnomon.ledger_verification v where v.id <= (select max(v2.id) - 100 from gnomon.ledger_verification v2);
  end if;
end $$;

create function gnomon.ledger_digest() returns table(block bigint, to_coord text, n_changes bigint, root text, hash text)
language sql stable as $$
  select id, gnomon.coord_text(to_coord), n_changes, encode(root, 'hex'), encode(hash, 'hex') from gnomon.ledger_block order by id
$$;

-------------------------------------------------------------------------------
-- Retention: keep versions visible at retained coordinates, drop the rest
-------------------------------------------------------------------------------
create function gnomon.set_retention(tbl regclass, policy jsonb) returns void language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform _gnomon.require_manage(_gnomon.base_rel(tbl));

  tbl := _gnomon.base_rel(tbl);  update gnomon.tracked set retention = coalesce(retention, '{}') || policy where rel = tbl;
  if not found then raise exception '% is not tracked', tbl using hint = '[gnomon:not_tracked]'; end if;
end $$;

-- Retained coordinates for a policy {"keep_all": "30 days", "daily": "1 year", "monthly": true}.
create function _gnomon.retained_coords(policy jsonb) returns gnomon.coord[] language sql stable as $$
  select coalesce(array_agg(c), '{}') from (
    select t.coord as c from gnomon.tag t
    union all
    select (array_agg(k.coord order by k.id desc))[1] from gnomon.tick k
     where k.at < now() - coalesce((policy ->> 'keep_all')::interval, '30 days')
       and k.at >= now() - coalesce((policy ->> 'daily')::interval, '0 days')
     group by date_trunc('day', k.at)
    union all
    select (array_agg(k.coord order by k.id desc))[1] from gnomon.tick k
     where coalesce((policy ->> 'monthly')::bool, false)
       and k.at < now() - coalesce((policy ->> 'daily')::interval, '0 days')
     group by date_trunc('month', k.at)
  ) s where c is not null
$$;

create function gnomon.apply_retention(tbl regclass default null) returns jsonb language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; gn_prev_ddl text := coalesce(current_setting('gnomon._in_ddl', true), ''); hz gnomon.coord; rc gnomon.coord[]; n_mat bigint; n_del bigint; out jsonb := '{}'; cs _gnomon.col[];
        vk text; V text; hzk int8; lf record; n bigint; n_below bigint; n_keep bigint; n_kd bigint; sel text; mat text;
        nn text; lo text; hi text; n_swapped int;
begin
  if not pg_has_role(_gnomon.who(), 'gnomon_admin', 'member') then
    raise exception 'this requires gnomon_admin' using errcode = '42501', hint = '[gnomon:requires_gnomon_admin]';
  end if;

  tbl := _gnomon.base_rel(tbl);  for t in select * from gnomon.tracked where retention is not null and (tbl is null or rel = tbl) and mode = 'known' loop
    hz := (select k.coord from gnomon.tick k
     where k.at < now() - coalesce((t.retention ->> 'keep_all')::interval, '30 days') order by k.id desc limit 1);
    if hz is null then continue; end if;
    -- every change after a feed consumer's position, the ledger's last seal and the watch point
    -- stays; main's state at every branch cutoff and unapplied merge base stays readable
    hzk := least(gnomon._kxmin(hz), (select min(gnomon._kxmin(p.coord)) from gnomon.history_pins() p where p.all_after));
    rc := _gnomon.retained_coords(t.retention) || hz
          || coalesce((select array_agg(p.coord) from gnomon.history_pins() p where not p.all_after), '{}');
    cs := _gnomon.tcols(t.id); V := _gnomon.obj(t, 'v');
    vk := case when t.wide_key then 'gn_rid' else _gnomon.lst(_gnomon.keys(cs)) end;
    -- versions to keep: the visible one at each retained coordinate, and everything after the horizon
    execute format($q$create temp table gnomon_keep on commit drop as
      select distinct on (%1$s, r.ord) v.tableoid as k_tab, v.ctid as k_tid, %1$s
        from %2$s v cross join generate_subscripts($1, 1) r(ord)
       where v.gn_key < $2 and v.gn_key <= gnomon._kxmax(($1)[r.ord]) and gnomon._vis(v.gn_key, v.gn_xoff, ($1)[r.ord])
       order by %1$s, r.ord, v.gn_key desc, v.gn_lsn desc$q$,
      (select string_agg('v.' || x, ', ') from unnest(string_to_array(vk, ', ')) x), V)
      using rc, hzk;
    create index on gnomon_keep (k_tab, k_tid);
    -- a kept delta becomes a keyframe: its keyframe may be among the removed
    mat := 'k.k_tid IS NOT NULL AND (v.gn_flags & 8) = 0';
    sel := (select string_agg(
              case when a.attname = 'gn_flags' then format('CASE WHEN %s THEN v.gn_flags | 8 ELSE v.gn_flags END', mat)
                   when a.attname = 'gn_mask' then format('CASE WHEN %s THEN %s ELSE v.gn_mask END', mat, _gnomon.ones(t.nslots))
                   when vc.slot is not null then format('CASE WHEN %s THEN (%s(%s, v.gn_key, v.gn_lsn) ->> %L)::%s ELSE v.%I END',
                        mat, _gnomon.obj(t, 'vrow'),
                        case when t.wide_key then 'jsonb_build_object(''gn_rid'', v.gn_rid)' else _gnomon.key_sql(t, 'v') end,
                        vc.raw, vc.typ, a.attname)
                   else 'v.' || quote_ident(a.attname) end, ', ' order by a.attnum)
              from pg_attribute a left join unnest(_gnomon.vals(cs)) vc on a.attname = 'gn_c' || vc.slot
             where a.attrelid = V::regclass and a.attnum > 0 and not a.attisdropped);
    n_mat := 0; n_del := 0; n_swapped := 0;
    -- Each partition holding versions below the horizon is rewritten with
    -- what it keeps and swapped in, so thinning leaves no dead rows behind. Old partitions take
    -- no new rows (new versions, carry-forward keyframes and baselines all go to the current
    -- partition), so the rewrite does not race with writers; the swap holds an exclusive lock on
    -- the version table only for the detach and attach. The default partition is thinned in place.
    for lf in select c.oid::regclass as leaf, c.relname, pg_get_expr(c.relpartbound, c.oid) as bound
                from pg_inherits i join pg_class c on c.oid = i.inhrelid
               where i.inhparent = V::regclass order by c.relname loop
      execute format($q$select count(*) filter (where v.gn_key < $1), count(k.k_tid), count(*) filter (where %s)
                          from %s v left join gnomon_keep k on k.k_tab = v.tableoid and k.k_tid = v.ctid$q$, mat, lf.leaf)
        into n_below, n_keep, n_kd using hzk;
      continue when n_below = n_keep;   -- nothing to remove here
      execute format($q$insert into _gnomon.history_removed
                          select %L::regclass, v.gn_key, v.gn_lsn, 'retention' from %s v
                           where v.gn_key < $1 and not exists (select 1 from gnomon_keep k where k.k_tab = v.tableoid and k.k_tid = v.ctid)
                          on conflict do nothing$q$, t.rel, lf.leaf) using hzk;
      n_del := n_del + n_below - n_keep;
      n_mat := n_mat + n_kd;
      -- The partition new versions go to (and any after it) is thinned in place, like the default
      -- partition: rewriting it would race with its writers. An older one takes new rows only from
      -- a transaction stamped long ago (REPEATABLE READ); it is locked against writes (reads go on)
      -- for its rewrite, so none is lost when it is swapped.
      if lf.bound <> 'DEFAULT'
         and substring(lf.bound from 'TO \(([0-9-]+)\)')::int8 > gnomon._part((gnomon.current_epoch()::int8 << 48) | gnomon._xid(pg_snapshot_xmax(pg_current_snapshot())), t.part_span) then
        lf.bound := 'DEFAULT';   -- (in place, below)
      elsif lf.bound <> 'DEFAULT' then
        execute format('lock table %s in exclusive mode', lf.leaf);
      end if;
      if lf.bound = 'DEFAULT' then
        execute format($q$update %1$s v set (%2$s) = (select %3$s) from gnomon_keep k
                           where v.ctid = k.k_tid and k.k_tab = %4$s and (v.gn_flags & 8) = 0$q$,
          lf.leaf, (select string_agg(quote_ident(a.attname), ', ' order by a.attnum) from pg_attribute a
                     where a.attrelid = V::regclass and a.attnum > 0 and not a.attisdropped),
          replace(sel, 'k.k_tid IS NOT NULL', 'true'), lf.leaf::oid);
        execute format($q$delete from %s v where v.gn_key < $1
                           and not exists (select 1 from gnomon_keep k where k.k_tab = v.tableoid and k.k_tid = v.ctid)$q$, lf.leaf) using hzk;
        continue;
      end if;
      lo := substring(lf.bound from 'FROM \(([0-9-]+)\)'); hi := substring(lf.bound from 'TO \(([0-9-]+)\)');
      nn := left(lf.relname, 54) || '_rewrite';
      perform set_config('gnomon._in_ddl', '1', true);   -- our own DDL: the event triggers stay out
      execute format('create table _gnomon.%I (like %s including defaults)', nn, V);
      execute format($q$insert into _gnomon.%I select %s from %s v left join gnomon_keep k on k.k_tab = v.tableoid and k.k_tid = v.ctid
                         where v.gn_key >= $1 or k.k_tid is not null$q$, nn, sel, lf.leaf) using hzk;
      execute format('alter table _gnomon.%I add constraint %I check (gn_part >= %s and gn_part < %s)', nn, nn || '_chk', lo, hi);
      execute format('alter table %s detach partition %s', V, lf.leaf);
      execute format('drop table %s', lf.leaf);
      execute format('alter table _gnomon.%I rename to %I', nn, lf.relname);
      execute format('alter table %s attach partition _gnomon.%I %s', V, lf.relname, lf.bound);
      execute format('alter table _gnomon.%I drop constraint %I', lf.relname, nn || '_chk');
      execute format('grant select on _gnomon.%I to gnomon_reader, gnomon_admin', lf.relname);
      execute format('grant select, insert on _gnomon.%I to gnomon_writer', lf.relname);
      perform set_config('gnomon._in_ddl', gn_prev_ddl, true);
      n_swapped := n_swapped + 1;
    end loop;
    drop table gnomon_keep;
    -- below the horizon, reads are exact only at the coordinates kept (gnomon._check_horizon)
    if n_del > 0 or t.retention ? 'thinned_below' then
      update gnomon.tracked set retention = retention || jsonb_build_object(
               'thinned_below', greatest(hzk, coalesce((retention ->> 'thinned_below')::int8, hzk)),
               'retained', (select coalesce(jsonb_agg(distinct gnomon.coord_text(c)), '[]') from unnest(rc) c))
       where id = t.id;
    end if;
    out := out || jsonb_build_object(t.rel::text, jsonb_build_object('materialized', n_mat, 'removed', n_del, 'partitions_rewritten', n_swapped));
  end loop;
  return out;
end $$;

-- Drop whole version partitions older than a time; each partition is self-contained.
create function gnomon.drop_history_before(tbl regclass, before timestamptz, force bool default false) returns int language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; hz gnomon.coord; p record; n int := 0; hk int8; pin record;
begin
  if not pg_has_role(_gnomon.who(), 'gnomon_admin', 'member') then
    raise exception 'this requires gnomon_admin' using errcode = '42501', hint = '[gnomon:requires_gnomon_admin]';
  end if;

  tbl := _gnomon.base_rel(tbl);  select * into t from gnomon.tracked where rel = tbl;
  hz := (select k.coord from gnomon.tick k where k.at <= before order by k.id desc limit 1);
  if hz is null then return 0; end if;
  hk := gnomon._kxmin(hz);
  -- history something still needs (gnomon.history_pins) is not dropped unless forced
  select * into pin from gnomon.history_pins() hp where gnomon._kxmin(hp.coord) < hk order by gnomon._kxmin(hp.coord) limit 1;
  if pin.kind is not null and not force then
    raise exception 'history of % before % is still needed: % "%" reads it', tbl, before, pin.kind, pin.what
      using errcode = '55000',
            hint = 'See gnomon.history_pins(). Rebase or drop the branch, finish the merge, or advance the consumer; or pass force => true.';
  end if;
  for p in select c.oid::regclass as part, pg_get_expr(c.relpartbound, c.oid) as bound,
                  (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \((-?\d+)\)'))[1]::int as hi
             from pg_inherits i join pg_class c on c.oid = i.inhrelid
            where i.inhparent = _gnomon.obj(t, 'v')::regclass and pg_get_expr(c.relpartbound, c.oid) <> 'DEFAULT' loop
    if p.hi <= gnomon._part(hk, t.part_span) then
      execute format('insert into _gnomon.history_removed select %L::regclass, gn_key, gn_lsn, ''dropped'' from %s on conflict do nothing', t.rel, p.part);
      execute format('drop table %s', p.part);
      n := n + 1;
    end if;
  end loop;
  if n > 0 then
    update gnomon.tracked set retention = coalesce(retention, '{}') || jsonb_build_object('dropped_below',
             greatest(hk, coalesce((retention ->> 'dropped_below')::int8, hk))) where id = t.id;
    perform _gnomon.set_horizon(t.id);
  end if;
  return n;
end $$;

-------------------------------------------------------------------------------
-- Cold storage manifest (the CLI writes Parquet, then calls these)
-------------------------------------------------------------------------------
-- keep: the file is written, the partition stays; retention then thins it to
-- the coordinates its policy keeps, and the file answers the rest.
create function gnomon.archive_partition(tbl regclass, part int4, uri text, rows bigint, checksum text, keep bool default false, format int default 1) returns bigint
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; pt regclass; lo int8; hi int8; root bytea; id bigint; leaves bytea[];
begin

  tbl := _gnomon.base_rel(tbl);  if not pg_has_role(_gnomon.who(), 'gnomon_admin', 'member') then raise exception 'archiving requires gnomon_admin' using errcode = '42501', hint = '[gnomon:archiving_requires_gnomon_admin]'; end if;
  select * into t from gnomon.tracked tr where tr.rel = archive_partition.tbl;
  pt := to_regclass('_gnomon.' || quote_ident(t.base || '__v_p' || archive_partition.part));
  if pt is null then raise exception 'no partition % of %', part, tbl using hint = '[gnomon:no_partition]'; end if;
  execute format('select min(gn_key), max(gn_key), count(*) from %s', pt) into lo, hi;
  select array_agg(l.leaf order by l.vkey, l.vlsn, l.key::text) into leaves from _gnomon.ledger_leaf l where l.tbl = t.rel and l.vkey between lo and hi;
  if lo is null then raise exception 'partition % of % is empty', archive_partition.part, archive_partition.tbl using hint = '[gnomon:partition_empty]'; end if;
  root := _gnomon.merkle(leaves);
  insert into gnomon.archive(tbl, part, uri, rows, checksum, ledger_root, key_lo, key_hi, thinned, format)
  values (archive_partition.tbl, archive_partition.part, archive_partition.uri, archive_partition.rows, archive_partition.checksum, root, lo, hi, keep, archive_partition.format)
    on conflict on constraint archive_tbl_part_key do update set uri = excluded.uri, rows = excluded.rows, checksum = excluded.checksum,
       restored = false, ledger_root = excluded.ledger_root, key_lo = excluded.key_lo, key_hi = excluded.key_hi, thinned = excluded.thinned,
       format = excluded.format, foreign_rel = null, engine = null
    returning archive.id into id;
  if keep then return id; end if;
  execute format('drop table %s', pt);
  perform _gnomon.set_horizon(t.id);
  return id;
end $$;

-- Re-create an archived partition (empty) for the CLI to load back.
create function gnomon.restore_partition(tbl regclass, part int4) returns text language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; nm text;
begin

  tbl := _gnomon.base_rel(tbl);  if not pg_has_role(_gnomon.who(), 'gnomon_admin', 'member') then raise exception 'restoring requires gnomon_admin' using errcode = '42501', hint = '[gnomon:restoring_requires_gnomon_admin]'; end if;
  select * into t from gnomon.tracked where rel = tbl;
  nm := t.base || '__v_p' || part;
  -- an archive read in place: its foreign partition gives way to the real one
  if (select c.relkind from pg_class c where c.oid = to_regclass('_gnomon.' || quote_ident(nm))) = 'f' then
    perform gnomon.detach_archive(tbl, part);
  end if;
  if to_regclass('_gnomon.' || quote_ident(nm)) is null then
    execute format('create table _gnomon.%I partition of %s for values from (%s) to (%s)', nm, _gnomon.obj(t, 'v'), part, part + 1);
    execute format('grant select on _gnomon.%I to gnomon_reader, gnomon_admin', nm);
    execute format('grant select, insert on _gnomon.%I to gnomon_writer', nm);
  end if;
  return '_gnomon.' || quote_ident(nm);
end $$;

-- Read an archived partition in place: a foreign partition of the version table,
-- made from the engine's template, over the file (or the CSV copy beside it) at location.
create function gnomon.attach_archive(tbl regclass, part int4, engine text, location text) returns text
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; e gnomon.archive_engine; a gnomon.archive; nm text; ddl text;
begin
  tbl := _gnomon.base_rel(tbl);
  if not pg_has_role(_gnomon.who(), 'gnomon_admin', 'member') then
    raise exception 'attaching archives requires gnomon_admin' using errcode = '42501', hint = '[gnomon:archiving_requires_gnomon_admin]';
  end if;
  select * into t from gnomon.tracked x where x.rel = $1;
  select * into e from gnomon.archive_engine x where x.name = attach_archive.engine;
  if e.name is null then raise exception 'no archive engine %', engine using errcode = '42704', hint = '[gnomon:archive_engine]'; end if;
  select * into a from gnomon.archive x where x.tbl = attach_archive.tbl and x.part = attach_archive.part;
  if a.id is null or a.restored or a.thinned then
    raise exception 'partition % of % is not archived and dropped', part, tbl using errcode = '55000', hint = '[gnomon:not_archived]';
  end if;
  nm := t.base || '__v_p' || part;
  if to_regclass('_gnomon.' || quote_ident(nm)) is not null then
    raise exception 'partition % of % is still here', part, tbl using errcode = '55000', hint = '[gnomon:not_archived]';
  end if;
  if e.setup is not null then execute e.setup; end if;
  ddl := replace(replace(replace(replace(replace(replace(e.create_template,
           '{table}', '_gnomon.' || quote_ident(nm)), '{parent}', _gnomon.obj(t, 'v')),
           '{from}', part::text), '{to}', (part + 1)::text), '{location}', quote_literal(location)),
           '{duckdb_read}', quote_literal('read_parquet(' || quote_literal(location) || ')'));
  perform set_config('gnomon._in_ddl', '1', true);
  execute ddl;
  perform set_config('gnomon._in_ddl', '', true);
  execute format('grant select on _gnomon.%I to gnomon_reader, gnomon_admin', nm);
  update gnomon.archive x set foreign_rel = '_gnomon.' || quote_ident(nm), engine = attach_archive.engine where x.id = a.id;
  perform gnomon._bump();
  return '_gnomon.' || quote_ident(nm);
end $$;

create function gnomon.detach_archive(tbl regclass, part int4) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; a gnomon.archive;
begin
  tbl := _gnomon.base_rel(tbl);
  if not pg_has_role(_gnomon.who(), 'gnomon_admin', 'member') then
    raise exception 'detaching archives requires gnomon_admin' using errcode = '42501', hint = '[gnomon:archiving_requires_gnomon_admin]';
  end if;
  select * into t from gnomon.tracked x where x.rel = $1;
  select * into a from gnomon.archive x where x.tbl = detach_archive.tbl and x.part = detach_archive.part;
  if a.foreign_rel is null then return; end if;
  perform set_config('gnomon._in_ddl', '1', true);
  if to_regclass(a.foreign_rel) is not null then
    execute format('alter table %s detach partition %s', _gnomon.obj(t, 'v'), a.foreign_rel);
    execute format('drop foreign table %s', a.foreign_rel);
  end if;
  perform set_config('gnomon._in_ddl', '', true);
  update gnomon.archive x set foreign_rel = null, engine = null where x.id = a.id;
end $$;

create function gnomon.restore_done(tbl regclass, part int4) returns void language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
begin
  if not pg_has_role(_gnomon.who(), 'gnomon_admin', 'member') then
    raise exception 'this requires gnomon_admin' using errcode = '42501', hint = '[gnomon:requires_gnomon_admin]';
  end if;
  update gnomon.archive set restored = true, thinned = false where archive.tbl = restore_done.tbl and archive.part = restore_done.part;
  -- the horizon falls back to what is still archived, or dropped for good
  perform _gnomon.set_horizon((select id from gnomon.tracked where rel = _gnomon.base_rel(restore_done.tbl)));
end $$;

-------------------------------------------------------------------------------
-- Thawing archived history
-------------------------------------------------------------------------------
insert into gnomon.setting_default values
  ('thaw_max_rows', '50000000', 'Largest thaw a read may ask for, in archived rows; beyond it, gnomon restore by hand.'),
  ('thaw_ttl', '1 day', 'How long a thawed partition stays before it is dropped again (the file stays in the store).'),
  ('thaw_wait', 'off', 'How long gnomon.use and gnomon.begin wait for archived history already requested to be thawed, e.g. 2 min; off: they return and reads say "being thawed". The session setting gnomon.thaw_wait overrides it. CALL gnomon.thaw(at, wait) requests and waits.'),
  ('cold_scans', 'thaw', 'Reads that need archives attached in place: allow (read through the foreign partitions; keyed reads are fine, scans slow), thaw (ask for a thaw first, as for any archive), refuse.');

-- The archived partitions a read at c needs: every one from that moment up to the horizon (a
-- read looks at all later partitions to see what changed).
create function gnomon.thaw_needed(at text) returns table(tbl regclass, part int4, rows bigint, uri text)
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare c gnomon.coord := gnomon.resolve_coord(thaw_needed.at);
begin
  return query select a.tbl, a.part, a.rows, a.uri from gnomon.archive a join gnomon.tracked t on t.rel = a.tbl
                where not a.restored and not a.thinned and a.key_hi >= gnomon._kxmin(c) and _gnomon.can_read(a.tbl)
                  and (a.foreign_rel is null or gnomon._cfg('cold_scans') <> 'allow')
                order by a.tbl::text, a.part;
end $$;

-- Ask for them: rows in gnomon.thaw_request, and a notification for the daemon's job loop. They
-- count once the transaction that asked commits (gnomon.use in autocommit does).
create function gnomon.request_thaw(at text) returns table(tbl regclass, part int4, rows bigint, status text)
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare n bigint; mx bigint := gnomon._cfg('thaw_max_rows')::bigint; r record;
begin
  select coalesce(sum(x.rows), 0) into n from gnomon.thaw_needed(request_thaw.at) x
   where not exists (select 1 from gnomon.thaw_request q where q.tbl = x.tbl and q.part = x.part and q.status in ('pending', 'thawing', 'thawed'));
  if n > mx then
    raise exception 'a read at % needs % archived row(s) thawed, more than thaw_max_rows (%)', request_thaw.at, n, mx
      using errcode = '54000', hint = 'Restore by hand: gnomon restore <table> <partition>. [gnomon:thaw_too_large]';
  end if;
  for r in select * from gnomon.thaw_needed(request_thaw.at) loop
    insert into gnomon.thaw_request(tbl, part, requested_by) values (r.tbl, r.part, _gnomon.who()) on conflict do nothing;
  end loop;
  perform pg_notify('gnomon_thaw', request_thaw.at);
  return query select q.tbl, q.part, a.rows, q.status from gnomon.thaw_request q join gnomon.archive a on a.tbl = q.tbl and a.part = q.part
                where q.status in ('pending', 'thawing', 'thawed') and (q.tbl, q.part) in (select x.tbl, x.part from gnomon.thaw_needed(request_thaw.at) x);
end $$;

-- Waiting for a thaw. The daemon restores what is requested, but a request made by
-- the waiting transaction is invisible to it until that transaction commits, so a function such
-- as gnomon.use can only wait for requests made earlier; the procedure gnomon.thaw requests,
-- commits, then waits.
create function _gnomon.thaw_wait_setting() returns interval language sql stable as $$
  select nullif(nullif(coalesce(nullif(current_setting('gnomon.thaw_wait', true), ''), gnomon._cfg('thaw_wait')), 'off'), '0')::interval
$$;

create function _gnomon.thaw_wait_for(at text, wait interval) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare t0 timestamptz := clock_timestamp(); f record;
begin
  loop
    exit when not exists (select 1 from gnomon.thaw_needed(at));
    select q.tbl, q.part, q.error into f from gnomon.thaw_request q join gnomon.thaw_needed(at) x on x.tbl = q.tbl and x.part = q.part
     where q.status = 'failed' order by q.id desc limit 1;
    if found then
      raise exception 'thawing partition % of % failed: %', f.part, f.tbl, f.error
        using errcode = '55000', hint = 'gnomon thaw status shows it; gnomon restore restores by hand. [gnomon:thaw_failed]';
    end if;
    if clock_timestamp() - t0 > wait then
      raise exception 'archived history for % is still being thawed after %', at, wait
        using errcode = '55000', hint = 'Is gnomon daemon running? gnomon.thaw_status() shows the queue. [gnomon:thawing]';
    end if;
    perform pg_sleep(0.2);
  end loop;
end $$;

-- gnomon.use's side: request what the moment needs; with thaw_wait set, wait when every request it
-- needs was made before this transaction. True when the history is there to read.
create function _gnomon.thaw_or_wait(at text) returns bool language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare w interval := _gnomon.thaw_wait_setting(); mine text;
begin
  perform gnomon.request_thaw(at);
  -- (after the request: inserting it is what gives this transaction an id)
  mine := (pg_current_xact_id_if_assigned()::text::bigint % 4294967296)::text;
  if w is null or exists (select 1 from gnomon.thaw_request q join gnomon.thaw_needed(at) x on x.tbl = q.tbl and x.part = q.part
                            where q.status in ('pending', 'failed') and q.xmin::text = mine) then
    return false;
  end if;
  perform _gnomon.thaw_wait_for(at, w);
  return true;
end $$;

-- Request the archived history a moment needs, commit, and wait until the daemon has restored it
-- (or wait passes): CALL gnomon.thaw('tag:release-1'). Outside a transaction block only, since it
-- commits the request for the daemon to see.
create procedure gnomon.thaw(at text, wait interval default interval '5 minutes')
language plpgsql as $$
begin
  perform gnomon.request_thaw(at);
  commit;
  perform _gnomon.thaw_wait_for(at, wait);
end $$;

create function gnomon.thaw_status() returns table(tbl regclass, part int4, status text, rows bigint, requested_at timestamptz, thawed_at timestamptz, expires_at timestamptz, error text)
language sql stable as $$
  select q.tbl, q.part, q.status, a.rows, q.requested_at, q.thawed_at, q.expires_at, q.error
    from gnomon.thaw_request q left join gnomon.archive a on a.tbl = q.tbl and a.part = q.part
   where q.status <> 'refrozen' order by q.id
$$;

-- The job loop's side: take a pending request (skip those another loop holds), and report it done.
create function gnomon.thaw_take() returns table(id bigint, tbl regclass, part int4)
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  if not pg_has_role(_gnomon.who(), 'gnomon_admin', 'member') then raise exception 'thawing requires gnomon_admin' using errcode = '42501', hint = '[gnomon:thawing_requires_gnomon_admin]'; end if;
  return query update gnomon.thaw_request q set status = 'thawing'
                where q.id = (select x.id from gnomon.thaw_request x where x.status = 'pending' order by x.id for update skip locked limit 1)
                returning q.id, q.tbl, q.part;
end $$;

create function gnomon.thaw_finish(id bigint, error text default null) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  if not pg_has_role(_gnomon.who(), 'gnomon_admin', 'member') then raise exception 'thawing requires gnomon_admin' using errcode = '42501', hint = '[gnomon:thawing_requires_gnomon_admin]'; end if;
  update gnomon.thaw_request q set status = case when thaw_finish.error is null then 'thawed' else 'failed' end, error = thaw_finish.error,
         thawed_at = case when thaw_finish.error is null then now() end,
         expires_at = case when thaw_finish.error is null then now() + gnomon._cfg('thaw_ttl')::interval end
   where q.id = thaw_finish.id;
end $$;

-- The sweeper (heartbeat): a thawed partition past its time is dropped again; the file stays.
create function gnomon.refreeze_expired() returns int
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare q gnomon.thaw_request; t gnomon.tracked; n int := 0;
begin
  for q in select * from gnomon.thaw_request x where x.status = 'thawed' and x.expires_at < now() for update skip locked loop
    select * into t from gnomon.tracked where rel = q.tbl;
    if t.id is not null and to_regclass('_gnomon.' || quote_ident(t.base || '__v_p' || q.part)) is not null then
      execute format('drop table _gnomon.%I', t.base || '__v_p' || q.part);
      update gnomon.archive set restored = false where archive.tbl = q.tbl and archive.part = q.part;
      perform _gnomon.set_horizon(t.id);
    end if;
    update gnomon.thaw_request set status = 'refrozen' where id = q.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function gnomon.refreeze_expired() from public;
grant execute on function gnomon.refreeze_expired() to gnomon_admin;

-------------------------------------------------------------------------------
-- Erasure: the one path that rewrites history
-------------------------------------------------------------------------------
-- Crypto-shredding. Erasing history inside the database does not reach WAL or
-- backups; for archives, especially in stores with object lock where gnomon erase-archives cannot
-- rewrite a file, the archiver encrypts a table's declared columns with a key per data subject,
-- and erasing the subject deletes the key. Restores and thaws decrypt; a value whose key is gone
-- comes back NULL. Ledger leaves hash the values before encryption, so verification is unchanged.
create function gnomon.set_subject(tbl regclass, subject_col name, columns name[]) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked;
begin
  tbl := _gnomon.base_rel(tbl);
  perform _gnomon.require_manage(tbl);
  select * into t from gnomon.tracked x where x.rel = $1;
  if t.id is null then raise exception '% is not tracked', tbl using hint = '[gnomon:not_tracked]'; end if;
  if not exists (select 1 from pg_attribute a where a.attrelid = tbl and a.attname = subject_col and not a.attisdropped) then
    raise exception 'column % does not exist in %', subject_col, tbl using errcode = '42703', hint = '[gnomon:no_column]';
  end if;
  if exists (select 1 from unnest(columns) c where c = any(t.key_cols) or c = subject_col
                or not exists (select 1 from pg_attribute a where a.attrelid = tbl and a.attname = c and not a.attisdropped)) then
    raise exception 'encrypted columns must exist and be neither key columns nor the subject column' using errcode = '22023', hint = '[gnomon:subject_columns]';
  end if;
  if cardinality(columns) = 0 then
    delete from gnomon.subject s where s.tbl = t.id;
    return;
  end if;
  insert into gnomon.subject(tbl, subject_col, columns, created_by) values (t.id, subject_col, columns, _gnomon.who())
    on conflict on constraint subject_pkey do update set subject_col = excluded.subject_col, columns = excluded.columns;
end $$;

-- What the archiver needs: the subject column and the encrypted columns by their storage names in
-- the version table (key columns by name, the others by slot).
create function gnomon.archive_crypto(tbl regclass) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; s gnomon.subject;
begin
  perform _gnomon.require_admin('reading archive encryption');
  select * into t from gnomon.tracked x where x.rel = _gnomon.base_rel(tbl);
  select * into s from gnomon.subject x where x.tbl = t.id;
  if s.tbl is null then return null; end if;
  return jsonb_build_object('table', _gnomon.qname(t.rel), 'keys', to_jsonb(t.key_cols),
    'subject', s.subject_col,
    'subject_storage', case when s.subject_col = any(t.key_cols) then s.subject_col::text
                            else 'gn_c' || (t.colmap ->> (select a.attnum::text from pg_attribute a where a.attrelid = t.rel and a.attname = s.subject_col)) end,
    'columns', (select jsonb_agg(jsonb_build_object('name', c, 'storage',
                   'gn_c' || (t.colmap ->> (select a.attnum::text from pg_attribute a where a.attrelid = t.rel and a.attname = c)))) from unnest(s.columns) c));
end $$;

-- The keys of some subjects (made for the ones that have none, when asked to).
create function gnomon.subject_keys(tbl regclass, subjects text[], create_missing bool default false) returns table(subject text, key bytea)
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare tid int := (select x.id from gnomon.tracked x where x.rel = _gnomon.base_rel(tbl));
begin
  perform _gnomon.require_admin('reading subject keys');
  if create_missing then
    insert into _gnomon.subject_key(tbl, subject, key)
    select tid, s, uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid()) from unnest(subjects) s
     where not exists (select 1 from gnomon.subject_erased e where e.tbl = tid and e.subject = s)
    on conflict do nothing;
  end if;
  return query select k.subject, k.key from _gnomon.subject_key k where k.tbl = tid and k.subject = any(subjects);
end $$;
revoke all on function gnomon.subject_keys(regclass, text[], bool) from public;
grant execute on function gnomon.subject_keys(regclass, text[], bool) to gnomon_admin;

-- Erase a data subject: its key goes (every archive of the table forgets the subject's encrypted
-- values), and the declared columns are erased in the database for every key of the subject.
create function gnomon.erase_subject(tbl regclass, subject text, reason text) returns jsonb
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; s gnomon.subject; k jsonb; n int := 0; keyed bool;
begin
  tbl := _gnomon.base_rel(tbl);
  if not pg_has_role(_gnomon.who(), 'gnomon_admin', 'member') then
    raise exception 'erasure requires gnomon_admin' using errcode = '42501', hint = '[gnomon:erasure_requires_gnomon_admin]';
  end if;
  select * into t from gnomon.tracked x where x.rel = $1;
  select * into s from gnomon.subject x where x.tbl = t.id;
  if s.tbl is null then raise exception '% has no data subject (gnomon.set_subject)', tbl using errcode = '22023', hint = '[gnomon:no_subject]'; end if;
  delete from _gnomon.subject_key x where x.tbl = t.id and x.subject = erase_subject.subject;
  keyed := found;
  insert into gnomon.subject_erased(tbl, subject, reason, erased_by) values (t.id, erase_subject.subject, reason, _gnomon.who())
    on conflict do nothing;
  for k in execute format('select distinct jsonb_build_object(%s) from %s where %I::text = $1',
                          (select string_agg(format('%L, %I', c, c), ', ') from unnest(t.key_cols) c), tbl, s.subject_col) using subject loop
    perform gnomon.erase(tbl, k, s.columns::text[], reason);
    n := n + 1;
  end loop;
  return jsonb_build_object('subject', subject, 'key_deleted', keyed, 'rows_erased', n);
end $$;

create function gnomon.erase(tbl regclass, key jsonb, columns text[], reason text) returns jsonb
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp
set timezone = 'UTC' set datestyle = 'ISO, YMD' set intervalstyle = 'postgres' set extra_float_digits = 1 set bytea_output = 'hex' as $$
declare t gnomon.tracked; cs _gnomon.col[]; c _gnomon.col; hashes jsonb := '{}'; v record; sfx text; keq text; vkeq text;
        rid int8; n_v bigint := 0; n_b bigint := 0; n bigint; h bytea; kvn jsonb;
begin

  tbl := _gnomon.base_rel(tbl);  if not pg_has_role(_gnomon.who(), 'gnomon_admin', 'member') then
    raise exception 'erasure requires gnomon_admin' using errcode = '42501', hint = '[gnomon:erasure_requires_gnomon_admin]';
  end if;
  select * into t from gnomon.tracked where rel = tbl;
  if t.id is null then raise exception '% is not tracked', tbl using hint = '[gnomon:not_tracked]'; end if;
  cs := _gnomon.tcols(t.id);
  if exists (select 1 from unnest(columns) x where x = any(t.key_cols)) then
    raise exception 'key columns cannot be erased; delete the row and erase its other columns' using hint = '[gnomon:key_columns_cannot_erased]';
  end if;
  keq := (select string_agg(format('%s = ($1->>%L)::%s', k.q, k.raw, k.typ), ' and ') from unnest(_gnomon.keys(cs)) k);
  if t.wide_key then
    execute format('select gn_rid from %s where %s', _gnomon.obj(t, 'id'), keq) into rid using key;
    vkeq := 'gn_rid = $2';
  else
    vkeq := keq;
  end if;
  -- the key's values in key-column order, through the column types
  execute format('select jsonb_agg(to_jsonb(r) -> u.kc order by u.o) from jsonb_populate_record(null::%s, $1) r, unnest($2::text[]) with ordinality u(kc, o)', tbl)
    into kvn using key, t.key_cols;
  perform set_config('gnomon._erasing', '1', true);
  -- the ledger's hashes of the values being erased, per version and slot (format 2 leaves), so
  -- ledger checks still pass and still cover the rest of the row's history
  hashes := jsonb_build_object('format', 2, 'versions',
    (select coalesce(jsonb_object_agg(r.vkey || '/' || r.vlsn, r.vh) filter (where r.vh <> '{}'), '{}')
       from _gnomon.leaf2_rows(t.id, null, null, kvn,
                               array(select c2.slot from unnest(_gnomon.vals(cs)) c2 where c2.raw = any(columns))) r));
  -- version rows: values and blob references
  foreach c in array _gnomon.vals(cs) loop
    if c.raw <> all(columns) then continue; end if;
    if c.large then
      for h in execute format('select distinct gn_h%s from %s where %s and gn_h%s is not null', c.slot, _gnomon.obj(t, 'v'), vkeq, c.slot) using key, rid loop
        execute format('update %s set gn_h%s = null where %s and gn_h%s = $3', _gnomon.obj(t, 'v'), c.slot, vkeq, c.slot) using key, rid, h;
        execute format('delete from _gnomon.blob b where b.h = $1 and not exists (select 1 from %s where gn_h%s = $1)', _gnomon.obj(t, 'v'), c.slot) using h;
      end loop;
    end if;
    execute format('update %s set gn_c%s = null where %s and gn_c%s is not null', _gnomon.obj(t, 'v'), c.slot, vkeq, c.slot) using key, rid;
    get diagnostics n = row_count; n_v := n_v + n;
  end loop;
  -- branch heads and branch history
  foreach sfx in array array['b', 'b_u', 'bv', 'bv_u'] loop
    execute format('update %s set %s where %s', _gnomon.obj(t, sfx),
                   (select string_agg(format('%I = null', x), ', ') from unnest(columns) x), keq) using key;
    get diagnostics n = row_count; n_b := n_b + n;
  end loop;
  -- the current table, without writing a new version
  execute format('update %s set %s where %s', t.rel, (select string_agg(format('%I = null', x), ', ') from unnest(columns) x), keq) using key;
  perform set_config('gnomon._erasing', '', true);
  insert into gnomon.erasure(tbl, key, cols, reason, hashes) values (tbl, key, columns, reason, hashes);
  return jsonb_build_object('versions', n_v, 'branch_rows', n_b,
    'note', 'WAL, backups and replicas keep the old values until they expire; archived Parquet files are rewritten by `gnomon erase-archives`.');
end $$;

-------------------------------------------------------------------------------
-- Heartbeat: ticks, scheduled changes, watching, ledger, partitions, scratch sweeping
-------------------------------------------------------------------------------
create function gnomon.heartbeat(do_watch bool default true, do_ledger bool default true) returns jsonb
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare c gnomon.coord; s int; w int := 0; b bigint; p int := 0; t gnomon.tracked; sw int; lr text;
        q int; ex jsonb; st int; ir int; ck int; ar int;
begin
  c := gnomon._do_tick(false);
  s := gnomon.apply_scheduled();
  if do_watch then w := gnomon.watch(); end if;
  if do_ledger then b := gnomon.seal_ledger(); end if;
  for t in select * from gnomon.tracked loop p := p + _gnomon.ensure_parts(t.id); end loop;
  sw := gnomon.sweep_scratch();
  perform gnomon.refreeze_expired();
  -- quotas, expiry, approvals gone stale, idle assigned branches
  q := gnomon.check_quotas();
  ex := gnomon.expire_branches();
  update gnomon.change_request x set status = 'open' where x.status = 'approved' and not gnomon._cr_approved(x.id);
  get diagnostics st = row_count;
  ir := gnomon._idle_reviews();
  ck := gnomon.run_checkpoint_policies();
  ar := gnomon.auto_rebase_branches();
  -- merge tokens outlive nothing but their transaction (and never another cluster's)
  delete from _gnomon.merge_txn where epoch <> gnomon.current_epoch() or xid < pg_snapshot_xmin(pg_current_snapshot());
  select value into lr from gnomon.setting where name = 'retention_last_run';
  if lr is null or lr::timestamptz < now() - interval '1 hour' then
    perform gnomon.apply_retention();
    insert into gnomon.setting(name, value, doc) values ('retention_last_run', now()::text, 'Last automatic retention pass.')
      on conflict (name) do update set value = excluded.value;
  end if;
  return jsonb_build_object('tick', gnomon.coord_text(c), 'scheduled_applied', s, 'warnings', w, 'ledger_block', b,
                            'partitions_created', p, 'scratch_swept', sw, 'over_quota', q, 'expired', ex,
                            'approvals_stale', st, 'reviews_opened', ir, 'checkpoints', ck, 'auto_rebased', ar);
end $$;
grant execute on function gnomon.heartbeat(bool, bool) to gnomon_admin;

-------------------------------------------------------------------------------
-- gnomon doctor
-------------------------------------------------------------------------------
create function gnomon.doctor(sample int default 100) returns table(check_name text, status text, detail text)
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; lt timestamptz; n bigint; bad bigint; r record; cm bool := coalesce(current_setting('gnomon.c_module', true), '') = 'on';
begin
  select max(at) into lt from gnomon.tick;
  check_name := 'ticks';
  if lt is null then status := 'warn'; detail := 'no ticks yet: as-of by timestamp needs gnomon.heartbeat() every second (worker, pg_cron or `gnomon daemon`)';
  elsif lt < now() - interval '1 minute' and gnomon._tick_due() then
    -- changes are waiting for a tick: nothing is ticking (an idle database writes no ticks)
    status := 'warn'; detail := format('last tick %s ago and changes since: is the heartbeat running? timestamp resolution degrades', date_trunc('second', now() - lt));
  else status := 'ok'; detail := format('last tick %s%s', lt, case when lt < now() - interval '1 minute' then ' (nothing changed since)' else '' end); end if;
  return next;

  -- a partition number is the xid over the table's part_span, up to 999,999 per epoch: past that,
  -- every new version lands in the last partition, which then never rolls over (retention,
  -- dropping and archiving work in whole partitions)
  for t in select * from gnomon.tracked where mode = 'known' order by id loop
    if gnomon._xid(pg_snapshot_xmax(pg_current_snapshot())) / greatest(t.part_span, 1) > 900000 then
      check_name := 'partitions'; status := 'warn';
      detail := format('%s: part_span %s is too small for this cluster''s xids (partition %s of at most 999999); new versions will soon all share one partition',
                       t.rel, t.part_span, gnomon._xid(pg_snapshot_xmax(pg_current_snapshot())) / greatest(t.part_span, 1));
      return next;
    end if;
  end loop;

  check_name := 'event_triggers';
  if exists (select 1 from pg_event_trigger where evtname in ('gnomon_ddl_start','gnomon_ddl_end') and evtenabled <> 'D') then
    status := 'ok'; detail := 'DDL on tracked tables re-syncs automatically';
  else status := 'warn'; detail := 'no event triggers: run gnomon.sync() after DDL; branch writes check fingerprints'; end if;
  return next;

  for t in select * from gnomon.tracked order by id loop
    check_name := 'triggers ' || t.rel::text;
    if exists (select 1 from pg_trigger where tgrelid = t.rel and tgname like 'gnomon\_v%' and tgenabled = 'D') then
      status := 'error'; detail := 'the versioning trigger is disabled: writes are not recorded';
    elsif not exists (select 1 from pg_trigger where tgrelid = t.rel and tgname like 'gnomon\_v%') then
      status := 'error'; detail := 'the versioning trigger is missing';
    else status := 'ok'; detail := t.write_mode || ' mode'; end if;
    return next;

    check_name := 'fingerprint ' || t.rel::text;
    if t.fingerprint is distinct from _gnomon.fingerprint(t.rel) then status := 'warn'; detail := 'definition changed since last sync: run gnomon.sync()';
    else status := 'ok'; detail := 'in sync'; end if;
    return next;

    -- consistency: sampled current rows against their latest versions (catches disabled triggers)
    if t.mode = 'known' then
      execute format($q$select count(*), count(*) filter (where img is distinct from cur) from (
          select to_jsonb(gn_cur) as cur,
                 (select %1$s(%2$s, v.gn_key, v.gn_lsn) from %3$s v where %4$s order by v.gn_key desc, v.gn_lsn desc limit 1) as img,
                 exists (select 1 from %3$s v where %4$s) as has
            from %5$s gn_cur tablesample system (least(100, greatest(1, %6$s)))) s where has$q$,
        _gnomon.obj(t, 'vrow'),
        case when t.wide_key then format('(select jsonb_build_object(''gn_rid'', i.gn_rid) from %s i where %s)', _gnomon.obj(t, 'id'), _gnomon.eqs(_gnomon.keys(_gnomon.cols(t.rel)), 'i', 'gn_cur'))
             else _gnomon.key_sql(t, 'gn_cur') end,
        _gnomon.obj(t, 'v'),
        case when t.wide_key then format('v.gn_rid = (select i.gn_rid from %s i where %s)', _gnomon.obj(t, 'id'), _gnomon.eqs(_gnomon.keys(_gnomon.cols(t.rel)), 'i', 'gn_cur'))
             else _gnomon.eqs(_gnomon.keys(_gnomon.cols(t.rel)), 'v', 'gn_cur') end,
        t.rel, sample) into n, bad;
      check_name := 'consistency ' || t.rel::text;
      if bad > 0 then status := 'error'; detail := format('%s of %s sampled rows differ from their latest version (writes with triggers disabled?)', bad, n);
      else status := 'ok'; detail := format('%s sampled rows match', n); end if;
      return next;
      execute format('select count(*) from %s', _gnomon.obj(t, 'v_d')) into n;
      if n > 0 then
        check_name := 'partitions ' || t.rel::text; status := 'warn';
        detail := format('%s versions in the default partition; gnomon.heartbeat() moves them', n);
        return next;
      end if;
    end if;
  end loop;

  check_name := 'branch_dml';
  if cm then status := 'ok'; detail := 'C module loaded: FOR UPDATE, ON CONFLICT and TRUNCATE work on branches';
  else status := 'warn';
       detail := 'SQL-only mode: on branches SELECT ... FOR UPDATE takes no row locks, INSERT ... ON CONFLICT (cols) fails, TRUNCATE needs gnomon.truncate(); branch-per-request apps with concurrent writers need the C module';
  end if;
  return next;

  for r in select b.name, b.status from gnomon.branch b where b.kind = 'scratch' and b.status = 'lost' loop
    check_name := 'branch ' || r.name; status := 'warn'; detail := 'scratch branch lost in a restart; gnomon.sweep_scratch() drops it';
    return next;
  end loop;
  for r in select w.branch, count(*) as n from gnomon.warning w group by w.branch loop
    check_name := 'warnings ' || (select name from gnomon.branch where id = r.branch); status := 'warn';
    detail := format('%s early conflict warning(s); see gnomon.warning', r.n);
    return next;
  end loop;
  -- foreign keys with no index on the child's columns (reverse lookups scan: the graph
  -- and branch foreign-key checks read them)
  for r in select c.conname, c.conrelid::regclass as child, c.confrelid::regclass as parent
             from pg_constraint c
            where c.contype = 'f' and (c.conrelid in (select rel from gnomon.tracked) or c.confrelid in (select rel from gnomon.tracked))
              and not exists (select 1 from pg_index i where i.indrelid = c.conrelid
                                 and (i.indkey::int2[])[0:cardinality(c.conkey) - 1] @> c.conkey
                                 and (i.indkey::int2[])[0:cardinality(c.conkey) - 1] <@ c.conkey) loop
    check_name := 'fk_index ' || r.child::text; status := 'warn';
    detail := format('foreign key %s to %s has no index on its columns: a reverse lookup (gnomon.neighbors, a parent''s delete on a branch) scans %s',
                     r.conname, r.parent, r.child);
    return next;
  end loop;
  -- a mask on a key or foreign-key column that is not deterministic breaks foreign
  -- keys in a masked export
  for r in select m.profile, m.tbl, m.col from gnomon.mask_rule m
            where m.expr !~* 'gnomon\.mask_(hash|int|email)|md5\(|sha(224|256|384|512)\('
              and exists (select 1 from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any(c.conkey)
                           where c.conrelid = m.tbl and c.contype in ('p', 'f', 'u') and a.attname = m.col) loop
    check_name := 'mask ' || r.profile || ' ' || r.tbl::text || '.' || r.col; status := 'warn';
    detail := 'a key or foreign-key column masked by an expression that may not be deterministic: use gnomon.mask_hash, mask_int or mask_email';
    return next;
  end loop;
  -- assigned roles whose branch is gone, and branches over quota
  -- (a stopped agent's role keeps its last assignment on purpose: it cannot log in)
  for r in select a.role from gnomon.assignment a join gnomon.branch b on b.id = a.branch where b.status <> 'open'
              and not exists (select 1 from gnomon.agent g where g.role = a.role and g.status = 'stopped') loop
    check_name := 'assignment ' || r.role; status := 'warn';
    detail := 'the role is assigned to a branch that is no longer open: its sessions cannot write (gnomon agent next, or gnomon.assign)';
    return next;
  end loop;
end $$;
grant execute on function gnomon.doctor(int) to public;
