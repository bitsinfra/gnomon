-- Developer experience, one document per screen: gnomon.status, describe,
-- explain_error, assert_routed, primary_key, api_version and run_summary,
-- change_request_status, comments and diff paging, done and notifications.

insert into gnomon.setting_default values
  ('review_url', '', 'Base URL of the review app (gnomon serve), for links in notifications.');

-- The SQL API the SDKs are written against: raised when a function they call changes.
create function gnomon.api_version() returns int language sql immutable as $$ select 2 $$;

-------------------------------------------------------------------------------
-- Where am I
-------------------------------------------------------------------------------
-- Is the session routed to the branch its setting names? An unqualified tracked table resolves
-- to its routing view under the current search_path (with the C module, routing happens at parse
-- analysis whatever the path).
create function gnomon._routed() returns bool language plpgsql stable as $$
declare t gnomon.tracked; rv regclass;
begin
  if coalesce(current_setting('gnomon.c_module', true), '') = 'on' then return true; end if;
  for t in select * from gnomon.tracked where nsp = any(current_schemas(false)) or ('gnomon_r_' || nsp) = any(current_schemas(false))
            order by id loop
    rv := to_regclass(quote_ident(t.relname));
    if rv is null then continue; end if;
    return rv <> t.rel;
  end loop;
  return null;   -- no tracked table on the path: nothing to route
end $$;

create function gnomon.status() returns jsonb language plpgsql volatile as $$
declare bn text := gnomon.current_branch(); b gnomon.branch; asof text := nullif(current_setting('gnomon.as_of', true), '');
        routed bool := gnomon._routed(); res jsonb; ch jsonb; cr gnomon.change_request; problems jsonb := '[]';
        lt timestamptz; q record; used bigint; behind int8; cm bool := coalesce(current_setting('gnomon.c_module', true), '') = 'on';
begin
  b := gnomon._branch_row(bn);
  select max(at) into lt from gnomon.tick;
  res := jsonb_build_object('version', 1, 'branch', b.name, 'kind', b.kind, 'status', b.status, 'as_of', asof,
                            'mode', case when cm then 'c_module' else 'sql' end, 'routed', routed,
                            'role', _gnomon.who(), 'confined', exists (select 1 from gnomon.confined c where c.role = _gnomon.who()),
                            'last_tick_age_s', round(extract(epoch from now() - lt)::numeric, 1));
  if (b.id <> 0 or asof is not null) and routed is false then
    problems := problems || to_jsonb('gnomon.branch names "' || b.name || '" but search_path does not route to it: unqualified reads return main''s rows. Call gnomon.use(''' || b.name || ''') or set search_path from gnomon.connection_options(). [gnomon:not_routed]');
  end if;
  if lt is null or lt < now() - interval '1 minute' then
    problems := problems || to_jsonb('no tick in the last minute: reads by timestamp resolve to an older moment. Run gnomon.heartbeat() every second (C worker, pg_cron or gnomon daemon). [gnomon:no_heartbeat]'::text);
  end if;
  if not cm and b.id <> 0 then
    problems := problems || to_jsonb('SQL-only mode on a branch: INSERT ... ON CONFLICT and SELECT ... FOR UPDATE do not work as on main (load gnomon_c for them). [gnomon:sql_only_dml]'::text);
  end if;
  if b.id <> 0 then
    select coalesce(jsonb_agg(jsonb_build_object('table', d.tbl::text, 'inserts', d.inserts, 'updates', d.updates, 'deletes', d.deletes)), '[]')
      into ch from gnomon.diff_summary(b.name) d;
    select x.behind into behind from gnomon.branches x where x.id = b.id;
    select * into cr from gnomon.change_request x where x.branch = b.id and x.status in ('open', 'approved') order by x.id desc limit 1;
    select * into q from gnomon.effective_quota(null, b.name);
    select coalesce(sum(u.rows), 0) into used from gnomon.branch_usage(b.name) u;
    res := res || jsonb_build_object(
      'changes', ch, 'behind_main', behind,
      'base', (select gnomon.coord_text(bb.lin_c[1]) from gnomon.branch_base bb where bb.branch = b.id order by bb.id desc limit 1),
      'warnings', (select count(*) from gnomon.warning w where w.branch = b.id),
      'stale_reads', (select count(*) from gnomon.warning w where w.branch = b.id and w.kind = 'stale-read'),
      'change_request', case when cr.id is null then null else jsonb_build_object('id', cr.id, 'status', cr.status,
                          'approved', gnomon._cr_approved(cr.id),
                          'approval_stale', cr.status = 'approved' and not gnomon._cr_approved(cr.id)) end,
      'can_write', b.status = 'open' and gnomon._may_write(b) and b.over_quota is null,
      'quota', jsonb_build_object('rows_used', used, 'max_rows', q.max_rows, 'max_age', q.max_age, 'over', b.over_quota));
    if b.over_quota is not null then problems := problems || to_jsonb('over quota: ' || b.over_quota || ' [gnomon:over_quota]'); end if;
  end if;
  return res || jsonb_build_object('problems', problems);
end $$;

-- For an application's start-up and the bindings' debug mode: raise when the branch
-- setting and the search_path disagree (the silent wrong read).
create function gnomon.assert_routed() returns void language plpgsql stable as $$
begin
  if (gnomon.current_branch() <> 'main' or coalesce(current_setting('gnomon.as_of', true), '') <> '') and gnomon._routed() is false then
    raise exception 'session is on branch "%" but its search_path does not route there', gnomon.current_branch()
      using errcode = '55000',
            hint = format('Call gnomon.use(%L), or connect with options from gnomon.connection_options(%L). [gnomon:not_routed]',
                          gnomon.current_branch(), gnomon.current_branch());
  end if;
end $$;

-- The primary key of a table or of the routing view a branch session resolves it to: views
-- have none of their own, and tools that read the schema on a branch find nothing.
create function gnomon.primary_key(rel regclass) returns name[] language sql stable as $$
  select coalesce((select t.key_cols from gnomon.tracked t where t.rel = _gnomon.base_rel($1)),
                  (select array_agg(a.attname order by k.o) from pg_index i
                     cross join lateral unnest(i.indkey) with ordinality k(attnum, o)
                     join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
                    where i.indrelid = _gnomon.base_rel($1) and i.indisprimary))
$$;

-------------------------------------------------------------------------------
-- Errors that explain themselves
-------------------------------------------------------------------------------
-- What an error means for a session on a branch, and what to do instead. The CLI, the MCP
-- server and the bindings append it; any client can call it. Null when there is nothing to add.
create function gnomon.explain_error(sqlstate text, message text default null) returns text
language plpgsql stable as $$
declare m text := coalesce(message, ''); slug text := (regexp_match(m, '\[gnomon:([a-z_]+)\]'))[1]; tn text; t gnomon.tracked;
        on_branch bool := gnomon.current_branch() <> 'main';
begin
  if sqlstate = '42P10' and m ilike '%ON CONFLICT%' then
    return 'On a branch, gnomon''s SQL core routes the table through a view, and a view has no unique index for '
        || 'INSERT ... ON CONFLICT to match. Load the C module (gnomon_c), which runs upserts on branches, or write the '
        || 'upsert as UPDATE ... WHERE key = ..., then INSERT ... SELECT ... WHERE NOT EXISTS (...). [gnomon:upsert_on_branch]';
  end if;
  if sqlstate = '42501' and m ~ '^permission denied for (table|view|relation) ' then
    tn := (regexp_match(m, '^permission denied for \w+ "?([^" ]+)"?'))[1];
    if tn is not null and to_regclass(tn) is not null then
      select * into t from gnomon.tracked x where x.rel = _gnomon.base_rel(to_regclass(tn));
      if t.id is null and on_branch then
        return format('%s is not tracked, so a branch cannot write it (reads see main''s rows). Track it with gnomon.track(%L). [gnomon:not_tracked]', tn, tn);
      end if;
      if t.id is not null and exists (select 1 from gnomon.confined c where c.role = _gnomon.who()) then
        return format('This role is confined: it reads and writes %s through its branch only, never the table itself. '
                   || 'Use the unqualified name on a branch (gnomon.use). [gnomon:confined]', tn);
      end if;
    end if;
    return 'The role lacks a grant, or is confined (gnomon.confine): confined roles write only the branches in their access list, never main. [gnomon:permission]';
  end if;
  if sqlstate = '42501' and m like 'permission denied for sequence%' then
    return 'The role cannot draw from a sequence behind a column default. gnomon.confine grants confined roles the sequences of tracked tables; for others, GRANT USAGE ON SEQUENCE. [gnomon:sequence_grant]';
  end if;
  if sqlstate = '40001' then
    return 'Another transaction changed the row since this statement read it (on a branch, any concurrent write to the same row). Retry the transaction: the bindings'' retry helpers do. [gnomon:serialization]';
  end if;
  if sqlstate = '25006' then
    return 'Read-only: gnomon.as_of is set (the past is read-only), or the branch is closed or merged. gnomon.use(branch) without a time to write. [gnomon:read_only]';
  end if;
  if sqlstate = '53400' then
    return 'A quota stops this: too many open branches for the role, children for the branch, or rows touched on it. See gnomon.effective_quota and gnomon.set_quota. [gnomon:over_quota]';
  end if;
  if sqlstate = '42704' and m like 'unknown gnomon branch%' then
    return 'No branch has that name. gnomon.branches lists them. [gnomon:unknown_branch]';
  end if;
  if sqlstate = '0A000' and m ilike '%FOR UPDATE%' then
    return 'SELECT ... FOR UPDATE takes no lock on a branch in the SQL core: the row is read through a view. The C module locks branch rows. [gnomon:sql_only_dml]';
  end if;
  if slug is not null then
    return 'What [gnomon:' || slug || '] means and what to do: https://gnomon.bitsinfra.com/errors';
  end if;
  return null;
end $$;

-------------------------------------------------------------------------------
-- describe: what an agent needs to know about the database, in one document
-------------------------------------------------------------------------------
create function gnomon.describe(schema text default null) returns jsonb language plpgsql stable as $$
declare who text := _gnomon.who(); tabs jsonb := '[]'; r record; mp text; b gnomon.branch := gnomon._branch_row(gnomon.current_branch());
        cols jsonb; fks jsonb; refs jsonb; t gnomon.tracked; schemas name[];
begin
  select c.mask_profile into mp from gnomon.confined c where c.role = who;
  schemas := case when schema is not null then array[schema::name]
                  else array(select distinct n from (select x.nsp as n from gnomon.tracked x
                                                     union select s from unnest(current_schemas(false)) s) y
                              where n not like 'gnomon\_r\_%' and n not in ('gnomon', '_gnomon')) end;
  for r in select c.oid::regclass as rel, n.nspname, c.relname, c.reltuples, c.relkind
             from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = any(schemas) and c.relkind in ('r', 'p', 'v', 'm', 'f')
              and not exists (select 1 from pg_inherits i where i.inhrelid = c.oid)
            order by n.nspname, c.relname loop
    select * into t from gnomon.tracked x where x.rel = r.rel;
    continue when not (has_table_privilege(who, r.rel, 'SELECT') or (t.id is not null and _gnomon.can_read(r.rel)));
    select coalesce(jsonb_agg(jsonb_build_object('name', a.attname, 'type', format_type(a.atttypid, a.atttypmod),
                                                 'nullable', not a.attnotnull, 'default', pg_get_expr(d.adbin, d.adrelid),
                                                 'key', a.attname = any(coalesce(gnomon.primary_key(r.rel), '{}')),
                                                 'masked', exists (select 1 from gnomon.mask_rule m where m.profile = mp and m.tbl = r.rel and m.col = a.attname))
                              order by a.attnum), '[]')
      into cols from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
     where a.attrelid = r.rel and a.attnum > 0 and not a.attisdropped;
    select coalesce(jsonb_agg(jsonb_build_object('columns', (select jsonb_agg(a.attname order by k.o) from unnest(c.conkey) with ordinality k(n, o)
                                                              join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.n),
                                                 'references', c.confrelid::regclass::text,
                                                 'referenced_columns', (select jsonb_agg(a.attname order by k.o) from unnest(c.confkey) with ordinality k(n, o)
                                                              join pg_attribute a on a.attrelid = c.confrelid and a.attnum = k.n))), '[]')
      into fks from pg_constraint c where c.conrelid = r.rel and c.contype = 'f';
    select coalesce(jsonb_agg(jsonb_build_object('table', c.conrelid::regclass::text,
                                                 'columns', (select jsonb_agg(a.attname order by k.o) from unnest(c.conkey) with ordinality k(n, o)
                                                              join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.n))), '[]')
      into refs from pg_constraint c where c.confrelid = r.rel and c.contype = 'f';
    tabs := tabs || jsonb_build_object(
      'schema', r.nspname, 'name', r.relname, 'kind', case r.relkind when 'v' then 'view' when 'm' then 'materialized view' else 'table' end,
      'tracked', t.id is not null, 'protected', coalesce(t.protected, false), 'outbox', coalesce(t.outbox, false),
      'action_table', exists (select 1 from gnomon.action_table x where x.rel = r.rel),
      'writable_on_branch', t.id is not null and not coalesce(t.protected, false),
      'primary_key', to_jsonb(gnomon.primary_key(r.rel)), 'columns', cols, 'foreign_keys', fks, 'referenced_by', refs,
      'rows_estimate', greatest(r.reltuples, 0)::bigint);
  end loop;
  return jsonb_build_object('version', 1,
    'session', jsonb_build_object('branch', b.name, 'kind', b.kind, 'status', b.status, 'role', who,
                                  'base', (select gnomon.coord_text(bb.lin_c[1]) from gnomon.branch_base bb where bb.branch = b.id order by bb.id desc limit 1),
                                  'can_write', b.id <> 0 and b.status = 'open' and gnomon._may_write(b) and b.over_quota is null,
                                  'mask_profile', mp,
                                  'mode', case when coalesce(current_setting('gnomon.c_module', true), '') = 'on' then 'c_module' else 'sql' end,
                                  'limits', case when coalesce(current_setting('gnomon.c_module', true), '') = 'on' then '[]'::jsonb
                                                 else '["INSERT ... ON CONFLICT is not supported on branches", "SELECT ... FOR UPDATE takes no lock on branches"]'::jsonb end),
    'tables', tabs);
end $$;

-------------------------------------------------------------------------------
-- One document per screen
-------------------------------------------------------------------------------
-- The latest result of each check on a branch.
create function _gnomon.latest_checks(b int) returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('check', x.check_name, 'passed', x.passed, 'detail', x.detail, 'at', x.at) order by x.check_name), '[]')
    from (select distinct on (r.check_name) r.* from gnomon.check_run r where r.on_branch = b and r.phase = 'branch'
           order by r.check_name, r.id desc) x
$$;

-- What an application shows before accepting a run: its changes, its checks, the conflicts a
-- merge would hit, and its warnings, in one round trip.
create function gnomon.run_summary(branch text, run_checks bool default true) returns jsonb language plpgsql volatile as $$
declare b gnomon.branch := gnomon._branch_row(branch); ch jsonb; nconf int; total bigint; checks jsonb; npass int; nfail int;
begin
  if b.id = 0 then raise exception 'run_summary is for a branch' using hint = '[gnomon:run_summary_branch]'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('table', d.tbl::text, 'inserts', d.inserts, 'updates', d.updates, 'deletes', d.deletes)), '[]'),
         coalesce(sum(d.inserts + d.updates + d.deletes), 0)
    into ch, total from gnomon.diff_summary(b.name) d;
  if run_checks and exists (select 1 from gnomon."check" where target = coalesce(b.parent, 0)) then
    perform gnomon.run_checks(b.name);
  end if;
  checks := _gnomon.latest_checks(b.id);
  select count(*) filter (where (e ->> 'passed')::bool), count(*) filter (where not (e ->> 'passed')::bool)
    into npass, nfail from jsonb_array_elements(checks) e;
  select count(*) into nconf from gnomon.merge_preview(b.name) p where jsonb_array_length(p.conflicts) > 0;
  return jsonb_build_object('version', 1, 'branch', b.name, 'status', b.status,
    'changes', jsonb_build_object('rows', total, 'tables', ch),
    'checks', jsonb_build_object('passed', nfail = 0, 'passed_count', npass, 'failed_count', nfail, 'results', checks),
    'conflicts', nconf,
    'warnings', (select coalesce(jsonb_agg(jsonb_build_object('kind', w.kind, 'table', w.tbl::text, 'key', w.key, 'detail', w.detail)), '[]')
                   from gnomon.warning w where w.branch = b.id),
    'behind_main', (select x.behind from gnomon.branches x where x.id = b.id));
end $$;

create function gnomon.change_request_status(cr bigint) returns jsonb language plpgsql stable as $$
declare r gnomon.change_request; m gnomon.merge;
begin
  select * into r from gnomon.change_request where id = cr;
  if r.id is null then raise exception 'no change request %', cr using errcode = '42704', hint = '[gnomon:no_change_request]'; end if;
  select * into m from gnomon.merge where id = r.merge_id;
  return jsonb_build_object('version', 1, 'id', r.id, 'title', r.title, 'body', r.body, 'status', r.status,
    'branch', (select name from gnomon.branch where id = r.branch), 'target', (select name from gnomon.branch where id = r.target),
    'opened_by', r.opened_by, 'opened_at', r.opened_at, 'required_approvals', r.required_approvals,
    'approved', gnomon._cr_approved(r.id),
    'reviews', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'reviewer', v.reviewer, 'verdict', v.verdict, 'body', v.body, 'at', v.at,
                                                           'stale', v.verdict = 'approve' and gnomon.review_stale(v.id)) order by v.id), '[]')
                  from gnomon.review v where v.cr = r.id),
    'comments', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'author', c.author, 'body', c.body, 'table', c.tbl::text, 'key', c.key,
                                                            'column', c.col, 'at', c.at, 'resolved', c.resolved_at is not null) order by c.id), '[]')
                   from gnomon.review_comment c where c.cr = r.id),
    'checks', _gnomon.latest_checks(r.branch),
    'merge', case when m.id is null then null else jsonb_build_object('id', m.id, 'status', m.status, 'stats', m.stats, 'at', m.finished_at) end);
end $$;

-- Wait for a review: returns the request's status once a review newer than the call arrives,
-- or at the timeout.
create function gnomon.wait_for_review(cr bigint, timeout interval default '5 minutes') returns jsonb language plpgsql volatile as $$
declare start bigint := coalesce((select max(id) from gnomon.review where review.cr = wait_for_review.cr), 0);
        deadline timestamptz := clock_timestamp() + timeout;
begin
  loop
    exit when exists (select 1 from gnomon.review v where v.cr = wait_for_review.cr and v.id > start)
           or exists (select 1 from gnomon.change_request x where x.id = cr and x.status in ('merged', 'closed'))
           or clock_timestamp() > deadline;
    perform pg_sleep(0.2);
  end loop;
  return gnomon.change_request_status(cr);
end $$;

-- Comments anchored to a row or a field.
create function gnomon.comment(cr bigint, body text, tbl regclass default null, key jsonb default null, col text default null) returns bigint
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare id bigint; r gnomon.change_request;
begin
  select * into r from gnomon.change_request x where x.id = cr;
  if r.id is null then raise exception 'no change request %', cr using errcode = '42704', hint = '[gnomon:no_change_request]'; end if;
  if not gnomon._may_read_branch(r.branch) then raise exception 'role % may not read branch of change request %', _gnomon.who(), cr using errcode = '42501', hint = '[gnomon:role_may_not_read]'; end if;
  insert into gnomon.review_comment(cr, tbl, key, col, body, author) values (cr, _gnomon.base_rel(tbl), key, col, body, _gnomon.who())
    returning review_comment.id into id;
  return id;
end $$;

create function gnomon.resolve_comment(id bigint) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  update gnomon.review_comment c set resolved_by = _gnomon.who(), resolved_at = now() where c.id = resolve_comment.id;
  if not found then raise exception 'no comment %', id using errcode = '42704', hint = '[gnomon:no_comment]'; end if;
end $$;

-- A page of the keys that can differ between two references, in key order: the review app
-- pages a large diff with it, then reads gnomon.diff(..., keys => page).
create function gnomon.diff_keys(a text, b text default null, tbl regclass default null, after jsonb default null, lim int default 100)
returns jsonb language plpgsql volatile as $$
declare ra gnomon.ref; rb gnomon.ref; br gnomon.branch; bb gnomon.branch_base; t gnomon.tracked;
begin
  select * into t from gnomon.tracked x where x.rel = _gnomon.base_rel(tbl);
  if t.id is null then raise exception '% is not tracked', tbl using hint = '[gnomon:not_tracked]'; end if;
  if b is null then
    br := gnomon._branch_row(a);
    bb := gnomon._base_at(br.id, null);
    rb := row(a, null)::gnomon.ref;
    ra := row((select name from gnomon.branch where id = bb.lin_b[1]), gnomon.coord_text(bb.lin_c[1]))::gnomon.ref;
  else
    ra := gnomon.parse_ref(a); rb := gnomon.parse_ref(b);
  end if;
  return (select coalesce(jsonb_agg(k order by k), '[]') from (
            select e.value as k from jsonb_array_elements(_gnomon.changed_keys(t.id, ra, rb)) e
             where after is null or e.value > after order by e.value limit lim) x);
end $$;

-------------------------------------------------------------------------------
-- Review finds you
-------------------------------------------------------------------------------
-- Queue an event for every notification target that wants it (the job loop delivers webhooks;
-- channel targets are notified at once).
create function _gnomon.notify_event(event text, payload jsonb) returns int
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.notify_target; n int := 0;
begin
  for t in select * from gnomon.notify_target x where event = any(x.events) loop
    if t.kind = 'channel' then
      perform pg_notify(coalesce(t.config ->> 'channel', 'gnomon_review'), payload::text);
    else
      insert into gnomon.notification(target, event, payload) values (t.name, event, payload);
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function _gnomon.notify_event(text, jsonb) from public;

create function _gnomon.cr_event(cr bigint) returns jsonb language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
declare r gnomon.change_request; bn text; nt int; nr bigint; url text := nullif(gnomon._cfg('review_url'), '');
begin
  select * into r from gnomon.change_request where id = cr;
  select name into bn from gnomon.branch where id = r.branch;
  select count(*), coalesce(sum(d.inserts + d.updates + d.deletes), 0) into nt, nr from gnomon.diff_summary(bn) d;
  return jsonb_build_object('change_request', r.id, 'branch', bn, 'title', r.title, 'opened_by', r.opened_by,
    'tables', nt, 'rows', nr,
    'text', format('change request %s on %s: %s table(s), %s row(s)', r.id, bn, nt, nr),
    'url', case when url is null then null else rtrim(url, '/') || '/cr/' || r.id end);
end $$;
revoke all on function _gnomon.cr_event(bigint) from public;

-- An agent on a plain connection says it is finished: open a change request for its branch.
create function gnomon.done(summary text default null) returns bigint
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch := gnomon._branch_row(gnomon.current_branch()); id bigint;
begin
  if b.id = 0 then raise exception 'gnomon.done() is called on a branch' using hint = '[gnomon:not_on_branch]'; end if;
  if not gnomon._may_write(b) then raise exception 'role % may not write branch "%"', _gnomon.who(), b.name using errcode = '42501', hint = '[gnomon:role_may_not_write]'; end if;
  select x.id into id from gnomon.change_request x where x.branch = b.id and x.status in ('open', 'approved') order by x.id desc limit 1;
  if id is not null then
    if summary is not null then perform gnomon.comment(id, summary); end if;
    return id;
  end if;
  insert into gnomon.change_request(branch, target, title, body, opened_by)
  values (b.id, coalesce(b.parent, 0), coalesce(left(split_part(summary, E'\n', 1), 100), 'Changes on ' || b.name), summary, _gnomon.who())
  returning change_request.id into id;
  perform _gnomon.notify_event('change_request', _gnomon.cr_event(id));
  return id;
end $$;

-- The heartbeat's part: an assigned branch with changes, idle for idle_review_after, gets a change
-- request opened for it (agents that never say they are done).
create function gnomon._idle_reviews() returns int
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare a record; n int := 0; idle interval; id bigint;
begin
  if gnomon._cfg('idle_review_after') in ('off', '') then return 0; end if;
  idle := gnomon._cfg('idle_review_after')::interval;
  for a in select x.role, b.* from gnomon.assignment x join gnomon.branch b on b.id = x.branch
            where b.status = 'open' and b.last_used < now() - idle
              and not exists (select 1 from gnomon.change_request c where c.branch = b.id and c.status in ('open', 'approved')) loop
    continue when not exists (select 1 from gnomon.branch_usage(a.name));
    insert into gnomon.change_request(branch, target, title, body, opened_by)
    values (a.id, coalesce(a.parent, 0), 'Changes on ' || a.name, format('Opened by gnomon: idle for %s with changes.', idle), a.role)
    returning change_request.id into id;
    perform _gnomon.notify_event('change_request', _gnomon.cr_event(id));
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function gnomon._idle_reviews() from public;

create function gnomon.add_notify_target(name text, kind text, config jsonb, events text[] default '{change_request}') returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform _gnomon.require_admin('adding a notification target');
  insert into gnomon.notify_target(name, kind, config, events, created_by) values (name, kind, config, events, _gnomon.who())
    on conflict on constraint notify_target_pkey do update set kind = excluded.kind, config = excluded.config, events = excluded.events;
end $$;

-------------------------------------------------------------------------------
-- Deterministic masks: a masked key or foreign-key column must mask the same value the
-- same way everywhere, or an export's foreign keys fail to validate
-------------------------------------------------------------------------------
create function gnomon.mask_hash(value text, salt text default '') returns text language sql immutable parallel safe as $$
  select case when value is null then null else encode(sha256(convert_to(salt || chr(31) || value, 'UTF8')), 'hex') end
$$;
create function gnomon.mask_int(value bigint, salt text default '') returns bigint language sql immutable parallel safe as $$
  select case when value is null then null
              else ('x' || left(encode(sha256(convert_to(salt || chr(31) || value::text, 'UTF8')), 'hex'), 15))::bit(60)::bigint end
$$;
create function gnomon.mask_email(value text, salt text default '') returns text language sql immutable parallel safe as $$
  select case when value is null then null else left(gnomon.mask_hash(value, salt), 16) || '@example.invalid' end
$$;
