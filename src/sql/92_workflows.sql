-- Workflows built on the merge engine: revert, checkpoints and rewind, dry runs,
-- parallel attempts, cherry-pick, scheduled merges, scenarios, bisect, action tables and
-- auto-merge policies.

-------------------------------------------------------------------------------
-- Revert rows to a past moment
-------------------------------------------------------------------------------
-- The plan of a revert for one table: what to insert (rows that existed then and are gone),
-- delete (rows that did not exist then) and update (rows that differ; only `columns` if given).
-- Candidates are the keys that can have changed since `at`; `keys` narrows them; `filter` (SQL
-- over the table's columns) keeps the keys whose row matches it now or matched it then.
create function _gnomon.revert_plan(tid int, past gnomon.ref, nowr gnomon.ref, keys jsonb, filter text, columns text[],
                                    out ins jsonb, out upd jsonb, out del jsonb)
language plpgsql volatile as $$
declare t gnomon.tracked := _gnomon.trow(tid); cand jsonb; kk jsonb; cols text[];
begin
  cand := _gnomon.changed_keys(tid, past, nowr);
  if keys is not null then
    kk := (select coalesce(jsonb_agg(_gnomon.key_arg(t, e.value)), '[]') from jsonb_array_elements(case when jsonb_typeof(keys) = 'array' then keys else jsonb_build_array(keys) end) e);
    cand := (select coalesce(jsonb_agg(x.value), '[]') from jsonb_array_elements(cand) x where x.value in (select y.value from jsonb_array_elements(kk) y));
  end if;
  create temp table if not exists gnomon_rv (k jsonb, p jsonb, n jsonb) on commit drop;
  truncate gnomon_rv;
  insert into gnomon_rv
    select coalesce(a.k, b.k), a.r, b.r
      from (select * from _gnomon.read_rows(tid, past, cand)) a
      full join (select * from _gnomon.read_rows(tid, nowr, cand)) b on a.k = b.k;
  delete from gnomon_rv where p is not distinct from n;
  if filter is not null then
    execute format($q$delete from gnomon_rv g where not coalesce((select (%3$s) from jsonb_populate_record(null::%1$s, g.p) as %2$I), false)
                                                   and not coalesce((select (%3$s) from jsonb_populate_record(null::%1$s, g.n) as %2$I), false)$q$,
                   _gnomon.qrel(t), t.relname, filter);
  end if;
  cols := case when columns is null then null else columns || t.key_cols::text[] end;
  ins := (select coalesce(jsonb_agg(g.p order by g.k), '[]') from gnomon_rv g where g.n is null);
  del := (select coalesce(jsonb_agg(g.n order by g.k), '[]') from gnomon_rv g where g.p is null);
  -- an update sets the past values of the chosen columns over the row as it is now
  upd := (select coalesce(jsonb_agg(x.r order by x.k), '[]') from (
            select g.k, case when cols is null then g.p
                             else g.n || (select coalesce(jsonb_object_agg(e.key, e.value), '{}') from jsonb_each(g.p) e where e.key = any(cols)) end as r, g.n
              from gnomon_rv g where g.p is not null and g.n is not null) x
           where x.r is distinct from x.n);
end $$;

-- Apply one phase of a revert plan to main (the table, with the caller's rights: a write they
-- could make by hand) or to a branch (through its routing view, as any branch write).
create function _gnomon.revert_apply(tid int, b gnomon.branch, action text, rows jsonb) returns bigint
language plpgsql volatile as $$
declare t gnomon.tracked := _gnomon.trow(tid); cs _gnomon.col[] := _gnomon.cols((_gnomon.trow(tid)).rel); ng _gnomon.col[]; upd _gnomon.col[];
        tgt text; n bigint; q text := _gnomon.qrel(_gnomon.trow(tid));
begin
  if rows is null or jsonb_array_length(rows) = 0 then return 0; end if;
  if b.id = 0 then return _gnomon.apply_main(tid, action, rows); end if;
  ng := _gnomon.nongen(cs);
  upd := (select coalesce(array_agg(x order by x.num), '{}') from unnest(ng) x where x.ident is distinct from 'a' and not x.iskey);
  tgt := _gnomon.robj_for(t, b.kind);
  if action = 'insert' then
    execute format('insert into %s (%s) overriding system value select %s from jsonb_populate_recordset(null::%s, $1) r',
                   tgt, _gnomon.lst(ng), _gnomon.lst(ng, 'r.'), q) using rows;
  elsif action = 'update' then
    if cardinality(upd) = 0 then return 0; end if;
    execute format('update %s t set (%s) = row(%s) from jsonb_populate_recordset(null::%s, $1) r where %s',
                   tgt, _gnomon.lst(upd), _gnomon.lst(upd, 'r.'), q, _gnomon.eqs(_gnomon.keys(cs), 't', 'r')) using rows;
  else
    execute format('delete from %s t using jsonb_populate_recordset(null::%s, $1) r where %s',
                   tgt, q, _gnomon.eqs(_gnomon.keys(cs), 't', 'r')) using rows;
  end if;
  get diagnostics n = row_count;
  return n;
end $$;

-- Set rows of several tables to their state at a past moment, in foreign-key order: deletes
-- children first, inserts and updates parents first. Recorded as one commit-log row, so it is
-- itself undoable; dry_run returns what it would do.
create function gnomon.revert_tables(tbls regclass[], at text, branch text default 'main', keys jsonb default null,
                                     filter text default null, columns text[] default null, dry_run bool default false) returns jsonb
language plpgsql volatile as $$
declare b gnomon.branch := gnomon._branch_row(branch); past gnomon.ref; nowr gnomon.ref; tid int; p record; plans jsonb := '{}';
        ord int[]; n bigint := 0; out jsonb := '[]'; t gnomon.tracked;
        ob text := current_setting('gnomon.branch', true); oa text := current_setting('gnomon.as_of', true); sp text := current_setting('search_path');
begin
  if at is null then raise exception 'revert needs a moment to go back to' using hint = '[gnomon:revert_needs_moment_go]'; end if;
  tbls := _gnomon.base_rels(tbls);
  if exists (select 1 from gnomon.tracked x where x.rel = any(tbls) and x.mode = 'bitemporal') then
    raise exception 'revert works on known-time tables; bitemporal tables are corrected with gnomon.correct' using errcode = '0A000', hint = '[gnomon:revert_works_known_time]';
  end if;
  if exists (select 1 from unnest(tbls) r where not exists (select 1 from gnomon.tracked x where x.rel = r)) then
    raise exception 'revert works on tracked tables' using hint = '[gnomon:not_tracked]';
  end if;
  past := row(b.name, at)::gnomon.ref; nowr := row(b.name, null)::gnomon.ref;
  perform gnomon._ctx_compute(case when b.id = 0 then '' else b.name end, at, null);   -- the moment must resolve
  ord := array(select x from unnest(_gnomon.fk_order()) x where (select rel from gnomon.tracked where id = x) = any(tbls));
  foreach tid in array ord loop
    select * into p from _gnomon.revert_plan(tid, past, nowr, case when cardinality(tbls) = 1 then keys else keys -> (tbls[1])::text end, filter, columns);
    plans := plans || jsonb_build_object(tid::text, jsonb_build_object('ins', p.ins, 'upd', p.upd, 'del', p.del));
    t := _gnomon.trow(tid);
    out := out || jsonb_build_object('table', t.rel::text, 'inserts', p.ins, 'updates', p.upd, 'deletes', p.del);
  end loop;
  if dry_run then return jsonb_build_object('dry_run', true, 'at', at, 'branch', b.name, 'tables', out); end if;
  -- main: the table itself, as the caller (and not as a branch session); a branch: its views
  if b.id = 0 then
    perform set_config('gnomon.branch', '', true); perform set_config('gnomon.as_of', '', true);
  else
    perform gnomon.use(b.name, null, true);
  end if;
  foreach tid in array (select array_agg(x order by o desc) from unnest(ord) with ordinality u(x, o)) loop
    n := n + _gnomon.revert_apply(tid, b, 'delete', plans -> tid::text -> 'del');
  end loop;
  foreach tid in array ord loop
    n := n + _gnomon.revert_apply(tid, b, 'update', plans -> tid::text -> 'upd');
    n := n + _gnomon.revert_apply(tid, b, 'insert', plans -> tid::text -> 'ins');
  end loop;
  perform set_config('gnomon.branch', coalesce(ob, ''), true); perform set_config('gnomon.as_of', coalesce(oa, ''), true);
  perform set_config('search_path', sp, true);
  if n > 0 then
    perform gnomon.note(nullif(current_setting('gnomon.actor', true), ''), coalesce(nullif(current_setting('gnomon.reason', true), ''), 'revert'),
                        jsonb_build_object('revert', jsonb_build_object('at', at, 'rows', n, 'tables', to_jsonb(tbls::text[]))));
  end if;
  return jsonb_build_object('reverted', n, 'at', at, 'branch', b.name, 'tables', out);
exception when others then
  perform set_config('gnomon.branch', coalesce(ob, ''), true); perform set_config('gnomon.as_of', coalesce(oa, ''), true);
  perform set_config('search_path', sp, true);
  raise;
end $$;

create function gnomon.revert(tbl regclass, at text, keys jsonb default null, filter text default null, columns text[] default null,
                              branch text default 'main', dry_run bool default false) returns jsonb
language sql volatile as $$
  select gnomon.revert_tables(array[tbl], at, branch, keys, filter, columns, dry_run)
$$;

-------------------------------------------------------------------------------
-- Checkpoints and rewind
-------------------------------------------------------------------------------
-- A checkpoint is a tag on a branch: its coordinate now, with this transaction's writes.
create function gnomon.checkpoint(name text, branch text default null) returns text
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch := gnomon._branch_row(coalesce(branch, gnomon.current_branch()));
begin
  if b.id <> 0 and not gnomon._may_read_branch(b.id) then raise exception 'role % may not read branch "%"', _gnomon.who(), b.name using errcode = '42501', hint = '[gnomon:role_may_not_read]'; end if;
  insert into gnomon.tag(name, branch, coord, note, created_by)
  values (name, b.id, gnomon._coordinate_self(), 'checkpoint of ' || b.name, _gnomon.who());
  perform gnomon._do_tick(false);
  return 'tag:' || name;
end $$;

-- Set every row the branch changed since a checkpoint back to the branch's state at it. Branch
-- TRUNCATE markers written after it are removed first. Recorded as a change: a rewind is undoable.
create function gnomon.rewind(branch text, "to" text, dry_run bool default false) returns jsonb
language plpgsql volatile as $$
declare b gnomon.branch := gnomon._branch_row(branch); g gnomon.tag; r jsonb;
begin
  if b.id = 0 then raise exception 'rewind is for branches; main is reverted with gnomon.revert' using hint = '[gnomon:rewind_branches_main_reverted]'; end if;
  select * into g from gnomon.tag x where x.name = regexp_replace("to", '^tag:', '');
  if g.name is null then raise exception 'no checkpoint "%"', "to" using errcode = '42704', hint = '[gnomon:no_checkpoint]'; end if;
  if g.branch <> b.id then raise exception 'checkpoint "%" belongs to another branch', g.name using hint = '[gnomon:checkpoint_belongs_another_branch]'; end if;
  if not dry_run then perform _gnomon.uncleared_since(b.id, g.coord); end if;
  r := gnomon.revert_tables(array(select rel from gnomon.tracked where mode = 'known' order by id), 'tag:' || g.name, b.name, null, null, null, dry_run);
  return r || jsonb_build_object('rewound_to', g.name);
end $$;

create function _gnomon.uncleared_since(b int, c gnomon.coord) returns void language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
begin
  if not gnomon._may_write((select x from gnomon.branch x where x.id = b)) then
    raise exception 'role % may not write this branch', _gnomon.who() using errcode = '42501', hint = '[gnomon:role_may_not_write]';
  end if;
  delete from _gnomon.cleared x where x.branch = b and not gnomon._vis(x.key, x.xoff, c);
  if found then perform gnomon._bump(); end if;
end $$;
revoke all on function _gnomon.uncleared_since(int, gnomon.coord) from public;
grant execute on function _gnomon.uncleared_since(int, gnomon.coord) to public;

-------------------------------------------------------------------------------
-- Dry runs: statements on a scratch child, the result kept, everything rolled back
-------------------------------------------------------------------------------
create function gnomon.dry_run(statements text[], branch text default null, checks bool default true) returns jsonb
language plpgsql volatile as $$
declare res jsonb; sb text; sid int; parent text := coalesce(branch, gnomon.current_branch()); st text; i int := 0;
        ob text := current_setting('gnomon.branch', true); oa text := current_setting('gnomon.as_of', true); sp text := current_setting('search_path');
begin
  begin
    sb := gnomon.create_scratch('dry', parent);
    sid := (select id from gnomon.branch where name = sb);
    perform gnomon.use(sb, null, true);
    begin
      foreach st in array statements loop
        i := i + 1;
        execute st;
      end loop;
    exception when others then
      res := jsonb_build_object('ok', false, 'error', sqlerrm, 'sqlstate', sqlstate, 'statement', i,
                                'explanation', gnomon.explain_error(sqlstate, sqlerrm));
      raise sqlstate 'GNDRY';
    end;
    perform gnomon.use('main', null, true);
    res := jsonb_build_object('ok', true, 'statements', i,
      'summary', (select coalesce(jsonb_agg(jsonb_build_object('table', d.tbl::text, 'inserts', d.inserts, 'updates', d.updates, 'deletes', d.deletes)), '[]')
                    from gnomon.diff_summary(sb) d),
      'diff', (select coalesce(jsonb_agg(jsonb_build_object('table', d.tbl::text, 'key', d.key, 'kind', d.kind, 'column', d.col, 'old', d.old, 'new', d.new)), '[]')
                 from gnomon.diff(sb) d),
      'checks', case when checks then (select coalesce(jsonb_agg(jsonb_build_object('check', c.check_name, 'passed', c.passed, 'detail', c.detail)), '[]')
                                         from gnomon.run_checks(sb) c) end,
      'note', 'Nothing was kept. Sequence values drawn on the way are not returned.');
    raise sqlstate 'GNDRY';
  exception when sqlstate 'GNDRY' then
    null;   -- the scratch branch, its writes and its check runs are rolled back
  end;
  if sid is not null then perform pg_advisory_unlock_shared(1735290222, sid); end if;
  perform set_config('gnomon.branch', coalesce(ob, ''), false); perform set_config('gnomon.as_of', coalesce(oa, ''), false);
  perform set_config('search_path', sp, false);
  return res;
end $$;

-------------------------------------------------------------------------------
-- Parallel attempts
-------------------------------------------------------------------------------
create function gnomon.attempts_create(n int, prefix text, parent text default 'main') returns text[]
language plpgsql volatile as $$
declare f text := gnomon.coordinate_text(); out text[] := '{}'; i int; bn text;
begin
  if n < 1 or n > 100 then raise exception 'between 1 and 100 attempts' using hint = '[gnomon:between_attempts]'; end if;
  for i in 1..n loop
    bn := prefix || '-' || i;
    perform gnomon.create_branch(bn, parent, 'logged', case when parent = 'main' then f end, null, 'attempt ' || i || ' of ' || prefix);
    insert into gnomon.attempt(grp, branch, seq) select prefix, id, i from gnomon.branch where name = bn;
    out := out || bn;
  end loop;
  return out;
end $$;
grant insert on gnomon.attempt to public;

-- Per branch: its checks, its changes and the conflicts a merge would hit.
create function gnomon.compare(branches text[]) returns table(branch text, rows bigint, checks_passed bool, checks_failed int, conflicts int, summary jsonb)
language plpgsql volatile as $$
declare bn text; s jsonb;
begin
  foreach bn in array branches loop
    s := gnomon.run_summary(bn);
    branch := bn; rows := (s -> 'changes' ->> 'rows')::bigint; checks_passed := (s -> 'checks' ->> 'passed')::bool;
    checks_failed := (s -> 'checks' ->> 'failed_count')::int; conflicts := (s ->> 'conflicts')::int; summary := s;
    return next;
  end loop;
end $$;

-- Keep one attempt: open its change request, drop the others.
create function gnomon.attempts_pick(grp text, winner text, title text default null) returns bigint
language plpgsql volatile as $$
declare b record; cr bigint;
begin
  if not exists (select 1 from gnomon.attempt a join gnomon.branch x on x.id = a.branch where a.grp = attempts_pick.grp and x.name = winner) then
    raise exception '"%" is not an attempt of %', winner, grp using hint = '[gnomon:not_attempt]';
  end if;
  cr := gnomon.open_change_request(winner, coalesce(title, 'Attempt ' || winner || ' of ' || grp));
  for b in select x.name from gnomon.attempt a join gnomon.branch x on x.id = a.branch
            where a.grp = attempts_pick.grp and x.name <> winner and x.status = 'open' loop
    perform gnomon.drop_branch(b.name, true);
  end loop;
  return cr;
end $$;

-------------------------------------------------------------------------------
-- Cherry-pick: the rows some transactions wrote, merged three ways onto another branch
-------------------------------------------------------------------------------
create function gnomon.cherry_pick(xids xid8[], source text, target text default 'main') returns jsonb
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare s gnomon.branch := gnomon._branch_row(source); tg gnomon.branch := gnomon._branch_row(target); t gnomon.tracked; r record; m record;
        mid bigint; tctx _gnomon.ctx; ord int[] := _gnomon.fk_order(); tid int; cur jsonb; n int := 0; conf jsonb := '[]'; e jsonb; plan jsonb := '[]';
begin
  if s.id = tg.id then raise exception 'cherry-pick onto the branch it came from' using hint = '[gnomon:cherry_pick_onto_branch]'; end if;
  perform _gnomon.merge_target_check(tg);
  if not gnomon._may_read_branch(s.id) then raise exception 'role % may not read branch "%"', _gnomon.who(), s.name using errcode = '42501', hint = '[gnomon:role_may_not_read]'; end if;
  insert into gnomon.merge(source, target, base, mode, filter, created_by)
  values (s.id, tg.id, null, 'cherry-pick', jsonb_build_object('xids', to_jsonb(xids)), _gnomon.who()) returning id into mid;
  if tg.id = 0 then perform _gnomon.merge_token(mid); end if;
  tctx := gnomon._ctx_compute(case when tg.id = 0 then '' else tg.name end, null, null);
  for r in select * from _gnomon.xid_images(xids, s.name) loop
    t := _gnomon.trow(r.tid);
    cur := (select x.r from _gnomon.read_rows(t.id, row(tg.name, null)::gnomon.ref, jsonb_build_array(r.key)) x limit 1);
    select * into m from _gnomon.m3_row(r.before, cur, r.after, t.merge, t.key_cols);
    if jsonb_array_length(m.conflicts) > 0 then
      conf := conf || jsonb_build_object('tbl', t.rel::text, 'key', r.key, 'conflicts', m.conflicts);
    elsif m.action <> 'none' then
      plan := plan || jsonb_build_object('tid', t.id, 'action', m.action, 'cur', cur, 'result', m.result);
    end if;
  end loop;
  if jsonb_array_length(conf) > 0 then
    raise exception 'cherry-pick would overwrite changes to % row(s) on "%"; nothing was applied', jsonb_array_length(conf), tg.name
      using errcode = '40001', detail = conf::text, hint = '[gnomon:cherry_pick_conflict]';
  end if;
  update gnomon.merge set status = 'applying' where id = mid;
  foreach tid in array (select array_agg(x order by o desc) from unnest(ord) with ordinality u(x, o)) loop
    for e in select x from jsonb_array_elements(plan) x where (x ->> 'tid')::int = tid and x ->> 'action' = 'delete' loop
      if tg.id = 0 then perform _gnomon.apply_main(tid, 'delete', jsonb_build_array(e -> 'cur'));
      else perform _gnomon.apply_branch(tid, tctx, 'delete', e -> 'cur', null); end if;
      n := n + 1;
    end loop;
  end loop;
  foreach tid in array ord loop
    for e in select x from jsonb_array_elements(plan) x where (x ->> 'tid')::int = tid and x ->> 'action' in ('update', 'insert') loop
      if tg.id = 0 then perform _gnomon.apply_main(tid, e ->> 'action', jsonb_build_array(e -> 'result'));
      else perform _gnomon.apply_branch(tid, tctx, e ->> 'action', nullif(e -> 'cur', 'null'), nullif(e -> 'result', 'null')); end if;
      n := n + 1;
    end loop;
  end loop;
  perform gnomon._log_xact(tg.id, mid);
  perform gnomon._merge_checks(mid, s.id, tg.id);
  update gnomon.merge set status = 'applied', result = gnomon._coordinate_self(), finished_at = clock_timestamp(),
         stats = jsonb_build_object('rows', n), xids = array[pg_current_xact_id()] where id = mid;
  perform gnomon._do_tick(true);
  return jsonb_build_object('merge', mid, 'rows', n);
end $$;

-------------------------------------------------------------------------------
-- Scheduled merges
-------------------------------------------------------------------------------
create function gnomon.schedule_merge(branch text, at timestamptz, close bool default false, require_checks bool default true) returns bigint
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch := gnomon._branch_row(branch); id bigint;
begin
  if b.id = 0 then raise exception 'schedule the merge of a branch' using hint = '[gnomon:schedule_merge_branch]'; end if;
  if not pg_has_role(_gnomon.who(), 'gnomon_merger', 'member') then
    raise exception 'scheduling a merge requires gnomon_merger' using errcode = '42501', hint = '[gnomon:merger_required]';
  end if;
  insert into gnomon.scheduled_merge(branch, at, close, require_checks, created_by) values (b.id, at, close, require_checks, _gnomon.who())
    returning scheduled_merge.id into id;
  return id;
end $$;

create function gnomon.cancel_scheduled_merge(id bigint) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  update gnomon.scheduled_merge s set status = 'cancelled'
   where s.id = cancel_scheduled_merge.id and s.status = 'pending'
     and (s.created_by = _gnomon.who() or pg_has_role(_gnomon.who(), 'gnomon_admin', 'member'));
  if not found then raise exception 'no pending scheduled merge % of yours', id using hint = '[gnomon:no_pending_scheduled_merge]'; end if;
end $$;

-- The scheduled merges that are due, locked for this transaction, and what became of one: the
-- table is gnomon's own, so the job loop's merger reads and records it through these.
create function _gnomon.scheduled_due() returns setof gnomon.scheduled_merge
language sql volatile security definer set search_path = pg_catalog, pg_temp as $$
  select x.* from gnomon.scheduled_merge x
   where x.status = 'pending' and x.at <= now() order by x.at, x.id for update of x skip locked
$$;
revoke all on function _gnomon.scheduled_due() from public;
grant execute on function _gnomon.scheduled_due() to gnomon_merger;

create function _gnomon.scheduled_ran(id bigint, status text, merge_id bigint, error text) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare s gnomon.scheduled_merge;
begin
  update gnomon.scheduled_merge x set status = scheduled_ran.status, merge_id = scheduled_ran.merge_id,
                                      error = scheduled_ran.error, ran_at = now()
   where x.id = scheduled_ran.id and x.status = 'pending' returning x.* into s;
  if s.id is not null and scheduled_ran.status = 'conflicts' then
    insert into gnomon.warning(branch, tbl, key, col, kind, detail)
    values (s.branch, 'gnomon.scheduled_merge'::regclass, jsonb_build_object('id', s.id), '', 'scheduled-merge-conflicts', jsonb_build_object('merge', scheduled_ran.merge_id))
    on conflict (branch, tbl, key, col) do update set detail = excluded.detail, at = now();
  end if;
end $$;
revoke all on function _gnomon.scheduled_ran(bigint, text, bigint, text) from public;
grant execute on function _gnomon.scheduled_ran(bigint, text, bigint, text) to gnomon_merger;

-- Run by the job loop as a merger. A definer cannot SET ROLE, so the checks and the merge run as
-- the loop's role; this re-checks that whoever scheduled it is a merger still, and the merge gate
-- checks the change request (approved, not stale) as for any merge. A loop whose role is not a
-- merger has nothing to do until a merge is due, and then says so.
create function gnomon.run_scheduled_merges() returns int language plpgsql volatile as $$
declare s record; mid bigint; n int := 0; st text; bname text;
begin
  if not pg_has_role(_gnomon.who(), 'gnomon_merger', 'member') then
    if exists (select 1 from gnomon.scheduled_merge x where x.status = 'pending' and x.at <= now()) then
      raise exception 'scheduled merges are due, and running them requires gnomon_merger' using errcode = '42501', hint = '[gnomon:merger_required]';
    end if;
    return 0;
  end if;
  for s in select * from _gnomon.scheduled_due() loop
    begin
      bname := (select b.name from gnomon.branch b where b.id = s.branch);
      if not pg_has_role(s.created_by, 'gnomon_merger', 'member') then
        raise exception 'role % who scheduled it is no longer a merger', s.created_by using errcode = '42501', hint = '[gnomon:role_who_scheduled_no]';
      end if;
      if s.require_checks and exists (select 1 from gnomon.run_checks(bname) c where not c.passed) then
        raise exception 'checks fail on the branch' using errcode = '23514', hint = '[gnomon:checks_fail_branch]';
      end if;
      mid := gnomon.merge(bname, close => s.close);
      select m.status into st from gnomon.merge m where m.id = mid;
      perform _gnomon.scheduled_ran(s.id, case when st = 'conflicts' then 'conflicts' else 'merged' end, mid, null);
      n := n + 1;
    exception when others then
      perform _gnomon.scheduled_ran(s.id, 'failed', null, sqlerrm);
    end;
  end loop;
  return n;
end $$;

-------------------------------------------------------------------------------
-- Scenarios
-------------------------------------------------------------------------------
create function gnomon.scenario_create(name text, parent text default 'main', kind text default 'scratch', note text default null) returns text
language plpgsql volatile as $$
declare pb text := coalesce((select b.name from gnomon.scenario s join gnomon.branch b on b.id = s.branch where s.name = scenario_create.parent), scenario_create.parent);
        bn text := 'scenario/' || name; c text := gnomon.coordinate_text();
begin
  perform gnomon.create_branch(bn, pb, kind, null, null, coalesce(note, 'scenario ' || name));
  insert into gnomon.scenario(name, parent, branch, base, note)
  select scenario_create.name, scenario_create.parent, b.id, c, scenario_create.note from gnomon.branch b where b.name = bn;
  return bn;
end $$;
grant insert, update on gnomon.scenario, gnomon.scenario_step to public;
grant insert on gnomon.metric_run, gnomon.metric to public;
grant usage on all sequences in schema gnomon to public;

-- Run a statement on the scenario's branch and record its text.
create function gnomon.scenario_apply(name text, sql text) returns bigint language plpgsql volatile as $$
declare s gnomon.scenario; bn text; n bigint;
        ob text := current_setting('gnomon.branch', true); oa text := current_setting('gnomon.as_of', true); sp text := current_setting('search_path');
begin
  select * into s from gnomon.scenario x where x.name = scenario_apply.name;
  if s.name is null then raise exception 'no scenario "%"', name using errcode = '42704', hint = '[gnomon:no_scenario]'; end if;
  select b.name into bn from gnomon.branch b where b.id = s.branch;
  perform gnomon.use(bn, null, true);
  execute sql;
  get diagnostics n = row_count;
  perform set_config('gnomon.branch', coalesce(ob, ''), true); perform set_config('gnomon.as_of', coalesce(oa, ''), true);
  perform set_config('search_path', sp, true);
  insert into gnomon.scenario_step(scenario, seq, sql, xid)
  values (s.name, coalesce((select max(seq) from gnomon.scenario_step where scenario = s.name), 0) + 1, sql, pg_current_xact_id_if_assigned());
  return n;
end $$;

create function gnomon.add_metric(name text, sql text, unit text default null) returns void language sql volatile as $$
  insert into gnomon.metric(name, sql, unit) values (name, sql, unit)
    on conflict on constraint metric_pkey do update set sql = excluded.sql, unit = excluded.unit
$$;

-- Evaluate a metric (a query returning one number) on a branch, at a moment.
create function _gnomon.eval_metric(sql text, branch text, at text) returns numeric language plpgsql volatile as $$
declare v numeric;
        ob text := current_setting('gnomon.branch', true); oa text := current_setting('gnomon.as_of', true); sp text := current_setting('search_path');
begin
  perform set_config('search_path', _gnomon.check_path(), true);
  perform set_config('gnomon._orig_path', '', true);
  perform gnomon.use(branch, at, true);
  execute sql into v;
  perform set_config('gnomon.branch', coalesce(ob, ''), true); perform set_config('gnomon.as_of', coalesce(oa, ''), true);
  perform set_config('search_path', sp, true); perform set_config('gnomon._orig_path', '', true);
  return v;
end $$;

-- Each metric on each scenario against its baseline: the parent at the scenario's base
-- coordinate (later changes on the parent do not blur the delta), or the parent now.
create function gnomon.compare(scenarios text[], metrics text[], baseline_at text default 'base')
returns table(metric text, scenario text, value numeric, baseline numeric, delta numeric, pct numeric)
language plpgsql volatile as $$
declare s gnomon.scenario; m gnomon.metric; pb text; bn text; v numeric; bv numeric;
begin
  for m in select * from gnomon.metric x where x.name = any(metrics) order by x.name loop
    for s in select * from gnomon.scenario x where x.name = any(scenarios) order by x.name loop
      select b.name into bn from gnomon.branch b where b.id = s.branch;
      pb := coalesce((select b.name from gnomon.scenario p join gnomon.branch b on b.id = p.branch where p.name = s.parent), s.parent);
      v := _gnomon.eval_metric(m.sql, bn, null);
      bv := _gnomon.eval_metric(m.sql, pb, case when baseline_at = 'now' then null else s.base end);
      insert into gnomon.metric_run(scenario, metric, value, coord) values (s.name, m.name, v, gnomon.coordinate_text());
      metric := m.name; scenario := s.name; value := v; baseline := bv; delta := v - bv;
      pct := case when bv is null or bv = 0 then null else round(100 * (v - bv) / bv, 2) end;
      return next;
    end loop;
  end loop;
end $$;

create function gnomon.scenario_promote(name text, title text default null) returns bigint language plpgsql volatile as $$
declare bn text := (select b.name from gnomon.scenario s join gnomon.branch b on b.id = s.branch where s.name = scenario_promote.name);
begin
  if bn is null then raise exception 'no scenario "%"', name using errcode = '42704', hint = '[gnomon:no_scenario]'; end if;
  return gnomon.open_change_request(bn, coalesce(title, 'Scenario ' || name));
end $$;

-------------------------------------------------------------------------------
-- Bisect
-------------------------------------------------------------------------------
-- Run a check (a name in gnomon."check", or SQL whose result must be empty) on a branch at a
-- coordinate.
create function _gnomon.check_at(c gnomon."check", branch text, at text) returns bool language plpgsql volatile as $$
declare r record;
        ob text := current_setting('gnomon.branch', true); oa text := current_setting('gnomon.as_of', true); sp text := current_setting('search_path');
begin
  perform set_config('search_path', _gnomon.check_path(), true);
  perform set_config('gnomon._orig_path', '', true);
  perform gnomon.use(branch, at, true);
  select * into r from _gnomon.run_check(c);
  perform set_config('gnomon.branch', coalesce(ob, ''), true); perform set_config('gnomon.as_of', coalesce(oa, ''), true);
  perform set_config('search_path', sp, true); perform set_config('gnomon._orig_path', '', true);
  return r.passed;
end $$;

-- A coordinate: the snapshot of c with the given xids still in progress (a prefix state).
create function _gnomon.coord_without(c gnomon.coord, xs int8[]) returns gnomon.coord language sql immutable as $$
  with x as (select array(select distinct v from (select gnomon._xid(y) as v from pg_snapshot_xip(c.snap) y
                                                  union all select z from unnest(xs) z where z < gnomon._xid(pg_snapshot_xmax(c.snap))) q order by v) as xip)
  select row(c.epoch,
             (least(gnomon._xid(pg_snapshot_xmin(c.snap)), coalesce((select min(v) from unnest(x.xip) v), gnomon._xid(pg_snapshot_xmin(c.snap))))
              || ':' || gnomon._xid(pg_snapshot_xmax(c.snap)) || ':' || array_to_string(x.xip, ','))::pg_snapshot,
             c.lsn)::gnomon.coord
    from x
$$;

-- Where a check started failing: a binary search over the ticks between a good and a bad
-- reference, then over the transactions of the first failing tick interval, ordered by the last
-- WAL position each wrote (a linear extension of every row's write order, so each prefix state
-- is consistent row by row). The last row names the culprit transaction.
create function gnomon.bisect("check" text, good text, bad text default 'now', branch text default 'main')
returns table(step int, ref text, passed bool, detail jsonb) language plpgsql volatile as $$
declare c gnomon."check"; cg gnomon.coord := gnomon.resolve_coord(good); cb gnomon.coord := gnomon.resolve_coord(bad);
        ticks gnomon.coord[]; lo int; hi int; mid int; n int := 0; xs int8[]; xl int; xh int; xm int; ok bool;
        lo_c gnomon.coord; hi_c gnomon.coord; culprit int8; x record;
begin
  select * into c from gnomon."check" k where k.name = bisect."check";
  if c.name is null then c := row('bisect', bisect."check", 'empty', 0, session_user)::gnomon."check"; end if;
  if not _gnomon.check_at(c, branch, gnomon.coord_text(cg)) then raise exception 'the check fails at the good reference already' using hint = '[gnomon:check_fails_good_reference]'; end if;
  if _gnomon.check_at(c, branch, gnomon.coord_text(cb)) then raise exception 'the check passes at the bad reference' using hint = '[gnomon:check_passes_bad_reference]'; end if;
  -- step 1: ticks, good first and bad last
  ticks := array[cg] || array(select t.coord from gnomon.tick t where t.kx > gnomon._kxmax(cg) and t.kx < gnomon._kxmax(cb) order by t.kx, t.id) || array[cb];
  lo := 1; hi := cardinality(ticks);
  while hi - lo > 1 loop
    mid := (lo + hi) / 2; n := n + 1;
    ok := _gnomon.check_at(c, branch, gnomon.coord_text(ticks[mid]));
    step := n; ref := gnomon.coord_text(ticks[mid]); passed := ok; detail := jsonb_build_object('phase', 'ticks');
    return next;
    if ok then lo := mid; else hi := mid; end if;
  end loop;
  lo_c := ticks[lo]; hi_c := ticks[hi];
  -- step 2: the transactions committed between the two, by their last write
  if branch = 'main' then
    xs := array(select gnomon._xid(ch.xid) from gnomon.changes(gnomon.coord_text(lo_c), gnomon.coord_text(hi_c), null, false) ch
                 group by ch.xid order by max(ch.vlsn), ch.xid);
  else
    xs := array(select y.x from (select ((v.gn_key & 281474976710655) - v.gn_xoff) as x, v.gn_lsn
                                   from _gnomon.bisect_branch_versions((gnomon._branch_row(branch)).id) v
                                  where not gnomon._vis(v.gn_key, v.gn_xoff, lo_c) and gnomon._vis(v.gn_key, v.gn_xoff, hi_c)) y
                 group by y.x order by max(y.gn_lsn), y.x);
  end if;
  if cardinality(xs) = 0 then
    step := n + 1; ref := gnomon.coord_text(hi_c); passed := false;
    detail := jsonb_build_object('phase', 'result', 'note', 'no transaction of the branch between the last passing and the first failing tick');
    return next; return;
  end if;
  -- prefix k: the first k transactions applied (the rest still in progress at hi_c)
  xl := 0; xh := cardinality(xs);
  while xh - xl > 1 loop
    xm := (xl + xh) / 2; n := n + 1;
    ok := _gnomon.check_at(c, branch, gnomon.coord_text(_gnomon.coord_without(hi_c, xs[xm + 1:])));
    step := n; ref := 'prefix ' || xm || ' of ' || cardinality(xs); passed := ok; detail := jsonb_build_object('phase', 'transactions');
    return next;
    if ok then xl := xm; else xh := xm; end if;
  end loop;
  culprit := xs[xh];
  select * into x from gnomon.xact xa where xa.xid = (culprit::text)::xid8 limit 1;
  step := n + 1; ref := culprit::text; passed := false;
  detail := jsonb_build_object('phase', 'result', 'xid', culprit::text, 'role', x.role, 'actor', x.actor, 'reason', x.reason,
    'tick', (select t.at from gnomon.tick t where t.kx = gnomon._kxmax(hi_c) and gnomon.coord_text(t.coord) = gnomon.coord_text(hi_c) limit 1),
    'changes', (select coalesce(jsonb_agg(jsonb_build_object('table', (select rel::text from gnomon.tracked where id = i.tid), 'key', i.key,
                                                            'before', i.before, 'after', i.after)), '[]')
                  from _gnomon.xid_images(array[(culprit::text)::xid8], branch) i),
    'next', format('gnomon undo %s%s', culprit, case when branch = 'main' then '' else ' --on ' || branch end));
  return next;
end $$;

create function _gnomon.bisect_branch_versions(b int) returns table(gn_key int8, gn_xoff int4, gn_lsn pg_lsn)
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked;
begin
  if not gnomon._may_read_branch(b) then raise exception 'branch not readable' using errcode = '42501', hint = '[gnomon:branch_not_readable]'; end if;
  for t in select * from gnomon.tracked loop
    return query execute format('select gn_key, gn_xoff, gn_lsn from %s where gn_branch = $1 union all select gn_key, gn_xoff, gn_lsn from %s where gn_branch = $1',
                                _gnomon.obj(t, 'bv'), _gnomon.obj(t, 'bv_u')) using b;
  end loop;
end $$;

-------------------------------------------------------------------------------
-- Staged side effects: action tables
-------------------------------------------------------------------------------
-- A tracked, held-outbox table of actions (an email, a refund, a webhook): inserted on a branch it
-- sends nothing; merged, its rows are delivered (a webhook sink filtered to it, or outbox_poll).
create function gnomon.create_action_table(name text, channel text default 'gnomon_actions', schema text default 'public') returns regclass
language plpgsql volatile as $$
declare r regclass;
begin
  execute format($t$create table %I.%I (
      id              bigint generated by default as identity primary key,
      kind            text not null,
      payload         jsonb not null default '{}',
      idempotency_key text not null default gen_random_uuid()::text unique,
      created_at      timestamptz not null default now()
    )$t$, schema, name);
  r := format('%I.%I', schema, name)::regclass;
  execute format('comment on table %s is %L', r, 'gnomon action table: rows run on merge');
  perform gnomon.track(r);
  perform gnomon.outbox(r, channel);
  perform _gnomon.register_action_table(r, channel);
  return r;
end $$;

create function _gnomon.register_action_table(r regclass, channel text) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform _gnomon.require_manage(r);
  insert into gnomon.action_table(rel, channel) values (r, channel) on conflict (rel) do update set channel = excluded.channel;
end $$;

-------------------------------------------------------------------------------
-- Auto-merge policies
-------------------------------------------------------------------------------
create function gnomon.create_merge_policy(name text, agents name[], rules jsonb, target text default 'main') returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform _gnomon.require_admin('creating a merge policy');
  insert into gnomon.merge_policy(name, target, agents, rules, created_by) values (name, (gnomon._branch_row(target)).id, agents, rules, _gnomon.who())
    on conflict on constraint merge_policy_pkey do update set target = excluded.target, agents = excluded.agents, rules = excluded.rules, enabled = true;
end $$;

create function gnomon.drop_merge_policy(name text) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform _gnomon.require_admin('dropping a merge policy');
  delete from gnomon.merge_policy p where p.name = drop_merge_policy.name;
end $$;

-- The policy that covers a role merging into a target, if any.
create function _gnomon.policy_for(who text, target int) returns gnomon.merge_policy language sql stable as $$
  select p.* from gnomon.merge_policy p
   where p.enabled and p.target = policy_for.target
     and exists (select 1 from unnest(p.agents) a where a = who or pg_has_role(who, a, 'member'))
   order by p.name limit 1
$$;

-- A table named in a policy's rules, qualified or not.
create function _gnomon.rule_key(j jsonb, tbl text) returns text language sql immutable as $$
  select case when j ? tbl then tbl when position('.' in tbl) > 0 and j ? split_part(tbl, '.', 2) then split_part(tbl, '.', 2) end
$$;

-- Why a plan breaks a policy (empty: it holds). rows: [{tbl, action, o, result}] as planned.
create function _gnomon.policy_violations(p gnomon.merge_policy, source int, rows jsonb) returns text[]
language plpgsql stable as $$
declare r jsonb := p.rules; v text[] := '{}'; total int := jsonb_array_length(rows); x record; w text[]; nowt time := localtime;
        behind int8;
begin
  if r ? 'max_rows' and total > (r ->> 'max_rows')::int then v := v || format('%s rows, more than %s', total, r ->> 'max_rows'); end if;
  for x in select e ->> 'tbl' as tbl, count(*) as n from jsonb_array_elements(rows) e group by 1 loop
    if r ? 'tables' and _gnomon.rule_key(r -> 'tables', x.tbl) is null then v := v || format('table %s is not allowed', x.tbl); end if;
    if jsonb_typeof(r -> 'max_rows_per_table') = 'number' and x.n > (r ->> 'max_rows_per_table')::int then
      v := v || format('%s rows of %s, more than %s', x.n, x.tbl, r ->> 'max_rows_per_table');
    elsif jsonb_typeof(r -> 'max_rows_per_table') = 'object' and _gnomon.rule_key(r -> 'max_rows_per_table', x.tbl) is not null
          and x.n > (r -> 'max_rows_per_table' ->> _gnomon.rule_key(r -> 'max_rows_per_table', x.tbl))::int then
      v := v || format('%s rows of %s, more than %s', x.n, x.tbl, r -> 'max_rows_per_table' ->> _gnomon.rule_key(r -> 'max_rows_per_table', x.tbl));
    end if;
    if coalesce((r ->> 'allow_protected')::bool, false) is false
       and exists (select 1 from gnomon.tracked t where t.rel::text = x.tbl and t.protected) then
      v := v || format('%s is protected', x.tbl);
    end if;
    if coalesce((r ->> 'allow_outbox')::bool, false) is false
       and exists (select 1 from gnomon.tracked t where t.rel::text = x.tbl and t.outbox) then
      v := v || format('%s is an outbox (its rows run on merge)', x.tbl);
    end if;
  end loop;
  if r ? 'ops' then
    for x in select distinct e ->> 'action' as a from jsonb_array_elements(rows) e loop
      if not (r -> 'ops') ? x.a then v := v || format('%s is not an allowed operation', x.a); end if;
    end loop;
  end if;
  if r ? 'columns' then
    for x in select e ->> 'tbl' as tbl, k.key as col from jsonb_array_elements(rows) e
              cross join lateral jsonb_each(coalesce(e -> 'result', '{}')) k
             where e ->> 'action' = 'update' and (e -> 'o' -> k.key) is distinct from k.value
               and _gnomon.rule_key(r -> 'columns', e ->> 'tbl') is not null
               and not (r -> 'columns' -> _gnomon.rule_key(r -> 'columns', e ->> 'tbl')) ? k.key loop
      v := v || format('column %s.%s is not allowed', x.tbl, x.col);
    end loop;
  end if;
  if coalesce((r ->> 'no_stale_reads')::bool, true) and exists (select 1 from gnomon.warning w where w.branch = source and w.kind = 'stale-read') then
    v := v || 'the branch has stale reads'::text;
  end if;
  if r ? 'window' then
    w := regexp_match(r ->> 'window', '^\s*(\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})\s*$');
    if w is null or not (case when w[1]::time <= w[2]::time then nowt >= w[1]::time and nowt < w[2]::time
                              else nowt >= w[1]::time or nowt < w[2]::time end) then
      v := v || format('outside the window %s', r ->> 'window');
    end if;
  end if;
  if r ? 'max_base_lag' then
    select b.behind into behind from gnomon.branches b where b.id = source;
    if behind > (r ->> 'max_base_lag')::int8 then v := v || format('the branch is %s changes behind main, more than %s', behind, r ->> 'max_base_lag'); end if;
  end if;
  return v;
end $$;

-- What a policy would say about merging a branch now, without merging.
create function gnomon.policy_eval(branch text, policy text default null) returns jsonb language plpgsql volatile as $$
declare b gnomon.branch := gnomon._branch_row(branch); p gnomon.merge_policy; rows jsonb; v text[]; nconf int;
begin
  if policy is null then p := _gnomon.policy_for(b.created_by, coalesce(b.parent, 0));
  else select * into p from gnomon.merge_policy x where x.name = policy; end if;
  if p.name is null then return jsonb_build_object('policy', null, 'allowed', false, 'reasons', jsonb_build_array('no policy covers this branch')); end if;
  select coalesce(jsonb_agg(jsonb_build_object('tbl', m.tbl::text, 'action', m.action, 'o', m.ours, 'result', m.result))
                    filter (where m.action <> 'none'), '[]'),
         count(*) filter (where jsonb_array_length(m.conflicts) > 0)
    into rows, nconf from gnomon.merge_preview(b.name) m;
  v := _gnomon.policy_violations(p, b.id, rows);
  if nconf > 0 then v := v || format('%s conflict(s)', nconf); end if;
  return jsonb_build_object('policy', p.name, 'allowed', cardinality(v) = 0, 'reasons', to_jsonb(v), 'rows', jsonb_array_length(rows));
end $$;
