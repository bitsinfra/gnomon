-- Read context: which branch, which coordinate, which lineage.
-- Every routing view and policy reads the context through the stable functions below,
-- evaluated once per statement as initplans.

create type _gnomon.ctx as (
  branch    int,             -- 0 = main
  kind      text,            -- main | logged | scratch
  status    text,
  asof      gnomon.coord,    -- null = now
  lb        int[],           -- branch levels, current branch first; main excluded
  lc        gnomon.coord[],  -- cutoff per level (null = now)
  main_cut  gnomon.coord,    -- main's cutoff (null when reading main now)
  main_xmin int8,
  valid_at  timestamptz,
  main_now  bool,
  name      text             -- branch name ('' for main)
);

-- Resolve a reference to a coordinate: coordinate text, tag:<name>, 'now', or a timestamp
-- (resolved to the latest tick at or before it).
create function gnomon.resolve_coord(ref text) returns gnomon.coord
language plpgsql stable as $$
declare c gnomon.coord; ts timestamptz;
begin
  if ref is null or btrim(ref) = '' then return null; end if;
  ref := btrim(ref);
  if ref = 'now' then return gnomon.coordinate(); end if;
  if ref ~ '^e\d+:' then return gnomon.coord(ref); end if;
  if ref like 'tag:%' then
    c := (select t.coord from gnomon.tag t where t.name = substr(ref, 5));
    if c is null then raise exception 'unknown gnomon tag "%"', substr(ref, 5) using hint = '[gnomon:unknown_tag]'; end if;
    return c;
  end if;
  begin
    ts := ref::timestamptz;
  exception when others then
    raise exception 'cannot resolve "%" to a gnomon coordinate', ref
      using hint = 'Use a coordinate (e1:...), tag:<name>, now, or a timestamp. [gnomon:cannot_resolve_coordinate]';
  end;
  if ts > now() then
    raise exception 'gnomon.as_of % is in the future', ts using hint = '[gnomon:as_of_future]';
  end if;
  c := (select t.coord from gnomon.tick t where t.at <= ts order by t.at desc, t.id desc limit 1);
  if c is null then
    raise exception 'no gnomon tick at or before %', ts
      using hint = 'Ticks are written by gnomon.heartbeat() (worker, pg_cron or the CLI daemon). [gnomon:no_tick_before]';
  end if;
  return c;
end $$;

create function gnomon._branch_row(name text) returns gnomon.branch
language plpgsql stable as $$
declare b gnomon.branch;
begin
  if name is null or name = '' or name = 'main' then
    select * into b from gnomon.branch where id = 0;
    return b;
  end if;
  select * into b from gnomon.branch where branch.name = _branch_row.name;
  if b.id is null then
    raise exception 'unknown gnomon branch "%"', name using errcode = '42704',
      hint = coalesce('Open branches with a similar name: ' || (
               select string_agg(x.name, ', ' order by x.name) from (
                 select x.name from gnomon.branch x
                  where x.id <> 0 and x.status = 'open'
                    and (x.name like left(_branch_row.name, greatest(2, length(_branch_row.name) / 2)) || '%'
                         or _branch_row.name like left(x.name, greatest(2, length(x.name) / 2)) || '%')
                  order by x.name limit 5) x) || '. ', '') || '[gnomon:unknown_branch]';
  end if;
  return b;
end $$;

-- The base (lineage) of a branch in force at a coordinate (null = latest).
create function gnomon._base_at(b int, at_c gnomon.coord) returns gnomon.branch_base
language sql stable as $$
  select bb.* from gnomon.branch_base bb
   where bb.branch = $1
     and ($2 is null or bb.since_key is null or gnomon._vis(bb.since_key, bb.since_xoff, $2))
   order by bb.id desc limit 1
$$;

-- A session that reads or writes a scratch branch holds a shared session-level advisory lock on
-- it until it ends, however the branch was chosen (gnomon.use, a setting, the C module), and the
-- sweeper never drops a branch it cannot lock: a branch in use is never swept as abandoned.
create function gnomon._hold_scratch(b int) returns void language plpgsql volatile as $$
declare held text := coalesce(nullif(current_setting('gnomon._scratch_held', true), ''), ',');
begin
  if position(',' || b || ',' in held) = 0 then
    perform pg_advisory_lock_shared(1735290222, b);   -- (1735290222: gnomon's advisory lock class, 'gnmn')
    perform set_config('gnomon._scratch_held', held || b || ',', false);
  end if;
end $$;

create function gnomon._ctx_compute(bname text, asof_ref text, valid_ref text) returns _gnomon.ctx
language plpgsql stable as $$
declare r _gnomon.ctx; b gnomon.branch; bb gnomon.branch_base; n int;
begin
  b := gnomon._branch_row(bname);
  -- read isolation: a confined role reads only the branches it may (and their ancestors)
  if b.id <> 0 and not gnomon._may_read_branch(b.id) then
    raise exception 'role % may not read branch "%"', _gnomon.who(), b.name
      using errcode = '42501', hint = 'A confined role reads the branches in its access list and their ancestors. [gnomon:branch_not_readable]';
  end if;
  r.branch := b.id; r.kind := b.kind; r.status := b.status; r.name := case when b.id = 0 then '' else b.name end;
  r.asof := gnomon.resolve_coord(asof_ref);
  -- an explicit coordinate may be newer than what a standby has replayed; tags, ticks and branch
  -- cutoffs come from catalog rows committed after their coordinates, so they never are
  if asof_ref ~ '^\s*e\d+:' and pg_is_in_recovery() then perform gnomon._standby_check(r.asof); end if;
  if valid_ref is not null and valid_ref <> '' then r.valid_at := valid_ref::timestamptz; end if;
  if b.id = 0 then
    r.lb := '{}'; r.lc := '{}';
    -- a valid-time read on main reads known time now
    r.main_cut := coalesce(r.asof, case when r.valid_at is not null then gnomon.coordinate() end);
    r.main_now := r.asof is null and r.valid_at is null;
  else
    if b.status = 'lost' or (b.kind = 'scratch' and b.created_at < pg_postmaster_start_time()) then
      -- (a restart empties unlogged tables: lost, whether or not the sweeper has marked it yet)
      raise exception 'scratch branch "%" was lost in a server restart', b.name using errcode = '55000', hint = '[gnomon:scratch_branch_lost_server]';
    end if;
    if b.kind = 'scratch' and not pg_is_in_recovery() then perform gnomon._hold_scratch(b.id); end if;
    bb := gnomon._base_at(b.id, r.asof);
    if bb.id is null then
      raise exception 'branch "%" did not exist at %', b.name, gnomon.coord_text(r.asof) using hint = '[gnomon:branch_did_not_exist]';
    end if;
    n := cardinality(bb.lin_b);
    r.lb := array[b.id] || bb.lin_b[1:n-1];
    r.lc := array[r.asof] || bb.lin_c[1:n-1];
    r.main_cut := bb.lin_c[n];
    r.main_now := false;
  end if;
  r.main_xmin := gnomon._kxmin(r.main_cut);
  return r;
end $$;

-- Per-statement context with a small session cache keyed by the settings and the
-- catalog generation (bumped by anything that changes branches or bases).
create sequence gnomon._gen;
grant select on gnomon._gen to public;

create function gnomon._bump() returns void language sql volatile security definer
set search_path = pg_catalog, pg_temp as $$ select nextval('gnomon._gen'); select set_config('gnomon._ctxc', '', true); $$;

create function gnomon._ctx() returns _gnomon.ctx language plpgsql stable as $$
declare b text := current_setting('gnomon.branch', true);
        a text := current_setting('gnomon.as_of', true);
        v text := current_setting('gnomon.valid_at', true);
        g int8;
        k text; cache text := current_setting('gnomon._ctxc', true);
        r _gnomon.ctx;
begin
  if (b is null or b = '' or b = 'main') and (a is null or a = '') and (v is null or v = '') then
    return row(0, 'main', 'open', null, '{}'::int[], '{}'::gnomon.coord[], null, null, null, true, '')::_gnomon.ctx;
  end if;
  -- The cache lives for one client statement: the initplans of one query share it, and a
  -- concurrent rebase can never leave a stale lineage behind. Changes this session makes to
  -- branches or bases within a statement clear it (gnomon._bump).
  k := coalesce(b,'') || '|' || coalesce(a,'') || '|' || coalesce(v,'') || '|' ||
       statement_timestamp()::text || '|' || coalesce(pg_current_xact_id_if_assigned()::text, '');
  if cache is not null and cache <> '' and split_part(cache, chr(1), 1) = k then
    return split_part(cache, chr(1), 2)::_gnomon.ctx;
  end if;
  r := gnomon._ctx_compute(b, a, v);
  perform set_config('gnomon._ctxc', k || chr(1) || r::text, false);
  return r;
end $$;

create function gnomon._ctx_main_now() returns bool language sql stable as $$ select (gnomon._ctx()).main_now $$;
create function gnomon._ctx_branch() returns int language sql stable as $$ select (gnomon._ctx()).branch $$;
create function gnomon._ctx_asof_null() returns bool language sql stable as $$ select (gnomon._ctx()).asof is null $$;
create function gnomon._ctx_lb() returns int[] language sql stable as $$ select (gnomon._ctx()).lb $$;
create function gnomon._ctx_lc() returns gnomon.coord[] language sql stable as $$ select (gnomon._ctx()).lc $$;
create function gnomon._ctx_main_cut() returns gnomon.coord language sql stable as $$ select (gnomon._ctx()).main_cut $$;
create function gnomon._ctx_main_xmin() returns int8 language sql stable as $$ select (gnomon._ctx()).main_xmin $$;
create function gnomon._ctx_main_xmax() returns int8 language sql stable as $$ select gnomon._kxmax((gnomon._ctx()).main_cut) $$;
create function gnomon._ctx_valid_at() returns timestamptz language sql stable as $$ select coalesce((gnomon._ctx()).valid_at, now()) $$;

-- Main's cutoff for one table: a branch whose cutoff predates the table's tracking reads the
-- table as of its tracking point (there is no history before it). Explicit as-of reads on main
-- before tracking fail instead (gnomon._check_horizon).
create function gnomon._ctx_main_cut_t(tid int) returns gnomon.coord language plpgsql stable as $$
declare c gnomon.coord := (gnomon._ctx()).main_cut; t record;
begin
  if c is null then return null; end if;
  select track_key, track_xoff, track_coord into t from gnomon.tracked where id = tid;
  if gnomon._vis(t.track_key, t.track_xoff, c) then return c; end if;
  return t.track_coord;
end $$;
create function gnomon._ctx_main_xmin_t(tid int) returns int8 language sql stable as $$ select gnomon._kxmin(gnomon._ctx_main_cut_t(tid)) $$;
create function gnomon._ctx_main_xmax_t(tid int) returns int8 language sql stable as $$ select gnomon._kxmax(gnomon._ctx_main_cut_t(tid)) $$;

-- The history checkpoint a statement reads table <tid> from: the one nearest main's
-- cutoff, on either side, when it is nearer than now (a scan then rebuilds the rows changed
-- between the cutoff and the checkpoint, not every row changed since the cutoff). Null: none
-- (checkpoints off, main now, none near enough).
create function gnomon._ctx_ck(tid int) returns int language plpgsql stable
security definer set search_path = pg_catalog, pg_temp as $$
declare c gnomon.coord; k record; dnow int8; mk int8;
begin
  c := gnomon._ctx_main_cut_t(tid);
  if c is null then return null; end if;
  -- a TRUNCATE on main after the cutoff: the rows it removed are only in the checkpoint it
  -- took, whatever the setting says
  select min(x.key) into mk from _gnomon.cleared x where x.tbl = tid and x.branch = 0 and not gnomon._vis(x.key, x.xoff, c);
  if mk is not null then
    return (select h.id from gnomon.history_checkpoint h where h.tbl = tid and h.cleared_key = mk);
  end if;
  if coalesce((select value from gnomon.setting where name = 'checkpoints'), 'off') <> 'on' then return null; end if;
  -- the nearest checkpoint with no TRUNCATE marker between it and the cutoff
  select h.id, h.kx into k from gnomon.history_checkpoint h where h.tbl = tid
     and not exists (select 1 from _gnomon.cleared x where x.tbl = tid and x.branch = 0
                        and gnomon._vis(x.key, x.xoff, c) and not gnomon._vis(x.key, x.xoff, h.coord))
   order by abs(h.kx - gnomon._kxmax(c)), h.id desc limit 1;
  if k.id is null then return null; end if;
  dnow := gnomon._kxmax(gnomon.coordinate()) - gnomon._kxmax(c);
  if abs(k.kx - gnomon._kxmax(c)) >= dnow then return null; end if;
  return k.id;
end $$;
-- The earlier and the later of main's cutoff and the chosen checkpoint: the history arm rebuilds the
-- keys with a version between them.
create function gnomon._ctx_ck_lo(tid int) returns gnomon.coord language plpgsql stable as $$
declare c gnomon.coord := gnomon._ctx_main_cut_t(tid); k gnomon.coord;
begin
  k := (select h.coord from gnomon.history_checkpoint h where h.tbl = tid and h.id = gnomon._ctx_ck(tid));
  if k is null then return c; end if;
  return case when (gnomon._kxmax(k), gnomon._kxmin(k)) < (gnomon._kxmax(c), gnomon._kxmin(c)) then k else c end;
end $$;
create function gnomon._ctx_ck_hi(tid int) returns gnomon.coord language plpgsql stable as $$
declare c gnomon.coord := gnomon._ctx_main_cut_t(tid); k gnomon.coord;
begin
  k := (select h.coord from gnomon.history_checkpoint h where h.tbl = tid and h.id = gnomon._ctx_ck(tid));
  if k is null then return null; end if;
  return case when (gnomon._kxmax(k), gnomon._kxmin(k)) < (gnomon._kxmax(c), gnomon._kxmin(c)) then c else k end;
end $$;

-- Where the history arm's scan of main's versions starts: main's cutoff, or the earlier of it and
-- the chosen checkpoint.
create function gnomon._ctx_hist_xmin_t(tid int) returns int8 language plpgsql stable as $$
begin
  if gnomon._ctx_ck(tid) is null then return gnomon._ctx_main_xmin_t(tid); end if;
  return gnomon._kxmin(gnomon._ctx_ck_lo(tid));
end $$;

-- Lowest lineage level at which table <tid> was cleared (branch TRUNCATE), visible at that level's cutoff.
create function gnomon._ctx_clear(tid int) returns int language sql stable security definer
set search_path = pg_catalog, pg_temp as $$
  select min(l.ord)::int
    from unnest((gnomon._ctx()).lb) with ordinality l(br, ord)
    join _gnomon.cleared c on c.tbl = tid and c.branch = l.br
   where gnomon._vis(c.key, c.xoff, ((gnomon._ctx()).lc)[l.ord])
$$;

-------------------------------------------------------------------------------
-- Choosing a branch (2, connection recipes; 11: setting + search_path in SQL-only mode)
-------------------------------------------------------------------------------
-- scratch: route through the scratch-branch schemas (gnomon_r_<schema>__s).
create function gnomon.routing_path(base_path text default null, scratch bool default false) returns text
language plpgsql stable as $$
begin
  return _gnomon.routing_path_for(coalesce(nullif(current_setting('role'), 'none'), session_user::text), base_path, scratch);
end $$;

-- The routing path for a role (a role assigned to a branch, 9.2, gets the path of its own mask profile).
create function _gnomon.routing_path_for(r text, base_path text default null, scratch bool default false) returns text
language plpgsql stable as $$
declare out text[] := '{}'; s text; p text[]; mp int;
begin
  -- roles confined to a mask profile route through that profile's schemas
  select m.id into mp from gnomon.confined c join gnomon.mask_profile m on m.name = c.mask_profile
   where c.role = r;
  if base_path is null then
    p := current_schemas(false);
  else
    p := string_to_array(replace(base_path, ' ', ''), ',');
  end if;
  foreach s in array p loop
    s := btrim(s, '"');
    if s like 'gnomon\_r\_%' then continue; end if;
    if mp is not null and exists (select 1 from pg_namespace where nspname = format('gnomon_r_%s__m%s', s, mp)) then
      out := out || quote_ident(format('gnomon_r_%s__m%s', s, mp));
    elsif scratch and exists (select 1 from pg_namespace where nspname = 'gnomon_r_' || s || '__s') then
      out := out || quote_ident('gnomon_r_' || s || '__s');
    elsif exists (select 1 from pg_namespace where nspname = 'gnomon_r_' || s) then
      out := out || quote_ident('gnomon_r_' || s);
    end if;
    out := out || quote_ident(s);
  end loop;
  return array_to_string(out, ', ');
end $$;

-- gnomon.use(branch): session-level. gnomon.begin(branch): transaction-level (SET LOCAL), for poolers.
create function gnomon.use(branch text, as_of text default null, local bool default false, mode text default null) returns text
language plpgsql volatile as $$
declare b gnomon.branch := gnomon._branch_row(branch); orig text; p text;
begin
  if mode is not null and mode not in ('routing', 'search') then raise exception 'mode is routing or search' using hint = '[gnomon:mode_routing_search]'; end if;
  if mode = 'search' and (b.kind = 'scratch' or exists (select 1 from gnomon.confined c where c.role = _gnomon.who())) then
    raise exception 'search views are for logged branches and for roles that may read the tables themselves'
      using errcode = '42501', hint = '[gnomon:search_confined]';
  end if;
  if b.status not in ('open') and b.id <> 0 then
    raise notice 'branch "%" is %', b.name, b.status;
  end if;
  orig := nullif(current_setting('gnomon._orig_path', true), '');
  if orig is null then
    orig := current_setting('search_path');
    perform set_config('gnomon._orig_path', orig, local);
  end if;
  if b.kind = 'scratch' and pg_is_in_recovery() then
    raise exception 'scratch branch "%" is not replicated: its tables are unlogged', b.name
      using errcode = '0A000', hint = 'Read it on the primary, or use a logged branch. [gnomon:scratch_branch_not_replicated]';
  end if;
  -- the shared runs login: this transaction is bound to the run
  if b.id <> 0 and _gnomon.who() = nullif(gnomon._cfg('runs_role'), '')
     and exists (select 1 from gnomon.acl a where a.role = _gnomon.who() and a.branch = b.id) then
    perform gnomon._run_bind_as_runner(b.id);
  end if;
  -- on a standby, wait until it has replayed past the coordinate
  if as_of is not null and pg_is_in_recovery() then perform gnomon.wait_for(gnomon.resolve_coord(as_of)); end if;
  -- the reference resolves now, not at the first read: a typo fails here
  -- archived history this moment needs: ask for it to be thawed; reads say so until then
  if as_of is not null and btrim(as_of) <> '' and not pg_is_in_recovery()
     and exists (select 1 from gnomon.thaw_needed(as_of))
     and not _gnomon.thaw_or_wait(as_of) then
    raise notice 'gnomon: % archived partition(s) are being thawed for this moment; reads succeed once the daemon has restored them',
      (select count(*) from gnomon.thaw_needed(as_of));
  else
  -- (on a standby the wait above resolved it, and this statement's snapshot predates the replay)
  if as_of is not null and btrim(as_of) <> '' and not pg_is_in_recovery() then
    perform gnomon._ctx_compute(case when b.id = 0 then '' else b.name end, as_of, null);
  elsif b.id <> 0 and not gnomon._may_read_branch(b.id) then
    perform gnomon._ctx_compute(b.name, null, null);   -- raises with the reason
  end if;
  end if;
  -- archives read in place: said once, since scans through them are slow
  if as_of is not null and btrim(as_of) <> '' and not pg_is_in_recovery() and gnomon._cfg('cold_scans') = 'allow'
     and exists (select 1 from gnomon.archive a where a.foreign_rel is not null and not a.restored
                    and a.key_hi >= gnomon._kxmin(gnomon.resolve_coord(as_of))) then
    raise notice 'gnomon: % archived partition(s) are read in place for this moment (cold_scans = allow): keyed reads are fine, scans are slow',
      (select count(*) from gnomon.archive a where a.foreign_rel is not null and not a.restored and a.key_hi >= gnomon._kxmin(gnomon.resolve_coord(as_of)));
  end if;
  perform set_config('gnomon.branch', case when b.id = 0 then '' else b.name end, local);
  perform set_config('gnomon.as_of', coalesce(as_of, ''), local);
  perform set_config('gnomon._local_route', case when local then '1' else '' end, local);
  if b.id = 0 and as_of is null then
    perform set_config('search_path', orig, local);
    perform set_config('gnomon._orig_path', '', local);
    p := orig;
  else
    p := gnomon.routing_path(orig, b.kind = 'scratch');
    -- a branch on a schema version: the version's views first
    if b.schema_version is not null and b.kind <> 'scratch' and not exists (select 1 from gnomon.confined c where c.role = _gnomon.who()) then
      p := _gnomon.version_path(b.schema_version, p);
    end if;
    -- search mode: the search views first, the routing views for the rest
    if mode = 'search' then
      p := array_to_string(array(select x from (select case when e like '"gnomon\_r\_%' or e like 'gnomon\_r\_%'
                                                             then case when exists (select 1 from pg_namespace n where n.nspname = 'gnomon_q_' || regexp_replace(btrim(e, '"'), '^gnomon_r_', ''))
                                                                       then quote_ident('gnomon_q_' || regexp_replace(btrim(e, '"'), '^gnomon_r_', '')) || ', ' || e else e end
                                                             else e end as x
                                                   from unnest(string_to_array(p, ', ')) e) y), ', ');
    end if;
    perform set_config('search_path', p, local);
  end if;
  -- a branch that tracks its reads (gnomon.track_reads): the C module records them for this session
  if b.read_sample is not null and coalesce(current_setting('gnomon.c_module', true), '') = 'on' then
    perform set_config('gnomon.track_reads', case when b.read_sample > 0 then 'on' else 'off' end, local);
  end if;
  if b.id <> 0 and b.last_used < now() - interval '1 minute' and current_setting('transaction_read_only') = 'off' then
    perform gnomon._touch(b.id);
  end if;
  return p;
end $$;

create function gnomon._touch(b int) returns void language sql volatile security definer
set search_path = pg_catalog, pg_temp as $$
  update gnomon.branch set last_used = now() where id = b and last_used < now() - interval '1 minute'
$$;

-- The C module's touch: sessions it routes never call use(); it never waits.
create function gnomon._touch_nowait(name text) returns void language sql volatile security definer
set search_path = pg_catalog, pg_temp as $$
  update gnomon.branch set last_used = now()
   where id = (select b.id from gnomon.branch b where b.name = $1 and b.last_used < now() - interval '1 minute' for update skip locked)
$$;

create function gnomon.begin(branch text, as_of text default null, mode text default null) returns text
language sql volatile as $$ select gnomon.use(branch, as_of, true, mode) $$;

create function gnomon.as_of(ref text) returns text language plpgsql volatile as $$
begin
  return gnomon.use(coalesce(nullif(current_setting('gnomon.branch', true), ''), 'main'), ref);
end $$;

create function gnomon.current_branch() returns text language sql stable as $$
  select coalesce(nullif(current_setting('gnomon.branch', true), ''), 'main')
$$;

-- Connection-string recipe for a branch.
create function gnomon.connection_options(branch text, c_module bool default false) returns text
language plpgsql stable as $$
declare b gnomon.branch := gnomon._branch_row(branch); p text := gnomon.routing_path(null, b.kind = 'scratch');
begin
  if b.schema_version is not null and b.kind <> 'scratch' then p := _gnomon.version_path(b.schema_version, p); end if;
  return case when c_module and b.schema_version is null then format('-c gnomon.branch=%s', branch)
              else format('-c gnomon.branch=%s -c search_path=%s', branch, replace(p, ' ', '')) end;
end $$;
