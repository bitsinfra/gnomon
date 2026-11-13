-- Branch lifecycle (5: branches, nesting, branch per test, confinement, scratch, TRUNCATE).

create function gnomon.create_branch(
  name text, parent text default 'main', kind text default 'logged', at text default null,
  ttl interval default null, note text default null
) returns int language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare p gnomon.branch := gnomon._branch_row(parent); pb gnomon.branch_base; f gnomon.coord; id int;
        who text := coalesce(nullif(current_setting('role'), 'none'), session_user::text); conf gnomon.confined;
        st gnomon.stamp;
begin
  if kind not in ('logged', 'scratch') then raise exception 'branch kind must be logged or scratch' using hint = '[gnomon:branch_kind_must_logged]'; end if;
  -- a scratch branch can vanish in a restart; nothing that must survive one may stand on it, and
  -- logged branches are read through views that contain no unlogged table (a standby reads them)
  if kind = 'logged' and p.kind = 'scratch' then
    raise exception 'a logged branch cannot be created from scratch branch "%"', p.name
      using hint = 'Create it as a scratch branch too (kind => ''scratch''), or branch from a logged branch. [gnomon:logged_branch_cannot_created]';
  end if;
  select * into conf from gnomon.confined c where c.role = who;
  if conf.role is not null and not conf.allow_create then
    raise exception 'role % is confined and may not create branches', who using errcode = '42501', hint = '[gnomon:role_confined_may_not]';
  end if;
  if conf.role is not null and p.id <> 0 and not exists (select 1 from gnomon.acl a where a.role = who and a.branch = p.id) then
    raise exception 'role % may not branch from "%"', who, p.name using errcode = '42501', hint = '[gnomon:role_may_not_branch]';
  end if;
  perform _gnomon.check_create_quota(who, p.id);
  f := coalesce(gnomon.resolve_coord(at), gnomon.coordinate());
  id := nextval('gnomon.branch_id_seq');
  st := gnomon._stamp();
  insert into gnomon.branch(id, name, parent, kind, created_by, fork, fork_key, fork_xoff, ttl, note, schema_version)
  values (id, name, p.id, kind, who::name, f, st.key, st.xoff,
          coalesce(ttl, case when kind = 'scratch' then gnomon._cfg('scratch_ttl')::interval end), note,
          case when kind <> 'scratch' then p.schema_version end);   -- a child stands on its parent's schema version
  -- lineage: the parent at the fork, then the parent's own lineage as of the fork
  if p.id = 0 then
    insert into gnomon.branch_base(branch, lin_b, lin_c, at, main_seq) values (id, array[0], array[f], f, _gnomon.main_changes());
  else
    pb := gnomon._base_at(p.id, f);
    insert into gnomon.branch_base(branch, lin_b, lin_c, at, main_seq) values (id, array[p.id] || pb.lin_b, array[f] || pb.lin_c, f, _gnomon.main_changes());
  end if;
  if conf.role is not null then
    insert into gnomon.acl(role, branch, can_write) values (who, id, true) on conflict on constraint acl_pkey do nothing;
  end if;
  perform gnomon._bump();
  perform gnomon._do_tick(false);   -- branch operations tick
  return id;
end $$;
grant execute on function gnomon.create_branch(text, text, text, text, interval, text) to public;

-- gnomon.branch_for_test(): a scratch branch named for the caller, used by test fixtures.
create function gnomon.create_scratch(prefix text default 'test', parent text default 'main', ttl interval default null) returns text
language plpgsql volatile as $$
declare n text := prefix || '-' || to_hex(pg_backend_pid()) || '-' || to_hex((extract(epoch from clock_timestamp()) * 1000000)::int8 % 4294967296)
                  || '-' || substr(md5(random()::text), 1, 6);
begin
  perform gnomon.create_branch(n, parent, 'scratch', null, ttl);
  return n;
end $$;

create function gnomon._purge_branch_rows(b int) returns void language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; s text;
begin
  for t in select * from gnomon.tracked loop
    foreach s in array array['b','b_u','bk','bk_u','bv','bv_u'] loop
      execute format('delete from %s where gn_branch = $1', _gnomon.obj(t, s)) using b;
    end loop;
  end loop;
  delete from _gnomon.cleared where branch = b;
end $$;

create function gnomon.drop_branch(name text, cascade bool default false) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch := gnomon._branch_row(name); ch record;
        who text := coalesce(nullif(current_setting('role'), 'none'), session_user::text);
begin
  if b.id = 0 then raise exception 'main cannot be dropped' using hint = '[gnomon:main_cannot_dropped]'; end if;
  -- the creator, gnomon_admin or gnomon_merger members, or a role the acl lets write it
  if current_setting('gnomon._sweeping', true) is distinct from '1' and not gnomon._may_manage(b) then
    raise exception 'role % may not drop branch "%"', who, b.name using errcode = '42501', hint = '[gnomon:role_may_not_drop]';
  end if;
  for ch in select * from gnomon.branch where parent = b.id loop
    if not cascade then
      raise exception 'branch "%" has child branch "%"', b.name, ch.name using hint = 'Use cascade => true. [gnomon:branch_child_branch]';
    end if;
    perform gnomon.drop_branch(ch.name, true);
  end loop;
  perform gnomon._purge_branch_rows(b.id);
  perform _gnomon.drop_branch_version(b.id);   -- its schema version, if it made one
  delete from _gnomon.branch_column where branch = b.id;
  delete from gnomon.warning where branch = b.id;
  delete from gnomon.branch_base where branch = b.id;
  delete from gnomon.acl where branch = b.id;
  update gnomon.change_request set status = 'closed' where branch = b.id and status = 'open';
  update gnomon.conflict set branch = null where branch = b.id;
  begin
    delete from gnomon.branch where id = b.id;
  exception when foreign_key_violation then
    -- merge records keep their branches; mark the branch closed instead
    update gnomon.branch set status = 'closed' where id = b.id;
  end;
  perform gnomon._bump();
end $$;
grant execute on function gnomon.drop_branch(text, bool) to public;

create function gnomon.close_branch(name text) returns void language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
begin
  update gnomon.branch set status = 'closed' where branch.name = close_branch.name and id <> 0;
  perform gnomon._bump();
end $$;

create function gnomon.reopen_branch(name text) returns void language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
begin
  update gnomon.branch set status = 'open' where branch.name = reopen_branch.name and status in ('closed', 'merged') and id <> 0;
  perform gnomon._bump();
end $$;

-- Abandoned scratch branches (TTL) and scratch branches lost in a restart.
create function gnomon.sweep_scratch() returns int language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch; n int := 0;
begin
  update gnomon.branch set status = 'lost'
   where kind = 'scratch' and status = 'open' and created_at < pg_postmaster_start_time();
  -- closed branches stay only for their merge records: they neither get swept again nor keep
  -- an abandoned parent alive (the cascade marks them closed once more)
  for b in select * from gnomon.branch
            where kind = 'scratch'
              and (status = 'lost' or (status = 'open' and ttl is not null and last_used < now() - ttl))
              and not exists (select 1 from gnomon.branch c where c.parent = branch.id and c.status in ('open', 'lost')) loop
    -- a session still using it holds its lock (gnomon._hold_scratch): not abandoned
    continue when not pg_try_advisory_xact_lock(1735290222, b.id);
    perform set_config('gnomon._sweeping', '1', true);
    perform gnomon.drop_branch(b.name, true);
    perform set_config('gnomon._sweeping', '', true);
    n := n + 1;
  end loop;
  return n;
end $$;

create view gnomon.branches as
  select b.id, b.name, p.name as parent, b.kind, b.status, b.created_by, b.created_at, b.last_used,
         gnomon.coord_text(b.fork) as fork,
         (select gnomon.coord_text(bb.lin_c[1]) from gnomon.branch_base bb where bb.branch = b.id order by bb.id desc limit 1) as base,
         (select count(*) from gnomon.branch_base bb where bb.branch = b.id) - 1 as rebases,
         -- versions main has written since the branch's base was set (gnomon.watch() counts them)
         _gnomon.main_changes() - (select bb.main_seq from gnomon.branch_base bb where bb.branch = b.id order by bb.id desc limit 1) as behind,
         b.note
    from gnomon.branch b left join gnomon.branch p on p.id = b.parent
   where b.id <> 0;
grant select on gnomon.branches to public;

-------------------------------------------------------------------------------
-- Confinement (5, "Isolation, confinement")
-------------------------------------------------------------------------------
create function gnomon.confine(role name, branches text[] default '{}', allow_create bool default true, mask_profile text default null)
returns void language plpgsql volatile set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; b text; r record;
begin
  if not exists (select 1 from pg_roles where rolname = role) then raise exception 'role % does not exist', role using hint = '[gnomon:role_does_not_exist]'; end if;
  insert into gnomon.confined(role, allow_create, mask_profile) values (confine.role, confine.allow_create, confine.mask_profile)
    on conflict on constraint confined_pkey do update set allow_create = excluded.allow_create, mask_profile = excluded.mask_profile;
  -- no DML on base or internal tables
  for t in select * from gnomon.tracked loop
    execute format('revoke insert, update, delete, truncate on %s from %I', t.rel, role);
    if mask_profile is not null then
      execute format('revoke select on %s from %I', t.rel, role);
      execute format('revoke all on %s from %I', _gnomon.robj(t), role);
      execute format('revoke all on %s from %I', _gnomon.robj_s(t), role);
    end if;
  end loop;
  -- the role must not be able to merge, undo on main, or write protected tables
  if pg_has_role(role, 'gnomon_merger', 'member') then
    execute format('revoke gnomon_merger from %I', role);
  end if;
  foreach b in array branches loop
    insert into gnomon.acl(role, branch, can_write) values (confine.role, (gnomon._branch_row(b)).id, true)
      on conflict on constraint acl_pkey do update set can_write = true;
  end loop;
  for t in select * from gnomon.tracked loop
    if mask_profile is null then
      perform _gnomon.sync_grants(t.id);
    end if;
  end loop;
  if mask_profile is not null then
    perform gnomon.build_mask_profile(mask_profile);
  end if;
  for r in select nspname from pg_namespace where nspname like 'gnomon\_r\_%' loop
    execute format('grant usage on schema %I to %I', r.nspname, role);
  end loop;
end $$;

-- (a definer, so an application login that manages a branch can let another role
-- write it; before, only a superuser could)
create function gnomon.allow(role name, branch text, can_write bool default true) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch := gnomon._branch_row(allow.branch);
begin
  if b.id = 0 then raise exception 'the access list is for branches; main is governed by table grants' using hint = '[gnomon:access_list_branches_main]'; end if;
  if not gnomon._may_manage(b) then
    raise exception 'role % may not manage branch "%"', _gnomon.who(), b.name using errcode = '42501', hint = '[gnomon:branch_not_manageable]';
  end if;
  insert into gnomon.acl(role, branch, can_write) values (allow.role, b.id, allow.can_write)
    on conflict on constraint acl_pkey do update set can_write = excluded.can_write;
  perform gnomon._bump();
end $$;

create function gnomon.unconfine(role name) returns void language plpgsql volatile as $$
begin
  delete from gnomon.confined c where c.role = unconfine.role;
  delete from gnomon.acl a where a.role = unconfine.role;
end $$;

-------------------------------------------------------------------------------
-- TRUNCATE on a branch: a branch-level "cleared" marker (5, TRUNCATE row)
-------------------------------------------------------------------------------
create function gnomon.truncate(tbl regclass) returns bigint language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
declare c _gnomon.ctx := gnomon._ctx(); t gnomon.tracked; st gnomon.stamp; sfx text; n bigint;
        who text := coalesce(nullif(current_setting('role'), 'none'), session_user::text);
begin

  tbl := _gnomon.base_rel(tbl);  select * into t from gnomon.tracked where rel = tbl;
  if t.id is null then raise exception '% is not tracked', tbl using hint = '[gnomon:not_tracked]'; end if;
  if c.main_now then
    return _gnomon.truncate_main(t, who);
  end if;
  perform gnomon._write_check(c, t.id, 'DELETE', who, _gnomon.robj(t)::regclass);
  sfx := case when c.kind = 'scratch' then '_u' else '' end;
  st := gnomon._stamp();
  -- tombstones for this branch's own heads, so as-of reads before the clear still see them
  execute format($q$insert into %s (%s, gn_branch, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags)
                    select %s, b.gn_branch, %s, %s, %L::pg_lsn, %s, 4 from %s b where b.gn_branch = %s$q$,
    _gnomon.obj(t, 'bv' || sfx), _gnomon.lst(_gnomon.nongen(_gnomon.cols(t.rel))),
    _gnomon.lst(_gnomon.nongen(_gnomon.cols(t.rel)), 'b.'), st.key, st.xoff, st.lsn, st.role,
    _gnomon.obj(t, 'b' || sfx), c.branch);
  execute format('delete from %s where gn_branch = $1', _gnomon.obj(t, 'b' || sfx)) using c.branch;
  get diagnostics n = row_count;
  insert into _gnomon.cleared(tbl, branch, key, xoff) values (t.id, c.branch, st.key, st.xoff) on conflict do nothing;
  perform gnomon._bump();
  return n;
end $$;
grant execute on function gnomon.truncate(regclass) to public;

-- TRUNCATE on main: one sequential copy of the table into a history checkpoint at
-- the truncate's coordinate, a marker, then the truncate. Reads before the marker go through the
-- checkpoint; branches forked before it keep their rows; the feed reports one truncate change.
create function _gnomon.truncate_main(t gnomon.tracked, who text) returns bigint
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare st gnomon.stamp; k int; n bigint;
begin
  if not has_table_privilege(who, t.rel, 'TRUNCATE') then
    raise exception 'permission denied for table %', t.rel using errcode = '42501', hint = '[gnomon:permission_denied_table]';
  end if;
  if t.mode <> 'known' then raise exception 'TRUNCATE of a bitemporal table: delete its rows' using errcode = '0A000', hint = '[gnomon:truncate_bitemporal_table_delete]'; end if;
  if t.protected and coalesce(current_setting('gnomon._main_write', true), '') <> '1' then
    raise exception 'protected table % changes only through merges', t.rel using errcode = '42501', hint = '[gnomon:protected_table_changes_through]';
  end if;
  if exists (select 1 from pg_constraint c where c.confrelid = t.rel and c.contype = 'f' and c.conrelid <> t.rel) then
    raise exception 'other tables reference %; truncate them with it or delete', t.rel using errcode = '0A000', hint = '[gnomon:other_tables_reference_truncate]';
  end if;
  st := gnomon._stamp();
  k := _gnomon.make_checkpoint(t.id, gnomon.coordinate());
  update gnomon.history_checkpoint set cleared_key = st.key where tbl = t.id and id = k;
  insert into _gnomon.cleared(tbl, branch, key, xoff) values (t.id, 0, st.key, st.xoff);
  select rows into n from gnomon.history_checkpoint where tbl = t.id and id = k;
  perform set_config('gnomon._truncating', t.rel::oid::text, true);
  execute format('truncate %s', t.rel);
  perform set_config('gnomon._truncating', '', true);
  perform gnomon._log_xact(0, null, null, jsonb_build_object('truncate', t.rel::text, 'rows', n, 'checkpoint', k));
  perform gnomon._bump();
  return n;
end $$;
revoke all on function _gnomon.truncate_main(gnomon.tracked, text) from public;
