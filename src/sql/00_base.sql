-- Gnomon SQL core: roles, schemas, catalog, coordinates, epochs, ticks, tags.

\echo Use "CREATE EXTENSION gnomon" to load this file. \quit

-------------------------------------------------------------------------------
-- Roles (cluster-wide; created once, reused by every database that installs gnomon)
-------------------------------------------------------------------------------
-- Roles are shared by every database of the cluster, and catalog rows of shared objects cannot be
-- updated by two transactions at once ("tuple concurrently updated"). So databases installing
-- gnomon at the same moment must not both write them: each role is created only if missing (a
-- concurrent creator's role is accepted), and changed only if not already as needed.
do $$
declare r text;
begin
  -- gnomon_reader_s: owner of the scratch-branch routing views (gnomon_r_<schema>__s). A member
  -- of gnomon_reader, so gnomon_reader's grants and arm policies apply to it too; one extra
  -- restrictive policy adds the unlogged touched keys. Keeping unlogged tables out of
  -- gnomon_reader's views and policies is what lets a standby read main's past and logged
  -- branches (it cannot open unlogged tables).
  foreach r in array array['gnomon_reader','gnomon_writer','gnomon_merger','gnomon_admin','gnomon_reader_s','gnomon_runner','gnomon_search'] loop
    if not exists (select 1 from pg_roles where rolname = r) then
      begin
        execute format('create role %I nologin', r);
      exception when duplicate_object or unique_violation then
        null;   -- created by a concurrent install in another database
      end;
    end if;
  end loop;
  -- merges and undo on main write tables that may carry user RLS policies
  foreach r in array array['gnomon_merger','gnomon_admin'] loop
    if not (select rolbypassrls from pg_roles where rolname = r) then
      execute format('alter role %I bypassrls', r);
    end if;
  end loop;
  -- the merge and admin paths act through gnomon_writer's branch functions too
  if not exists (select 1 from pg_auth_members m where m.roleid = 'gnomon_writer'::regrole and m.member = 'gnomon_merger'::regrole) then
    execute 'grant gnomon_writer to gnomon_merger';
  end if;
  if not exists (select 1 from pg_auth_members m where m.roleid = 'gnomon_reader'::regrole and m.member = 'gnomon_reader_s'::regrole) then
    execute 'grant gnomon_reader to gnomon_reader_s';
  end if;
end $$;

create schema _gnomon;
comment on schema _gnomon is 'Gnomon storage. No grants to application roles.';
-- Usage lets invoker-rights helpers resolve; no table in _gnomon is granted to application
-- roles, and the definer functions that write storage are not executable by them.
grant usage on schema _gnomon to public;
grant usage on schema gnomon to public;

-------------------------------------------------------------------------------
-- Coordinates
-------------------------------------------------------------------------------
create type gnomon.coord as (epoch int2, snap pg_snapshot, lsn pg_lsn);
comment on type gnomon.coord is 'A point in known time: (cluster epoch, MVCC snapshot, WAL insert LSN). Text form e<epoch>:<xmin>:<xmax>:<xip,...>@<lsn>.';

create function gnomon.coord_text(c gnomon.coord) returns text
language sql immutable strict parallel safe as
$$ select 'e' || c.epoch || ':' || c.snap::text || '@' || c.lsn::text $$;

create function gnomon.coord(t text) returns gnomon.coord
language plpgsql immutable strict parallel safe as $$
declare m text[];
begin
  m := regexp_match(btrim(t), '^e(\d+):(\d+:\d+:[0-9,]*)@([0-9A-Fa-f]+/[0-9A-Fa-f]+)$');
  if m is null then
    raise exception 'invalid gnomon coordinate "%"', t
      using hint = 'Expected e<epoch>:<xmin>:<xmax>:<xip,...>@<lsn>, for example e1:880:882:881@0/1A2B3C4. [gnomon:invalid_coordinate]';
  end if;
  return row(m[1]::int2, m[2]::pg_snapshot, m[3]::pg_lsn)::gnomon.coord;
end $$;

create cast (gnomon.coord as text) with function gnomon.coord_text(gnomon.coord);
create cast (text as gnomon.coord) with function gnomon.coord(text);

-- Key-space helpers. A version key is an int8 with the epoch in its top 16 bits and
-- greatest(xid, writer-snapshot xmax) in the low 48 bits.
create function gnomon._xid(x xid8) returns int8 language sql immutable strict parallel safe
as $$ select x::text::int8 $$;

create function gnomon._kxmin(c gnomon.coord) returns int8 language sql immutable parallel safe
as $$ select case when c is null then null else (c.epoch::int8 << 48) | gnomon._xid(pg_snapshot_xmin(c.snap)) end $$;

create function gnomon._kxmax(c gnomon.coord) returns int8 language sql immutable parallel safe
as $$ select case when c is null then 9223372036854775807 else (c.epoch::int8 << 48) | gnomon._xid(pg_snapshot_xmax(c.snap)) end $$;

-- Visibility of a stamp at a coordinate. NULL coordinate = "now" (MVCC visibility already applied).
-- Older epochs count as committed before every coordinate of a newer epoch.
create function gnomon._vis(k int8, xoff int4, c gnomon.coord) returns bool
language sql immutable parallel safe as $$
  select case
    when c is null then true
    when (k >> 48) < c.epoch then true
    when (k >> 48) > c.epoch then false
    else pg_visible_in_snapshot((((k & 281474976710655) - xoff)::text)::xid8, c.snap)
  end
$$;

-- Write-time partition number for a key and a span (in xids). Epoch-aware, fits int4.
create function gnomon._part(k int8, span int8) returns int4
language sql immutable strict parallel safe as $$
  select ((k >> 48) * 1000000 + least((k & 281474976710655) / greatest(span, 1), 999999))::int4
$$;

-------------------------------------------------------------------------------
-- Epochs
-------------------------------------------------------------------------------
create table gnomon.epoch (
  epoch      int2 primary key,
  sysid      bigint not null,
  tli        int not null default 1,
  created_at timestamptz not null default now(),
  unique (sysid, tli)
);
comment on table gnomon.epoch is 'Cluster epochs. A new epoch starts when the system identifier changes (dump/restore, pg_upgrade, logical cutover) or the timeline does (failover, point-in-time recovery).';

create function gnomon._sysid() returns bigint language sql stable parallel safe
as $$ select system_identifier from pg_control_system() $$;

-- The timeline WAL is written on now: correct from the first moment after a promotion (the
-- checkpoint record in pg_control can lag behind it). Only meaningful on a primary.
create function gnomon._tli() returns int language sql stable parallel safe
as $$ select ('x' || left(pg_walfile_name(pg_current_wal_insert_lsn()), 8))::bit(32)::int $$;

-- Why the timeline is part of the epoch: a failover or a point-in-time recovery forks history,
-- and xids assigned on the abandoned branch of it (never replicated, or past the recovery target)
-- are assigned again on the new timeline. A coordinate handed out on the old timeline may count
-- such an xid as finished; its reuse must not become visible there. Versions of a newer epoch are
-- invisible at every coordinate of an older one, so a new epoch per timeline keeps old coordinates
-- exact (they still read their own epoch), and new ones start clean.

-- Read-only lookup, safe inside stable functions and policies. On a standby: the newest epoch
-- the primary registered for this cluster (a standby writes nothing itself).
create function gnomon._epoch_ro() returns int2 language plpgsql stable parallel safe as $$
declare c text := current_setting('gnomon._epoch', true); s bigint; e int2;
begin
  if c is not null and c <> '' then return c::int2; end if;
  s := gnomon._sysid();
  if pg_is_in_recovery() then
    select max(epoch) into e from gnomon.epoch where sysid = s;
  else
    select epoch into e from gnomon.epoch where sysid = s and tli = gnomon._tli();
  end if;
  if e is null then
    select coalesce(max(epoch), 0) + 1 into e from gnomon.epoch;
  end if;
  -- a primary's sessions never outlive a timeline switch (a standby's can: no cache there)
  if not pg_is_in_recovery() then perform set_config('gnomon._epoch', e::text, false); end if;
  return e;
end $$;

-- Registering lookup for the write path; caches the epoch for the session (a session never
-- outlives a timeline switch on the primary it writes to).
create function gnomon.current_epoch() returns int2 language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
declare c text := current_setting('gnomon._epoch', true); s bigint; e int2; tl int;
begin
  if c is not null and c <> '' then return c::int2; end if;
  if pg_is_in_recovery() then return gnomon._epoch_ro(); end if;   -- never cache on a standby
  s := gnomon._sysid(); tl := gnomon._tli();
  select epoch into e from gnomon.epoch where sysid = s and tli = tl;
  if e is null then
    insert into gnomon.epoch(epoch, sysid, tli)
      select coalesce(max(epoch), 0) + 1, s, tl from gnomon.epoch
      on conflict do nothing;
    select epoch into e from gnomon.epoch where sysid = s and tli = tl;
    if e is null then  -- lost a race on the epoch number; retry once
      insert into gnomon.epoch(epoch, sysid, tli) select coalesce(max(epoch), 0) + 1, s, tl from gnomon.epoch on conflict do nothing;
      select epoch into e from gnomon.epoch where sysid = s and tli = tl;
    end if;
  end if;
  perform set_config('gnomon._epoch', e::text, false);
  return e;
end $$;

-------------------------------------------------------------------------------
-- Capturing coordinates
-------------------------------------------------------------------------------
-- Stable, so it returns the snapshot of the calling statement: "the snapshot that read used".
create function gnomon._no_coordinate_on_standby() returns gnomon.coord language plpgsql stable as $$
begin
  raise exception 'gnomon coordinates are captured on the primary only'
    using detail = 'A standby''s snapshot can reflect a commit order that never existed on the primary.',
          hint = 'Capture the coordinate on the primary; reads at a coordinate work on a standby once it has replayed past its LSN.';
end $$;
-- Plain SQL so the planner inlines it: the cost of a coordinate is the snapshot and the insert
-- position (target: under 10 µs), with the epoch read from the session's cache.
create function gnomon.coordinate() returns gnomon.coord language sql stable as $$
  select case when pg_is_in_recovery() then gnomon._no_coordinate_on_standby()
              else row(coalesce(nullif(current_setting('gnomon._epoch', true), '')::int2, gnomon._epoch_ro()),
                       pg_current_snapshot(), pg_current_wal_insert_lsn())::gnomon.coord end
$$;

-- The same coordinate, but with the calling transaction's own writes visible. A snapshot taken
-- inside a writing transaction usually has xmax <= its own xid, so its own changes would not be
-- visible at it; tracking points and merge results need them to be. xids assigned between the
-- snapshot's xmax and our own are treated as in progress, which is what they were.
create function gnomon._coordinate_self() returns gnomon.coord language plpgsql volatile as $$
declare c gnomon.coord := gnomon.coordinate(); x int8 := gnomon._xid(pg_current_xact_id());
        xmn int8; xmx int8; xip int8[];
begin
  xmx := gnomon._xid(pg_snapshot_xmax(c.snap));
  if x < xmx then return c; end if;
  xmn := gnomon._xid(pg_snapshot_xmin(c.snap));
  xip := array(select gnomon._xid(v) from pg_snapshot_xip(c.snap) v where gnomon._xid(v) <> x)
         || array(select g from generate_series(xmx, x - 1) g);
  xmn := least(xmn, coalesce((select min(v) from unnest(xip) v), x));
  return row(c.epoch,
             (xmn || ':' || (x + 1) || ':' || array_to_string(array(select distinct v from unnest(xip) v order by v), ','))::pg_snapshot,
             c.lsn)::gnomon.coord;
end $$;

create function gnomon.coordinate_text() returns text language sql stable
as $$ select gnomon.coord_text(gnomon.coordinate()) $$;

-- Stamp for a write made now by this transaction: (key, xoff). 4.1.
create type gnomon.stamp as (key int8, xoff int4, lsn pg_lsn, role oid);

create function gnomon._stamp() returns gnomon.stamp language plpgsql volatile as $$
declare x int8 := gnomon._xid(pg_current_xact_id());
        r int8 := greatest(x, gnomon._xid(pg_snapshot_xmax(pg_current_snapshot())));
begin
  return row((gnomon.current_epoch()::int8 << 48) | r, (r - x)::int4, pg_current_wal_insert_lsn(),
             quote_ident(coalesce(nullif(current_setting('role'), 'none'), session_user::text))::regrole::oid)::gnomon.stamp;
end $$;

-- A stamp raised to key prev (same xid; xoff grows by the difference) when prev is larger.
create function gnomon._restamp(st gnomon.stamp, prev int8) returns gnomon.stamp language sql immutable as $$
  select case when prev is null or prev <= st.key then st
              else row(prev, st.xoff + (prev - st.key)::int4, st.lsn, st.role)::gnomon.stamp end
$$;

-- A fresh xid, as a clock that is ahead of every stamp already taken (so version keys along a row
-- never decrease under REPEATABLE READ and SERIALIZABLE). An INSERT that follows a concurrent, committed DELETE of
-- the same key succeeds at those levels (PostgreSQL raises no serialization error: the old row is
-- dead), and its stamp, from the transaction snapshot, can be older than that delete's. Plain SQL
-- cannot take a fresh snapshot there, but a subtransaction's xid is assigned now: above the
-- deleter's xid and above any snapshot xmax taken before. The subtransaction is rolled back,
-- which advances latestCompletedXid, so every later snapshot's xmax is above it (claim 3 holds).
create unlogged table _gnomon.clock (x int);
create function gnomon._fresh_xid() returns int8 language plpgsql volatile as $$
declare cx xid; me int8 := gnomon._xid(pg_current_xact_id()); r int8;
begin
  begin
    insert into _gnomon.clock values (0) returning xmin into cx;
    raise sqlstate 'GNCLK';
  exception when sqlstate 'GNCLK' then null;
  end;
  r := (me & ~4294967295::int8) | cx::text::int8;   -- widen with our own xid's epoch: it came later
  if r < me then r := r + 4294967296; end if;
  return r;
end $$;
revoke all on function gnomon._fresh_xid() from public;
grant execute on function gnomon._fresh_xid() to gnomon_writer;
grant select, insert on _gnomon.clock to gnomon_writer;
-- The stamp of a write that may follow one its snapshot cannot see (REPEATABLE READ or above).
create function gnomon._stamp_fresh(st gnomon.stamp) returns gnomon.stamp language sql volatile as $$
  select case when current_setting('transaction_isolation') = 'read committed' then st
              else gnomon._restamp(st, ((st.key >> 48) << 48) | gnomon._fresh_xid()) end
$$;

-- True inside a logical-replication apply worker (or any session with a replication origin set
-- up). The underlying function is superuser-only, so the trigger reaches it through this wrapper.
create function _gnomon.is_apply() returns bool language sql stable security definer
set search_path = pg_catalog, pg_temp as $$ select pg_replication_origin_session_is_setup() $$;
revoke all on function _gnomon.is_apply() from public;
grant execute on function _gnomon.is_apply() to gnomon_writer;

-- Has replay reached a coordinate's LSN? The coordinate holds the insert position, which at a
-- WAL page boundary points past the page header (24 bytes, 40 on a segment's first page) while
-- replay stops at the boundary: replay at that boundary has everything inserted before capture.
create function gnomon._lsn_reached(r pg_lsn, target pg_lsn) returns bool language sql stable as $$
  select r >= target
      or (target - r in (24, 40)
          and (r - '0/0'::pg_lsn) % current_setting('wal_block_size')::numeric = 0)
$$;

-- Waits until a standby has replayed past a coordinate. No-op on the primary.
-- Notes when the replay was observed: a statement (or a REPEATABLE READ transaction) that starts
-- after that moment takes a snapshot that includes everything visible at the coordinate.
create function gnomon.wait_for(c gnomon.coord, timeout interval default null) returns void
language plpgsql volatile as $$
declare w interval := coalesce(timeout, coalesce(nullif(current_setting('gnomon.standby_wait', true), ''), '30 seconds')::interval);
        deadline timestamptz := clock_timestamp() + w;
        r pg_lsn;
begin
  if c is null or not pg_is_in_recovery() then return; end if;
  loop
    r := pg_last_wal_replay_lsn();
    exit when gnomon._lsn_reached(r, c.lsn);
    if clock_timestamp() > deadline then
      raise exception 'standby has not replayed to % within %', c.lsn, w
        using errcode = '55000', detail = format('Replayed to %s.', r), hint = '[gnomon:standby_not_replayed_within]';
    end if;
    perform pg_sleep(0.005);
  end loop;
  perform set_config('gnomon._replayed_lsn', r::text, false);
  perform set_config('gnomon._replayed_at', clock_timestamp()::text, false);
end $$;

create function gnomon.wait_for(c text, timeout interval default null) returns void
language sql volatile as $$ select gnomon.wait_for(gnomon.coord(c), timeout) $$;

-- On a standby, a read at a coordinate C taken on the primary is exact only if the reading
-- snapshot includes every commit visible at C. Two ways to know it does:
--   * gnomon.wait_for (called by gnomon.use/as_of/begin) observed replay past C.lsn before this
--     statement started (before this transaction started, under REPEATABLE READ or SERIALIZABLE);
--   * every xid below C.xmax had finished in the reading snapshot: its xmin is at least C.xmax.
--     A standby reports a snapshot's xmin and xmax correctly but not its xip, so this is the only
--     snapshot comparison available without C.
-- Otherwise the read is refused rather than answered from a standby that may be behind.
create function gnomon._standby_check(c gnomon.coord) returns void language plpgsql stable as $$
declare l text := current_setting('gnomon._replayed_lsn', true);
        a text := current_setting('gnomon._replayed_at', true);
        st timestamptz := case when current_setting('transaction_isolation') = 'read committed'
                               then statement_timestamp() else transaction_timestamp() end;
        e int2;
begin
  if c is null or not pg_is_in_recovery() then return; end if;
  e := gnomon._epoch_ro();
  -- an older epoch ended before a newer one this standby has replayed began
  if c.epoch < e then return; end if;
  if l is not null and l <> '' and gnomon._lsn_reached(l::pg_lsn, c.lsn) and a::timestamptz < st then return; end if;
  if c.epoch = e and gnomon._xid(pg_snapshot_xmin(pg_current_snapshot())) >= gnomon._xid(pg_snapshot_xmax(c.snap)) then return; end if;
  raise exception 'this standby may not have replayed coordinate % yet', gnomon.coord_text(c)
    using errcode = '55000',
          detail = format('Replayed to %s; the coordinate needs %s.', pg_last_wal_replay_lsn(), c.lsn),
          hint = 'Call gnomon.use(branch, coordinate) or gnomon.wait_for(coordinate) first (before BEGIN under REPEATABLE READ). [gnomon:standby_behind]';
end $$;

-------------------------------------------------------------------------------
-- Settings (custom placeholders; no C needed). Defaults documented here.
-------------------------------------------------------------------------------
-- Defaults ship with the extension; gnomon.setting holds what an operator (or gnomon itself)
-- changed, so pg_dump carries overrides and never collides with the defaults on restore.
create table gnomon.setting_default (
  name  text primary key,
  value text not null,
  doc   text
);
insert into gnomon.setting_default values
  ('blob_threshold', '2048', 'Text, jsonb and bytea values above this many bytes are stored once in _gnomon.blob.'),
  ('part_span', '16777216', 'Default write-time partition span for version tables, in xids. Each key''s first write in a partition carries a keyframe forward, so a small span costs writes, WAL and storage; 2^24 is about 9 minutes at 30k writes/s.'),
  ('warn_changes_since_base', '1000000', 'Warn when main has changed this many rows since a branch''s base.'),
  ('auto_rebase', 'off', 'on: gnomon.watch() rebases a branch whose base is warn_changes_since_base behind main.'),
  ('scratch_ttl', '1 hour', 'Default time-to-live for abandoned scratch branches.'),
  ('merge_batch', '10000', 'Keys per merge batch.'),
  ('event_triggers', 'on', 'Whether DDL on tracked tables is re-synced by event triggers.'),
  ('c_trigger', 'auto', 'auto: with gnomon_c installed, gnomon.track() versions known-time, row-mode tables without wide keys with the C trigger; off: always the PL/pgSQL trigger (gnomon.use_c_trigger switches one table).');
create table gnomon.setting (
  name  text primary key,
  value text not null,
  doc   text
);
comment on table gnomon.setting is 'Setting overrides; defaults are in gnomon.setting_default. Use gnomon.set(name, value).';

create function gnomon.set(name text, value text) returns void language sql volatile as $$
  insert into gnomon.setting(name, value) values ($1, $2) on conflict on constraint setting_pkey do update set value = excluded.value
$$;

create view gnomon.settings as
  select d.name, coalesce(s.value, d.value) as value, s.value is not null as overridden, d.doc
    from gnomon.setting_default d left join gnomon.setting s using (name)
  union all
  select s.name, s.value, true, s.doc from gnomon.setting s where not exists (select 1 from gnomon.setting_default d where d.name = s.name);

create function gnomon._cfg(n text) returns text language sql stable parallel safe
as $$ select coalesce((select value from gnomon.setting where name = n), (select value from gnomon.setting_default where name = n)) $$;

-- Main's change counter: the versions gnomon.watch() has seen main write. A branch's distance from
-- main is the counter now minus its value when the branch's base was set (gnomon.branches.behind).
create function _gnomon.main_changes() returns int8 language sql stable as $$
  select coalesce((select value::int8 from gnomon.setting where name = 'main_changes'), 0)
$$;

-------------------------------------------------------------------------------
-- Ticks and tags
-------------------------------------------------------------------------------
create table gnomon.tick (
  id    bigserial primary key,
  at    timestamptz not null,
  coord gnomon.coord not null,
  xid   xid8 not null,
  kx    int8            -- gnomon._kxmax(coord): the first tick that saw a version, by its xid (gnomon._tick_of)
);
create index tick_at on gnomon.tick (at);
create index tick_kx on gnomon.tick (kx, id);
comment on table gnomon.tick is 'Wall-clock time to coordinate. Written only when something changed since the previous tick.';

-- Has anything changed since the last tick? Some transaction other than the tick's own took an
-- xid since, or one running at the tick has ended (it may have committed what a tick then could
-- not see).
-- (A snapshot's xmax is one past the newest finished xid: the newest running transactions are
-- not in its in-progress list but at or above xmax. So: an xid in the tick's list, or at or above
-- its xmax, that is finished now, other than the tick's own.)
create function gnomon._tick_due(c gnomon.coord default null) returns bool
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare last gnomon.tick; lx int8; lmax int8; nmax int8; nxip int8[];
begin
  c := coalesce(c, gnomon.coordinate());
  select * into last from gnomon.tick order by id desc limit 1;
  if last.id is null or (last.coord).epoch <> c.epoch then return true; end if;
  lx := gnomon._xid(last.xid); lmax := gnomon._xid(pg_snapshot_xmax((last.coord).snap)); nmax := gnomon._xid(pg_snapshot_xmax(c.snap));
  nxip := array(select gnomon._xid(y) from pg_snapshot_xip(c.snap) y);
  if exists (select 1 from pg_snapshot_xip((last.coord).snap) x
              where gnomon._xid(x) <> lx and gnomon._xid(x) < nmax and not (gnomon._xid(x) = any(nxip))) then
    return true;
  end if;
  return nmax - lmax > (select count(*) from unnest(nxip) y where y >= lmax)
                       + case when lx >= lmax and lx < nmax and not (lx = any(nxip)) then 1 else 0 end;
end $$;

create function gnomon._do_tick(force bool default false) returns gnomon.coord
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare last gnomon.tick; c gnomon.coord := gnomon.coordinate();
begin
  if not force and not gnomon._tick_due(c) then
    return (select t.coord from gnomon.tick t order by t.id desc limit 1);
  end if;
  insert into gnomon.tick(at, coord, xid, kx) values (clock_timestamp(), c, pg_current_xact_id(), gnomon._kxmax(c));
  return c;
end $$;

-- A tick: the coordinate now, with the wall time, written only when something changed.
-- Called once a second by the C module's worker, pg_cron or `gnomon daemon` (through
-- gnomon.heartbeat, which also does the rest of the periodic work); branch, tag and merge
-- operations tick too.
create function gnomon.tick() returns gnomon.coord language sql volatile security definer
set search_path = pg_catalog, pg_temp as $$
  select gnomon._do_tick(false)
$$;

create table gnomon.tag (
  name       text primary key,
  branch     int not null default 0,
  coord      gnomon.coord not null,
  created_by name not null default session_user,
  created_at timestamptz not null default now(),
  note       text
);

-- Tags: a name for a coordinate; as_of = 'tag:<name>'; tags keep their history from retention.
create function gnomon.create_tag(name text, at text default 'now', note text default null) returns gnomon.coord
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare c gnomon.coord := gnomon.resolve_coord(coalesce(at, 'now'));
begin
  if c is null then raise exception 'cannot resolve "%" to a coordinate', at using hint = '[gnomon:cannot_resolve_coordinate]'; end if;
  insert into gnomon.tag(name, coord, note, created_by) values (name, c, note, coalesce(nullif(current_setting('role'), 'none'), session_user::text));
  perform gnomon._do_tick(false);
  return c;
end $$;

create function gnomon.drop_tag(name text) returns bool
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare g gnomon.tag;
begin
  select * into g from gnomon.tag x where x.name = drop_tag.name;
  if g.name is null then return false; end if;
  if g.created_by is distinct from coalesce(nullif(current_setting('role'), 'none'), session_user::text)::name
     and not pg_has_role(coalesce(nullif(current_setting('role'), 'none'), session_user::text), 'gnomon_admin', 'member') then
    raise exception 'tag "%" belongs to role %', g.name, g.created_by using errcode = '42501', hint = '[gnomon:tag_belongs_role]';
  end if;
  delete from gnomon.tag x where x.name = drop_tag.name;
  return true;
end $$;
comment on table gnomon.tag is 'Named coordinates. Tags pin retention.';

-------------------------------------------------------------------------------
-- Catalog
-------------------------------------------------------------------------------
create table gnomon.tracked (
  id           serial primary key,
  rel          regclass not null unique,
  nsp          name not null,
  relname      name not null,
  base         text not null unique,          -- storage name prefix in _gnomon
  mode         text not null default 'known' check (mode in ('known','bitemporal')),
  write_mode   text not null default 'row' check (write_mode in ('row','statement')),
  key_cols     name[] not null,
  wide_key     bool not null default false,    -- versions keyed by an internal bigint
  merge        jsonb not null default '{}',    -- column -> strategy
  protected    bool not null default false,
  outbox       bool not null default false,
  retention    jsonb,
  part_span    int8 not null,
  key_index    text not null default 'brin' check (key_index in ('brin','btree')),
  c_trigger    bool not null default false,    -- use the C module's versioning trigger when loaded
  user_rls     bool not null default false,    -- the table's own RLS governs it (_gnomon.refresh_user_rls)
  checkpoint_policy jsonb,                     -- {every, keep}: history checkpoints by the heartbeat
  fingerprint  text,
  colmap       jsonb not null default '{}',    -- attnum -> value slot (stable across renames and drops)
  colnames     jsonb not null default '{}',    -- attnum -> the name branch storage has the column under
  nslots       int not null default 0,
  blob_threshold int not null default 2048,
  track_coord  gnomon.coord not null,
  track_key    int8 not null,
  track_xoff   int4 not null,
  track_role   oid not null,
  created_at   timestamptz not null default now(),
  created_by   name not null default session_user
);
comment on table gnomon.tracked is 'One row per tracked table.';

create table gnomon.branch (
  id         int primary key,
  name       text not null unique check (name ~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,62}$'),
  parent     int references gnomon.branch,
  kind       text not null default 'logged' check (kind in ('main','logged','scratch')),
  status     text not null default 'open' check (status in ('open','merged','closed','lost')),
  created_by name not null default session_user,
  created_at timestamptz not null default now(),
  fork       gnomon.coord,                       -- coordinate on the parent at creation
  fork_key   int8,                               -- stamp of the creating transaction
  fork_xoff  int4,
  ttl        interval,
  last_used  timestamptz not null default now(),
  read_sample float8,                    -- read-set tracking on this branch (gnomon.track_reads), null: the setting
  note       text,
  over_quota text,                       -- why the heartbeat found it over quota; writes are refused
  expired_at timestamptz,                -- closed by expiry; dropped expire_grace later
  auto_rebase text check (auto_rebase in ('off', 'clean', 'always')),  -- null: the setting
  schema_version int                     -- the branch's shape; null: main's
);
create sequence gnomon.branch_id_seq;
insert into gnomon.branch(id, name, kind) values (0, 'main', 'main');
comment on table gnomon.branch is 'Branches. Branch 0 is main. Lineage lives in gnomon.branch_base.';

-- Cutoff history. lin_b/lin_c are the ancestor levels, parent first and main (0) last,
-- each with the cutoff the branch sees it at. Fixed at creation; rebase and merge add rows.
create table gnomon.branch_base (
  id        bigserial primary key,
  branch    int not null references gnomon.branch on delete cascade,
  since_key int8,             -- stamp of the transaction that set this base (null: creation)
  since_xoff int4,
  at        gnomon.coord,     -- coordinate when this base took effect
  lin_b     int[] not null,
  lin_c     gnomon.coord[] not null,
  reason    text not null default 'create',
  main_seq  int8 not null default 0   -- main's change counter when this base was set (_gnomon.main_changes)
);
create index branch_base_branch on gnomon.branch_base (branch, id);
create index branch_base_seq on gnomon.branch_base (main_seq);

create table gnomon.xact (
  -- a transaction by its epoch and xid: xids restart in a restored or replaced cluster
  -- (no default calling gnomon code: upgrades drop and re-create the code; _log_xact sets it)
  epoch      int2 not null,
  xid        xid8 not null,
  branch     int not null default 0,
  role       name not null default current_user,
  session_role name not null default session_user,
  actor      text,
  reason     text,
  merge_id   bigint,
  undo_of    jsonb,
  meta       jsonb,
  at         timestamptz not null default now(),
  primary key (epoch, xid)
);
comment on table gnomon.xact is 'Optional commit log. Written only when attribution is set, or by merge and undo.';

create table gnomon.merge (
  id          bigserial primary key,
  source      int not null references gnomon.branch,
  target      int not null references gnomon.branch,
  base        gnomon.coord,
  result      gnomon.coord,
  mode        text not null default 'atomic',
  status      text not null default 'planned' check (status in ('planned','conflicts','applying','applied','failed','undone')),
  filter      jsonb,
  stats       jsonb not null default '{}',
  xids        xid8[] not null default '{}',
  source_at   gnomon.coord,     -- what the merge read of the source (the base of the pair's next sibling merge)
  created_by  name not null default session_user,
  created_at  timestamptz not null default now(),
  finished_at timestamptz
);

create table gnomon.conflict (
  id          bigserial primary key,
  merge_id    bigint references gnomon.merge on delete cascade,
  branch      int,                       -- for rebase conflicts
  tbl         regclass not null,
  key         jsonb not null,
  col         text,                      -- null for row-level conflicts
  kind        text not null,             -- 'value', 'delete-update', 'update-delete', 'insert-insert', 'jsonb-path', 'text-hunk'
  path        text[],
  base        jsonb,
  ours        jsonb,
  theirs      jsonb,
  resolution  text check (resolution in ('ours','theirs','base','value')),
  value       jsonb,
  resolved_by name,
  resolved_at timestamptz
);
create index conflict_merge on gnomon.conflict (merge_id);

-- Keys an incremental merge planned a delete for: applied children first, after every insert and
-- update (gnomon.merge_incremental).
create table _gnomon.merge_pending (
  merge_id bigint not null references gnomon.merge on delete cascade,
  tid      int not null,
  k        jsonb not null,
  primary key (merge_id, tid, k)
);

create table gnomon.change_request (
  id          bigserial primary key,
  branch      int not null references gnomon.branch,
  target      int not null default 0 references gnomon.branch,
  title       text not null,
  body        text,
  status      text not null default 'open' check (status in ('open','approved','merged','closed')),
  required_approvals int not null default 1,
  merge_id    bigint references gnomon.merge,
  opened_by   name not null default session_user,
  opened_at   timestamptz not null default now()
);

create table gnomon.review (
  id          bigserial primary key,
  cr          bigint not null references gnomon.change_request on delete cascade,
  reviewer    name not null default session_user,
  verdict     text not null check (verdict in ('approve','reject','comment')),
  body        text,
  at          timestamptz not null default now(),
  coord       gnomon.coord,      -- what the reviewer saw: a later write to the branch makes an approval stale
  head        int8               -- the branch's newest version key when the review was written
);

create table gnomon."check" (
  name        text primary key,
  sql         text not null,
  expect      text not null default 'empty' check (expect in ('empty','nonempty','true')),
  target      int not null default 0,
  created_by  name not null default session_user
);

create table gnomon.check_run (
  id          bigserial primary key,
  cr          bigint references gnomon.change_request on delete cascade,
  merge_id    bigint,
  check_name  text not null,
  on_branch   int,
  phase       text not null check (phase in ('branch','merge')),
  passed      bool not null,
  detail      text,
  at          timestamptz not null default now()
);

create table gnomon.acl (
  role      name not null,
  branch    int not null references gnomon.branch on delete cascade,
  can_write bool not null default true,
  primary key (role, branch)
);
create table gnomon.confined (
  role name primary key,
  allow_create bool not null default true,
  mask_profile text
);

create table gnomon.mask_profile (
  name   text primary key,
  id     serial unique,
  note   text
);
create table gnomon.mask_rule (
  profile text not null references gnomon.mask_profile on delete cascade,
  tbl     regclass not null,
  col     name not null,
  expr    text not null,         -- SQL expression over the column; `$1` or the column name
  primary key (profile, tbl, col)
);

create table gnomon.warning (
  id        bigserial primary key,
  branch    int not null references gnomon.branch on delete cascade,
  tbl       regclass not null,
  key       jsonb not null,
  col       text,
  kind      text not null,
  main_key  int8,
  detail    jsonb,
  at        timestamptz not null default now(),
  unique (branch, tbl, key, col)
);

create table gnomon.ledger_block (
  id        bigserial primary key,
  from_coord gnomon.coord,
  to_coord  gnomon.coord not null,
  n_changes bigint not null,
  root      bytea not null,
  prev_hash bytea,
  hash      bytea not null,
  at        timestamptz not null default now(),
  leaf_format int not null default 2      -- 1: leaves by names; 2: _gnomon.leaf2 (storage slots)
);

create table gnomon.archive (
  id        bigserial primary key,
  tbl       regclass not null,
  part      int4 not null,
  uri       text not null,
  rows      bigint not null,
  checksum  text not null,
  ledger_root bytea,
  key_lo    int8,
  key_hi    int8,
  at        timestamptz not null default now(),
  restored  bool not null default false,
  thinned   bool not null default false,   -- archive --keep: the partition stays, thinned by retention
  format    int not null default 1,        -- 1: every column as text; 2: native Parquet types, sorted by row key
  foreign_rel text,                        -- the foreign partition reading the file in place, if one is attached
  engine    text,                          -- its engine (gnomon.archive_engine)
  unique (tbl, part)
);

create table gnomon.erasure (
  id        bigserial primary key,
  tbl       regclass not null,
  key       jsonb not null,
  cols      text[] not null,
  reason    text not null,
  hashes    jsonb not null,
  by_role   name not null default session_user,
  at        timestamptz not null default now()
);

create table gnomon.consumer (
  name       text primary key,
  pos        gnomon.coord not null,
  pending_to gnomon.coord,
  pending_off bigint not null default 0,   -- only for windows an older version paged by offset
  -- the position in the pending window: the feed-order tuple of the last change returned
  after_key  int8,
  after_lsn  pg_lsn,
  after_tbl  text,
  after_rk   text,
  created_by name not null default session_user,   -- the role that may poll and drop it
  updated_at timestamptz not null default now()
);

create table _gnomon.blob (
  h bytea primary key,
  v text not null
);

-- Merge tokens: a protected table accepts writes only from a transaction holding one.
create table _gnomon.merge_txn (
  xid      xid8 primary key,
  merge_id bigint,
  at       timestamptz not null default now(),
  epoch    int2 not null   -- a token copied from another cluster never matches (set by merge_token)
);

-- Branch-level TRUNCATE markers (5, TRUNCATE row).
create table _gnomon.cleared (
  tbl    int not null references gnomon.tracked on delete cascade,
  branch int not null references gnomon.branch on delete cascade,
  key    int8 not null,
  xoff   int4 not null,
  primary key (tbl, branch, key)
);

grant select on all tables in schema gnomon to public;
revoke select on gnomon.xact, gnomon.erasure from public;
grant select on gnomon.xact to gnomon_reader, gnomon_merger, gnomon_admin;
grant select on _gnomon.blob, _gnomon.cleared to gnomon_reader, gnomon_writer;
-- Whether a table has any branch TRUNCATE marker (the C module's point reads ask, as the caller).
create function _gnomon.has_cleared(tid int) returns bool language sql stable security definer
set search_path = pg_catalog, pg_temp as $$
  select exists (select 1 from _gnomon.cleared c where c.tbl = tid)
$$;
grant insert on _gnomon.blob to gnomon_writer;
grant select, insert, delete on _gnomon.cleared to gnomon_writer;
