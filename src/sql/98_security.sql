-- Privileges (docs/security.md). Functions default to EXECUTE for
-- PUBLIC; the definer functions below either check the caller inside or are internal.

-- Internal: only gnomon's own definer code (or its roles) may call these.
revoke all on function gnomon._purge_branch_rows(int) from public;
revoke all on function gnomon._do_tick(bool) from public;
revoke all on function gnomon._log_xact(int, bigint, jsonb, jsonb) from public;
grant execute on function gnomon._log_xact(int, bigint, jsonb, jsonb) to gnomon_writer, gnomon_merger, gnomon_admin;
grant execute on function gnomon._do_tick(bool) to gnomon_admin;
revoke all on function gnomon.tick() from public;
grant execute on function gnomon.tick() to gnomon_admin;

-- Operations: gnomon_admin (the C worker and `gnomon daemon` run with such a role).
revoke all on function gnomon.heartbeat(bool, bool) from public;
revoke all on function gnomon.apply_retention(regclass) from public;
revoke all on function gnomon.drop_history_before(regclass, timestamptz, bool) from public;
revoke all on function gnomon.seal_ledger() from public;
revoke all on function gnomon.restore_done(regclass, int4) from public;
revoke all on function gnomon.thaw_take() from public;
revoke all on function gnomon.thaw_finish(bigint, text) from public;
grant execute on function gnomon.thaw_take(), gnomon.thaw_finish(bigint, text) to gnomon_admin;
revoke all on function gnomon.apply_scheduled() from public;
grant execute on function gnomon.heartbeat(bool, bool), gnomon.apply_retention(regclass),
  gnomon.drop_history_before(regclass, timestamptz, bool), gnomon.seal_ledger(), gnomon.restore_done(regclass, int4),
  gnomon.apply_scheduled() to gnomon_admin;

-- Who may manage a branch: its creator, gnomon_admin or gnomon_merger members, or a role whose
-- acl lets it write the branch.
create function gnomon._may_manage(b gnomon.branch) returns bool language sql stable as $$
  select b.created_by = _gnomon.who()
      or pg_has_role(_gnomon.who(), 'gnomon_admin', 'member')
      or pg_has_role(_gnomon.who(), 'gnomon_merger', 'member')
      or exists (select 1 from gnomon.acl a where a.role = _gnomon.who() and a.branch = b.id and a.can_write)
$$;

-- Who may read a branch (read isolation): anyone unconfined; a confined role only
-- the branches in its access list and their ancestors. Runs that share a login cannot read each
-- other's branches.
-- The shared runs login (runs_role) holds every run in its access list, so for it the list is
-- not enough: each transaction is bound to one run by gnomon.begin (gnomon._run_bind), and only
-- that run (its ancestors, its children) is readable in it.
create function gnomon._may_read_branch(b int) returns bool language plpgsql stable
security definer set search_path = pg_catalog, pg_temp as $$
declare who text := _gnomon.who(); rr text; bound int;
begin
  if b = 0 then return true; end if;
  if not exists (select 1 from gnomon.confined c where c.role = who) then return true; end if;
  if not exists (select 1 from gnomon.acl a where a.role = who
                    and (a.branch = b or exists (select 1 from gnomon.branch_base bb where bb.branch = a.branch and b = any(bb.lin_b)))) then
    return false;
  end if;
  rr := nullif(gnomon._cfg('runs_role'), '');
  if rr is null or who <> rr then return true; end if;
  bound := gnomon._run_bound();
  return bound is not null
     and (bound = b
          or exists (select 1 from gnomon.branch_base bb where bb.branch = bound and b = any(bb.lin_b))
          or exists (select 1 from gnomon.branch_base bb where bb.branch = b and bound = any(bb.lin_b)));
end $$;

-- The run this transaction is bound to: a row in a temporary table that gnomon's definer code
-- creates and owns, so the session's own role cannot write it (nor plant a table of its own in
-- its place: the owner is checked).
create function gnomon._run_bound() returns int language plpgsql stable
security definer set search_path = pg_catalog, pg_temp as $$
declare r regclass := to_regclass('pg_temp.gnomon_run_bind'); v int;
begin
  if r is null or (select c.relowner from pg_class c where c.oid = r) <> (select oid from pg_roles where rolname = current_user) then
    return null;
  end if;
  execute 'select branch from pg_temp.gnomon_run_bind where ts = transaction_timestamp()' into v;
  return v;
end $$;

create function gnomon._run_bind(b int) returns void language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
declare r regclass; cur int;
begin
  if pg_is_in_recovery() then return; end if;
  r := to_regclass('pg_temp.gnomon_run_bind');
  if r is not null and (select c.relowner from pg_class c where c.oid = r) <> (select oid from pg_roles where rolname = current_user) then
    raise exception 'a table named gnomon_run_bind that gnomon does not own is in the way' using errcode = '42501', hint = '[gnomon:table_named_gnomon_run_bind_does]';
  end if;
  if r is null then
    create temp table gnomon_run_bind (ts timestamptz primary key, branch int not null);
  end if;
  execute 'select branch from pg_temp.gnomon_run_bind where ts = transaction_timestamp()' into cur;
  if cur is not null and cur <> b then
    raise exception 'this transaction is bound to another run' using errcode = '42501',
      hint = 'Runs that share a login get one run per transaction: BEGIN; SELECT gnomon.begin(run); ...; COMMIT. [gnomon:run_bound]';
  end if;
  if cur is null then
    execute 'delete from pg_temp.gnomon_run_bind';
    execute 'insert into pg_temp.gnomon_run_bind values (transaction_timestamp(), $1)' using b;
  end if;
end $$;
revoke all on function gnomon._run_bind(int) from public;
-- (the entry gnomon.use calls: only for a branch in the runs login's access list)
create function gnomon._run_bind_as_runner(b int) returns void language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
begin
  if _gnomon.who() is distinct from nullif(gnomon._cfg('runs_role'), '')
     or not exists (select 1 from gnomon.acl a where a.role = _gnomon.who() and a.branch = b) then
    raise exception 'not a run of this login' using errcode = '42501', hint = '[gnomon:not_run_login]';
  end if;
  perform gnomon._run_bind(b);
end $$;

-- Who may write a branch: anyone unconfined, or a confined role its acl allows.
create function gnomon._may_write(b gnomon.branch) returns bool language sql stable as $$
  select not exists (select 1 from gnomon.confined c where c.role = _gnomon.who())
      or exists (select 1 from gnomon.acl a where a.role = _gnomon.who() and a.branch = b.id and a.can_write)
$$;

create or replace function gnomon.close_branch(name text) returns void language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch := gnomon._branch_row(name);
begin
  if b.id = 0 then raise exception 'main cannot be closed' using hint = '[gnomon:main_cannot_closed]'; end if;
  if not gnomon._may_manage(b) then raise exception 'role % may not close branch "%"', _gnomon.who(), b.name using errcode = '42501', hint = '[gnomon:role_may_not_close]'; end if;
  update gnomon.branch set status = 'closed' where id = b.id;
  perform gnomon._bump();
end $$;

create or replace function gnomon.reopen_branch(name text) returns void language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch := gnomon._branch_row(name);
begin
  if not gnomon._may_manage(b) then raise exception 'role % may not reopen branch "%"', _gnomon.who(), b.name using errcode = '42501', hint = '[gnomon:role_may_not_reopen]'; end if;
  update gnomon.branch set status = 'open' where id = b.id and status in ('closed', 'merged') and id <> 0;
  perform gnomon._bump();
end $$;

-- note(): attribution for the caller's own transaction; merge and undo links stay internal.
create or replace function gnomon.note(actor text, reason text default null, meta jsonb default null) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform set_config('gnomon.actor', coalesce(actor, ''), true);
  perform set_config('gnomon.reason', coalesce(reason, ''), true);
  perform gnomon._log_xact((gnomon._ctx()).branch, null, null, meta);
end $$;
