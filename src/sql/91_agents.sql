-- A role is a branch, agents, quotas, runs, the kill switch, the run record and auto-merge policies.

insert into gnomon.setting_default values
  ('runs_role', '', 'The login every agent run shares: gnomon.run_start gives it write access to each run''s branch.'),
  ('logged_ttl', 'off', 'Default time-to-live for new logged branches; off: none. A branch unused that long is closed, then dropped expire_grace later.'),
  ('expire_grace', '7 days', 'How long a branch closed by expiry is kept before it is dropped.'),
  ('merge_window', '', 'When merges into main may run, as HH:MM-HH:MM in the server''s time zone; empty: any time.'),
  ('idle_review_after', 'off', 'Open a change request for an assigned branch that has changes and has been idle this long; off: never.');

-------------------------------------------------------------------------------
-- Who is who
-------------------------------------------------------------------------------
create function _gnomon.is_super(r text) returns bool language sql stable as $$
  select coalesce((select rolsuper from pg_roles where rolname = r), false)
$$;
create function _gnomon.require_admin(what text) returns void language plpgsql stable as $$
begin
  if not (pg_has_role(_gnomon.who(), 'gnomon_admin', 'member') or _gnomon.is_super(_gnomon.who())) then
    raise exception '% requires gnomon_admin', what using errcode = '42501', hint = '[gnomon:admin_required]';
  end if;
end $$;

-------------------------------------------------------------------------------
-- A role is a branch
-------------------------------------------------------------------------------
-- Role defaults put every session of a role on a branch: the role connects with a plain
-- connection string and its writes land on its branch. A role set up as an agent holds no grant
-- on the base tables, so a session that lost its defaults (a pooler that switches roles) fails
-- loudly instead of touching main.
create function gnomon.assign(role name, branch text, base_path text default '"$user", public') returns text
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch := gnomon._branch_row(assign.branch); p text; who text := _gnomon.who(); rr pg_roles;
begin
  select * into rr from pg_roles where rolname = assign.role;
  if rr.rolname is null then raise exception 'role % does not exist', assign.role using errcode = '42704', hint = '[gnomon:role_does_not_exist]'; end if;
  perform _gnomon.require_admin('assigning a role to a branch');
  if (rr.rolsuper or rr.rolbypassrls or pg_has_role(rr.rolname, 'gnomon_admin', 'member')) and not _gnomon.is_super(who) then
    raise exception 'role % is privileged; only a superuser assigns it', assign.role using errcode = '42501', hint = '[gnomon:role_privileged_superuser_assigns]';
  end if;
  if b.id = 0 then
    perform gnomon.unassign(assign.role);
    return null;
  end if;
  if b.status <> 'open' then raise exception 'branch "%" is %', b.name, b.status using errcode = '25006', hint = '[gnomon:branch_closed]'; end if;
  p := _gnomon.routing_path_for(rr.rolname, base_path, b.kind = 'scratch');
  if b.schema_version is not null and b.kind <> 'scratch' and not exists (select 1 from gnomon.confined c where c.role = rr.rolname) then
    p := _gnomon.version_path(b.schema_version, p);
  end if;
  execute format('alter role %I in database %I set gnomon.branch = %L', rr.rolname, current_database(), b.name);
  execute format('alter role %I in database %I set search_path = %s', rr.rolname, current_database(), p);
  insert into gnomon.assignment(role, branch, db, assigned_by) values (rr.rolname, b.id, current_database(), who)
    on conflict on constraint assignment_pkey do update set branch = excluded.branch, db = excluded.db, assigned_by = excluded.assigned_by, assigned_at = now();
  return p;
end $$;

create function gnomon.unassign(role name) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform _gnomon.require_admin('unassigning a role');
  if exists (select 1 from pg_roles where rolname = unassign.role) then
    execute format('alter role %I in database %I reset gnomon.branch', unassign.role, current_database());
    execute format('alter role %I in database %I reset search_path', unassign.role, current_database());
  end if;
  delete from gnomon.assignment a where a.role = unassign.role and a.db = current_database();
end $$;

-- Re-issue the defaults of every assigned role (a newly tracked schema, a sync, a mask profile).
create function _gnomon.reassign_all() returns int
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare a record; n int := 0; p text;
begin
  for a in select x.role, b.name, b.kind, b.schema_version from gnomon.assignment x join gnomon.branch b on b.id = x.branch
            where x.db = current_database() and b.status = 'open' and exists (select 1 from pg_roles r where r.rolname = x.role) loop
    p := _gnomon.routing_path_for(a.role, '"$user", public', a.kind = 'scratch');
    if a.schema_version is not null and a.kind <> 'scratch' and not exists (select 1 from gnomon.confined c where c.role = a.role) then
      p := _gnomon.version_path(a.schema_version, p);
    end if;
    execute format('alter role %I in database %I set search_path = %s', a.role, current_database(), p);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function _gnomon.reassign_all() from public;

-------------------------------------------------------------------------------
-- Quotas: counted off the write path
-------------------------------------------------------------------------------
create function gnomon.set_quota(scope text, name text default '', max_branches int default null, max_rows bigint default null,
                                 max_age interval default null, max_children int default null) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform _gnomon.require_admin('setting quotas');
  if scope not in ('default', 'role', 'branch') then raise exception 'scope must be default, role or branch' using hint = '[gnomon:scope_must_default_role]'; end if;
  if scope = 'default' then name := ''; end if;
  if max_branches is null and max_rows is null and max_age is null and max_children is null then
    delete from gnomon.quota q where q.scope = set_quota.scope and q.name = set_quota.name;
    return;
  end if;
  insert into gnomon.quota values (scope, coalesce(name, ''), max_branches, max_rows, max_age, max_children)
    on conflict on constraint quota_pkey do update set max_branches = excluded.max_branches, max_rows = excluded.max_rows,
      max_age = excluded.max_age, max_children = excluded.max_children;
end $$;

-- The quota in force for a role (its own row, else the default), and for a branch (its own row,
-- then its creator's, then the default), field by field.
create function gnomon.effective_quota(role name default null, branch text default null,
  out max_branches int, out max_rows bigint, out max_age interval, out max_children int)
language sql stable as $$
  with b as (select x.name, x.created_by from gnomon.branch x where x.name = effective_quota.branch),
       r as (select coalesce(effective_quota.role, (select created_by from b)) as role),
       rows as (select q.*, case q.scope when 'branch' then 1 when 'role' then 2 else 3 end as o from gnomon.quota q
                 where (q.scope = 'branch' and q.name = (select name from b))
                    or (q.scope = 'role' and q.name = (select role from r))
                    or q.scope = 'default')
  select (select x.max_branches from rows x where x.max_branches is not null order by x.o limit 1),
         (select x.max_rows from rows x where x.max_rows is not null order by x.o limit 1),
         (select x.max_age from rows x where x.max_age is not null order by x.o limit 1),
         (select x.max_children from rows x where x.max_children is not null order by x.o limit 1)
$$;

-- Checked directly when a branch is created: open branches per role, children per parent.
create function _gnomon.check_create_quota(who text, parent int) returns void
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare q record; n int; pn text;
begin
  if not exists (select 1 from gnomon.quota) then return; end if;
  select * into q from gnomon.effective_quota(who::name, null);
  if q.max_branches is not null then
    select count(*) into n from gnomon.branch b where b.created_by = who and b.status = 'open' and b.id <> 0;
    if n >= q.max_branches then
      raise exception 'role % has % open branch(es), its quota', who, n using errcode = '53400',
        hint = 'Drop or merge a branch first, or raise the quota (gnomon.set_quota). [gnomon:over_quota]';
    end if;
  end if;
  if parent <> 0 then
    select x.name into pn from gnomon.branch x where x.id = check_create_quota.parent;
    select * into q from gnomon.effective_quota(null, pn);
    if q.max_children is not null then
      select count(*) into n from gnomon.branch b where b.parent = check_create_quota.parent and b.status = 'open';
      if n >= q.max_children then
        raise exception 'branch "%" has % open child branch(es), its quota', pn, n using errcode = '53400', hint = '[gnomon:over_quota]';
      end if;
    end if;
  end if;
end $$;
revoke all on function _gnomon.check_create_quota(text, int) from public;

-- Keys a branch has touched, table by table (an index-only count of its touched-key rows).
create function gnomon.branch_usage(branch text) returns table(tbl regclass, rows bigint)
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch := gnomon._branch_row(branch); t gnomon.tracked; n bigint;
begin
  for t in select * from gnomon.tracked order by id loop
    execute format('select (select count(*) from %s where gn_branch = $1) + (select count(*) from %s where gn_branch = $1)',
                   _gnomon.obj(t, 'bk'), _gnomon.obj(t, 'bk_u')) into n using b.id;
    if n > 0 then tbl := t.rel; rows := n; return next; end if;
  end loop;
end $$;

-- The heartbeat's pass: mark branches over quota (writes refused, one tick late) and clear
-- the mark of those back under it.
create function gnomon.check_quotas() returns int
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch; q record; n bigint; why text; marked int := 0;
begin
  if not exists (select 1 from gnomon.quota) then
    update gnomon.branch set over_quota = null where over_quota is not null;
    return 0;
  end if;
  for b in select * from gnomon.branch where id <> 0 and status = 'open' loop
    select * into q from gnomon.effective_quota(null, b.name);
    why := null;
    if q.max_age is not null and now() - b.created_at > q.max_age then
      why := format('older than %s', q.max_age);
    end if;
    if why is null and q.max_rows is not null then
      select coalesce(sum(u.rows), 0) into n from gnomon.branch_usage(b.name) u;
      if n > q.max_rows then why := format('%s rows touched, quota %s', n, q.max_rows); end if;
    end if;
    if why is distinct from b.over_quota then
      update gnomon.branch set over_quota = why where id = b.id;
    end if;
    if why is not null then marked := marked + 1; end if;
  end loop;
  return marked;
end $$;
revoke all on function gnomon.check_quotas() from public;
grant execute on function gnomon.check_quotas() to gnomon_admin;

-------------------------------------------------------------------------------
-- Expiry
-------------------------------------------------------------------------------
create function gnomon.set_branch_ttl(branch text, ttl interval) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch := gnomon._branch_row(branch);
begin
  if b.id = 0 then raise exception 'main does not expire' using hint = '[gnomon:main_does_not_expire]'; end if;
  if not gnomon._may_manage(b) then raise exception 'role % may not manage branch "%"', _gnomon.who(), b.name using errcode = '42501', hint = '[gnomon:role_may_not_manage]'; end if;
  update gnomon.branch set ttl = set_branch_ttl.ttl where id = b.id;
end $$;

-- Logged branches with a ttl, unused that long: closed; closed by expiry expire_grace ago: dropped.
-- Branches with an open change request or open children are left alone.
create function gnomon.expire_branches() returns jsonb
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch; closed int := 0; dropped int := 0; grace interval := gnomon._cfg('expire_grace')::interval;
begin
  for b in select * from gnomon.branch x
            where x.kind = 'logged' and x.status = 'open' and x.ttl is not null and x.last_used < now() - x.ttl
              and not exists (select 1 from gnomon.change_request cr where cr.branch = x.id and cr.status in ('open', 'approved'))
              and not exists (select 1 from gnomon.branch c where c.parent = x.id and c.status = 'open') loop
    update gnomon.branch set status = 'closed', expired_at = now() where id = b.id;
    closed := closed + 1;
  end loop;
  for b in select * from gnomon.branch x
            where x.status = 'closed' and x.expired_at is not null and x.expired_at < now() - grace
              and not exists (select 1 from gnomon.branch c where c.parent = x.id and c.status in ('open', 'lost')) loop
    perform set_config('gnomon._sweeping', '1', true);
    perform gnomon.drop_branch(b.name, true);
    perform set_config('gnomon._sweeping', '', true);
    dropped := dropped + 1;
  end loop;
  if closed + dropped > 0 then perform gnomon._bump(); end if;
  return jsonb_build_object('closed', closed, 'dropped', dropped);
end $$;
revoke all on function gnomon.expire_branches() from public;
grant execute on function gnomon.expire_branches() to gnomon_admin;

-------------------------------------------------------------------------------
-- Runs: an application login starts a branch the shared runs login may write
-------------------------------------------------------------------------------
create function gnomon.run_start(task text default null, actor text default null, kind text default 'logged',
                                 ttl interval default null, parent text default 'main') returns text
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare who text := _gnomon.who(); rr text := nullif(gnomon._cfg('runs_role'), ''); n text; id int;
begin
  if not (pg_has_role(who, 'gnomon_runner', 'member') or _gnomon.is_super(who)) then
    raise exception 'starting a run requires gnomon_runner' using errcode = '42501', hint = '[gnomon:runner_required]';
  end if;
  if rr is null or not exists (select 1 from pg_roles where rolname = rr) then
    raise exception 'no runs login: set gnomon.set(''runs_role'', <role>) first' using errcode = '55000', hint = '[gnomon:no_runs_role]';
  end if;
  if not exists (select 1 from gnomon.confined c where c.role = rr) then
    raise exception 'the runs login % must be confined (gnomon.confine)', rr using errcode = '55000', hint = '[gnomon:runs_role_unconfined]';
  end if;
  n := 'run-' || to_hex((extract(epoch from clock_timestamp()) * 1000)::int8) || '-' || substr(md5(random()::text), 1, 6);
  id := gnomon.create_branch(n, parent, kind, null, ttl, task);
  insert into gnomon.acl(role, branch, can_write) values (rr, id, true) on conflict on constraint acl_pkey do update set can_write = true;
  insert into gnomon.run(branch, task, actor, runs_role, created_by) values (id, task, actor, rr, who);
  perform gnomon._bump();
  return n;
end $$;

-- A login of the run's own (run.url, run.connection), for a tool that wants a
-- connection string: a member of the runs role (its privileges), confined to the run's branch,
-- which its sessions start on. The shared login binds each transaction to a run; a login per run
-- needs no binding, so its connection string can be handed out. run_end drops it.
create function gnomon.run_login(branch text) returns jsonb
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch := gnomon._branch_row(branch); r gnomon.run; nm text; pw text := _gnomon.new_secret(); p text;
begin
  select * into r from gnomon.run x where x.branch = b.id;
  if r.branch is null then raise exception 'branch "%" is not a run', b.name using hint = '[gnomon:branch_not_run]'; end if;
  if r.ended_at is not null then raise exception 'run "%" has ended', b.name using errcode = '55000', hint = '[gnomon:run_ended]'; end if;
  if not (r.created_by = _gnomon.who() or pg_has_role(_gnomon.who(), 'gnomon_runner', 'member') and not exists (select 1 from gnomon.confined c where c.role = _gnomon.who())) then
    raise exception 'role % may not hand out run "%"', _gnomon.who(), b.name using errcode = '42501', hint = '[gnomon:role_may_not_end]';
  end if;
  nm := coalesce(r.login, 'gnomon_run_' || substr(md5(b.name || clock_timestamp()::text), 1, 16));
  if r.login is null then
    execute format('create role %I login inherit password %L', nm, pw);
    execute format('grant %I to %I', r.runs_role, nm);
    update gnomon.run x set login = nm where x.branch = b.id;
  else
    execute format('alter role %I password %L', nm, pw);
  end if;
  perform gnomon.confine(nm::name, array[b.name], false);
  p := _gnomon.routing_path_for(nm, '"$user", public', b.kind = 'scratch');
  if b.schema_version is not null and b.kind <> 'scratch' then p := _gnomon.version_path(b.schema_version, p); end if;
  execute format('alter role %I in database %I set gnomon.branch = %L', nm, current_database(), b.name);
  execute format('alter role %I in database %I set search_path = %s', nm, current_database(), p);
  return jsonb_build_object('role', nm, 'password', pw, 'branch', b.name, 'options', gnomon.connection_options(b.name));
end $$;

create function gnomon.run_end(branch text, keep bool default false, outcome text default null) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch := gnomon._branch_row(branch); r gnomon.run;
begin
  select * into r from gnomon.run x where x.branch = b.id;
  if r.branch is null then raise exception 'branch "%" is not a run', b.name using hint = '[gnomon:branch_not_run]'; end if;
  if not (r.created_by = _gnomon.who() or gnomon._may_manage(b) and not exists (select 1 from gnomon.confined c where c.role = _gnomon.who())) then
    raise exception 'role % may not end run "%"', _gnomon.who(), b.name using errcode = '42501', hint = '[gnomon:role_may_not_end]';
  end if;
  update gnomon.run x set ended_at = now(), outcome = coalesce(run_end.outcome, case when keep then 'kept' else 'discarded' end) where x.branch = b.id;
  -- the run's own login goes with it
  if r.login is not null and exists (select 1 from pg_roles where rolname = r.login) then
    perform pg_terminate_backend(a.pid) from pg_stat_activity a where a.usename = r.login and a.pid <> pg_backend_pid();
    delete from gnomon.confined c where c.role = r.login;
    delete from gnomon.acl a where a.role = r.login;
    execute format('drop owned by %I', r.login);
    execute format('drop role %I', r.login);
  end if;
  if keep then
    if b.status = 'open' then update gnomon.branch set status = 'closed' where id = b.id; end if;
    delete from gnomon.acl a where a.branch = b.id and a.role = r.runs_role;
  else
    perform gnomon.drop_branch(b.name, true);
  end if;
  perform gnomon._bump();
end $$;

-------------------------------------------------------------------------------
-- Agents
-------------------------------------------------------------------------------
create function _gnomon.new_secret() returns text language sql volatile as $$
  select replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
$$;

-- gnomon agent create: a login role holding no grant on the base tables, confined to its own
-- branch (and the right to create children), assigned to it, with a token for HTTP. The password
-- and the token are returned once and stored nowhere but as a role password and a hash.
create function gnomon.agent_create(name text, parent text default 'main', password text default null,
                                    mask_profile text default null, allow_create bool default true, note text default null)
returns jsonb language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare r text := 'gnomon_agent_' || regexp_replace(lower(agent_create.name), '[^a-z0-9_]', '_', 'g');
        bn text := agent_create.name || '/1'; tok text := _gnomon.new_secret(); pw text := coalesce(password, _gnomon.new_secret());
        bid int; t gnomon.tracked;
begin
  perform _gnomon.require_admin('creating an agent');
  if exists (select 1 from gnomon.agent a where a.name = agent_create.name) then
    raise exception 'agent "%" exists', agent_create.name using errcode = '42710', hint = '[gnomon:agent_exists]';
  end if;
  if exists (select 1 from pg_roles where rolname = r) then
    raise exception 'role % exists already', r using errcode = '42710', hint = 'Choose another agent name. [gnomon:role_exists_already]';
  end if;
  execute format('create role %I login password %L', r, pw);
  bid := gnomon.create_branch(bn, parent, 'logged', null, null, coalesce(note, 'agent ' || agent_create.name));
  perform gnomon.confine(r::name, array[bn], allow_create, mask_profile);
  -- nothing on the base tables, even what PUBLIC was granted
  for t in select * from gnomon.tracked loop
    execute format('revoke all on %s from %I', t.rel, r);
  end loop;
  perform gnomon.assign(r::name, bn);
  insert into gnomon.agent(name, role, token_hash, branch, created_by, note)
  values (agent_create.name, r, sha256(convert_to(tok, 'UTF8')), bid, _gnomon.who(), note);
  return jsonb_build_object('agent', agent_create.name, 'role', r, 'branch', bn, 'password', pw, 'token', tok,
                            'options', format('-c gnomon.branch=%s', bn));
end $$;

-- A fresh branch for the agent's next task; its sessions pick it up when they next connect.
create function gnomon.agent_next(name text, parent text default 'main') returns text
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare a gnomon.agent; n int; bn text; bid int;
begin
  select * into a from gnomon.agent x where x.name = agent_next.name;
  if a.name is null then raise exception 'no agent "%"', agent_next.name using errcode = '42704', hint = '[gnomon:no_agent]'; end if;
  if not (pg_has_role(_gnomon.who(), 'gnomon_admin', 'member') or _gnomon.who() = a.created_by) then
    raise exception 'role % may not move agent "%"', _gnomon.who(), a.name using errcode = '42501', hint = '[gnomon:role_may_not_move]';
  end if;
  if a.status <> 'active' then raise exception 'agent "%" is stopped', a.name using errcode = '55000', hint = '[gnomon:agent_stopped]'; end if;
  select coalesce(max(substr(b.name, length(a.name) + 2)::int), 0) + 1 into n
    from gnomon.branch b where starts_with(b.name, a.name || '/') and substr(b.name, length(a.name) + 2) ~ '^[0-9]{1,9}$';
  bn := a.name || '/' || n;
  bid := gnomon.create_branch(bn, parent, 'logged', null, null, 'agent ' || a.name);
  insert into gnomon.acl(role, branch, can_write) values (a.role, bid, true) on conflict on constraint acl_pkey do update set can_write = true;
  execute format('alter role %I in database %I set gnomon.branch = %L', a.role, current_database(), bn);
  execute format('alter role %I in database %I set search_path = %s', a.role, current_database(), _gnomon.routing_path_for(a.role, '"$user", public', false));
  insert into gnomon.assignment(role, branch, db, assigned_by) values (a.role, bid, current_database(), _gnomon.who())
    on conflict on constraint assignment_pkey do update set branch = excluded.branch, assigned_by = excluded.assigned_by, assigned_at = now();
  update gnomon.agent set branch = bid where agent.name = a.name;
  return bn;
end $$;

create function gnomon.agent_rotate(name text) returns text
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare tok text := _gnomon.new_secret();
begin
  perform _gnomon.require_admin('rotating an agent token');
  update gnomon.agent set token_hash = sha256(convert_to(tok, 'UTF8')) where agent.name = agent_rotate.name;
  if not found then raise exception 'no agent "%"', name using errcode = '42704', hint = '[gnomon:no_agent]'; end if;
  return tok;
end $$;

-- The HTTP server's lookup: a bearer token to the agent's role and branch. Only the
-- server's login (a member of gnomon_runner or gnomon_admin) may ask.
create function gnomon.agent_auth(token text) returns table(name text, role name, branch text)
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
begin
  if not (pg_has_role(_gnomon.who(), 'gnomon_runner', 'member') or pg_has_role(_gnomon.who(), 'gnomon_admin', 'member')) then
    raise exception 'token lookups are for gnomon''s server' using errcode = '42501', hint = '[gnomon:token_lookups_s_server]';
  end if;
  return query select a.name, a.role, b.name from gnomon.agent a left join gnomon.branch b on b.id = a.branch
                where a.status = 'active' and a.token_hash = sha256(convert_to(token, 'UTF8'));
end $$;

-- The kill switch: the agent's login and token stop, its sessions end, its open branches
-- and change requests close, and with undo_since the merges of branches it created since then
-- are undone newest first (work merged from an agent's branch was written by the merger: undo
-- by role would find nothing).
create function gnomon.agent_stop(name text, undo_since timestamptz default null) returns jsonb
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare a gnomon.agent; nb int; ncr int; ns int := 0; m gnomon.merge; undone jsonb := '[]'; failed jsonb := '[]'; res jsonb;
begin
  perform _gnomon.require_admin('stopping an agent');
  select * into a from gnomon.agent x where x.name = agent_stop.name;
  if a.name is null then raise exception 'no agent "%"', agent_stop.name using errcode = '42704', hint = '[gnomon:no_agent]'; end if;
  update gnomon.agent set status = 'stopped', token_hash = null where agent.name = a.name;
  if exists (select 1 from pg_roles where rolname = a.role) then
    execute format('alter role %I nologin', a.role);
    select count(*) into ns from (select pg_terminate_backend(pid) from pg_stat_activity
                                    where usename = a.role and pid <> pg_backend_pid()) x;
  end if;
  update gnomon.change_request set status = 'closed'
   where status in ('open', 'approved') and (opened_by = a.role or branch in (select id from gnomon.branch where created_by = a.role));
  get diagnostics ncr = row_count;
  update gnomon.branch set status = 'closed' where status = 'open' and id <> 0
     and (created_by = a.role or id = a.branch or starts_with(branch.name, a.name || '/'));
  get diagnostics nb = row_count;
  delete from gnomon.acl where acl.role = a.role;
  update gnomon.confined set allow_create = false where confined.role = a.role;
  if undo_since is not null then
    for m in select * from gnomon.merge x
              where x.status = 'applied' and x.created_at >= undo_since
                and exists (select 1 from gnomon.branch s where s.id = x.source
                               and (s.created_by = a.role or s.id = a.branch or starts_with(s.name, a.name || '/')))
              order by x.id desc loop
      begin
        res := gnomon.undo_merge(m.id);
        undone := undone || jsonb_build_object('merge', m.id, 'result', res);
      exception when others then
        failed := failed || jsonb_build_object('merge', m.id, 'error', sqlerrm);
      end;
    end loop;
  end if;
  perform gnomon._bump();
  return jsonb_build_object('agent', a.name, 'sessions_ended', ns, 'branches_closed', nb, 'change_requests_closed', ncr,
                            'merges_undone', undone, 'undo_failed', failed);
end $$;

-- What each agent uses: open branches, rows changed per branch, calls in the last minute.
create view gnomon.agent_usage as
  select a.name as agent, a.role, a.status,
         (select count(*) from gnomon.branch b where b.created_by = a.role and b.status = 'open') as open_branches,
         (select b.name from gnomon.branch b where b.id = a.branch) as branch,
         (select count(*) from gnomon.agent_call c where c.agent = a.name and c.at > now() - interval '1 minute') as calls_last_minute,
         a.calls_per_minute, a.max_result_rows, a.max_result_bytes
    from gnomon.agent a;
revoke all on gnomon.agent_usage from public;
grant select on gnomon.agent_usage to gnomon_admin;

create function gnomon.set_agent_budget(name text, calls_per_minute int default null, max_result_rows int default null,
                                        max_result_bytes int default null) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform _gnomon.require_admin('setting an agent budget');
  update gnomon.agent a set calls_per_minute = set_agent_budget.calls_per_minute, max_result_rows = set_agent_budget.max_result_rows,
         max_result_bytes = set_agent_budget.max_result_bytes where a.name = set_agent_budget.name;
  if not found then raise exception 'no agent "%"', name using errcode = '42704', hint = '[gnomon:no_agent]'; end if;
end $$;

-------------------------------------------------------------------------------
-- The run record: insert-only, hash-chained per run
-------------------------------------------------------------------------------
-- A tool call as the server saw it. The agent's role cannot write the table; this function is
-- the only way in, and it chains each call to the previous one of its run.
create function gnomon.record_call(run text, tool text, args jsonb default null, branch text default null, coord text default null,
                                   xid xid8 default null, rows bigint default null, digest text default null, error text default null,
                                   agent text default null)
returns int language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare prev gnomon.agent_call; s int; h bytea; who text := _gnomon.who(); ag text;
begin
  -- an agent records as itself; gnomon's server (gnomon_runner, gnomon_admin) records for the agent it acts for
  select a.name into ag from gnomon.agent a where a.role = who;
  if ag is null then
    if not (pg_has_role(who, 'gnomon_runner', 'member') or pg_has_role(who, 'gnomon_admin', 'member')) then
      raise exception 'role % may not record agent calls', who using errcode = '42501', hint = '[gnomon:role_may_not_record]';
    end if;
    ag := agent;
  end if;
  perform pg_advisory_xact_lock(1735290222, hashtext('call:' || run));
  select * into prev from gnomon.agent_call c where c.run = record_call.run order by c.seq desc limit 1;
  s := coalesce(prev.seq, 0) + 1;
  h := sha256(coalesce(prev.hash, ''::bytea) || convert_to(jsonb_build_array(run, s, ag, tool, args, branch, coord, xid::text, rows, digest, error)::text, 'UTF8'));
  insert into gnomon.agent_call(run, seq, agent, tool, args, branch, coord, xid, rows, digest, error, prev_hash, hash)
  values (run, s, ag, tool, args, branch, coord, xid, rows, digest, error, prev.hash, h);
  return s;
end $$;

-- A run's record is intact when every link of its chain hashes to the next.
create function gnomon.verify_run(run text) returns table(seq int, ok bool)
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select c.seq,
         c.hash = sha256(coalesce(c.prev_hash, ''::bytea) || convert_to(jsonb_build_array(c.run, c.seq, c.agent, c.tool, c.args, c.branch,
                                                     c.coord, c.xid::text, c.rows, c.digest, c.error)::text, 'UTF8'))
         and c.prev_hash is not distinct from (select p.hash from gnomon.agent_call p where p.run = c.run and p.seq = c.seq - 1)
    from gnomon.agent_call c where c.run = verify_run.run order by c.seq
$$;
revoke all on function gnomon.verify_run(text) from public;
grant execute on function gnomon.verify_run(text) to gnomon_admin, gnomon_merger;

-------------------------------------------------------------------------------
-- Auto-rebase per branch
-------------------------------------------------------------------------------
-- off (the default), clean (only when a rebase would hit no conflict), always.
create function gnomon.set_auto_rebase(branch text, mode text) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch := gnomon._branch_row(branch);
begin
  if mode not in ('off', 'clean', 'always') then raise exception 'mode is off, clean or always' using hint = '[gnomon:mode_off_clean_always]'; end if;
  if b.id = 0 or not gnomon._may_manage(b) then raise exception 'role % may not manage branch "%"', _gnomon.who(), b.name using errcode = '42501', hint = '[gnomon:role_may_not_manage]'; end if;
  update gnomon.branch set auto_rebase = mode where id = b.id;
end $$;

-- The heartbeat's pass: an idle branch whose base main has left past the warning threshold is
-- rebased, when its option allows. Never a branch used in the last few minutes, nor one with an
-- approved change request: a rebase changes what the branch reads.
create function gnomon.auto_rebase_branches(idle interval default '5 minutes') returns int
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare r record; n int := 0; thr int8 := gnomon._cfg('warn_changes_since_base')::int8; d jsonb;
begin
  for r in select b.id, b.name, b.auto_rebase from gnomon.branches x join gnomon.branch b on b.id = x.id
            where b.status = 'open' and b.auto_rebase in ('clean', 'always') and x.behind > thr
              and b.last_used < now() - idle
              and not exists (select 1 from gnomon.change_request cr where cr.branch = b.id and cr.status = 'approved') loop
    if r.auto_rebase = 'clean' then
      d := gnomon.rebase(r.name, null, true);
      continue when (d ->> 'conflicts')::int > 0;
    end if;
    perform gnomon.rebase(r.name);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function gnomon.auto_rebase_branches(interval) from public;
grant execute on function gnomon.auto_rebase_branches(interval) to gnomon_admin;
