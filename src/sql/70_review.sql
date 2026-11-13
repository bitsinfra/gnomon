-- Review and control: change requests, checks, masked branches, held outbox.
-- Protected tables live in 30_storage.sql (gnomon.protect, _gnomon.protect_check).

insert into gnomon.setting_default values
  ('require_change_request', 'off', 'When on, merges into main need an approved change request.'),
  ('stale_reads', 'warn', 'What a merge does about stale reads (C module read-set tracking): warn or refuse.'),
  ('stale_approvals', 'dismiss', 'dismiss: an approval stops counting once its branch is written or rebased after it; keep: approvals count whatever the branch did afterwards.');

create function gnomon.open_change_request(branch text, title text, body text default null, target text default 'main',
                                           approvals int default 1) returns bigint
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch := gnomon._branch_row(branch); id bigint;
begin
  if b.id = 0 then raise exception 'open change requests from a branch' using hint = '[gnomon:open_change_requests_branch]'; end if;
  insert into gnomon.change_request(branch, target, title, body, required_approvals, opened_by)
  values (b.id, (gnomon._branch_row(target)).id, title, body, approvals, _gnomon.who()::name) returning change_request.id into id;
  perform _gnomon.notify_event('change_request', _gnomon.cr_event(id));   -- review finds you
  return id;
end $$;
grant execute on function gnomon.open_change_request(text, text, text, text, int) to public;

create function gnomon.review(cr bigint, verdict text, body text default null) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare r gnomon.change_request; who text := _gnomon.who();
begin
  select * into r from gnomon.change_request where id = cr;
  if r.id is null then raise exception 'no change request %', cr using hint = '[gnomon:no_change_request]'; end if;
  if verdict = 'approve' and r.opened_by = who then
    raise exception 'the author of change request % cannot approve it', cr using errcode = '42501', hint = '[gnomon:author_change_request_cannot]';
  end if;
  if verdict = 'approve' and exists (select 1 from gnomon.confined c where c.role = who) then
    raise exception 'confined role % cannot approve change requests', who using errcode = '42501', hint = '[gnomon:confined_role_cannot_approve]';
  end if;
  -- what the reviewer saw (with this transaction's writes): a later write makes the review stale
  insert into gnomon.review(cr, reviewer, verdict, body, coord, head)
  values (cr, who::name, verdict, body, gnomon._coordinate_self(), _gnomon.branch_head(r.branch));
  update gnomon.change_request set status = case when gnomon._cr_approved(cr) then 'approved' else 'open' end
   where id = cr and status in ('open', 'approved');
end $$;
grant execute on function gnomon.review(bigint, text, text) to public;

-- The newest version key a branch has written (its head): one index-only read per
-- tracked table, at review time only.
create function _gnomon.branch_head(b int) returns int8 language plpgsql stable
security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; k int8; m int8;
begin
  for t in select * from gnomon.tracked loop
    execute format('select greatest((select max(gn_key) from %s where gn_branch = $1), (select max(gn_key) from %s where gn_branch = $1))',
                   _gnomon.obj(t, 'bv'), _gnomon.obj(t, 'bv_u')) into k using b;
    m := greatest(m, k);
  end loop;
  return m;
end $$;

-- Has a branch been written, or its base moved (rebase), since a coordinate? A version that is not
-- visible there was written after it, or was in flight and unseen: either way, not what a reviewer
-- at that coordinate approved. Merges of children into the branch write versions too.
create function _gnomon.branch_changed_since(b int, c gnomon.coord) returns bool language plpgsql stable
security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; hit bool; km int8 := gnomon._kxmin(c);
begin
  if c is null then return true; end if;
  if exists (select 1 from gnomon.branch_base bb where bb.branch = b and bb.since_key is not null
                and not gnomon._vis(bb.since_key, bb.since_xoff, c)) then
    return true;
  end if;
  if exists (select 1 from _gnomon.cleared x where x.branch = b and not gnomon._vis(x.key, x.xoff, c)) then return true; end if;
  for t in select * from gnomon.tracked loop
    execute format($q$select exists (select 1 from %1$s v where v.gn_branch = $1 and v.gn_key >= $2 and not gnomon._vis(v.gn_key, v.gn_xoff, $3))
                          or exists (select 1 from %2$s v where v.gn_branch = $1 and v.gn_key >= $2 and not gnomon._vis(v.gn_key, v.gn_xoff, $3))$q$,
                   _gnomon.obj(t, 'bv'), _gnomon.obj(t, 'bv_u')) into hit using b, km, c;
    if hit then return true; end if;
  end loop;
  return false;
end $$;
revoke all on function _gnomon.branch_changed_since(int, gnomon.coord) from public;
revoke all on function _gnomon.branch_head(int) from public;

-- A review is stale when its branch changed after it (stale_approvals = dismiss).
create function gnomon.review_stale(review_id bigint) returns bool language sql stable
security definer set search_path = pg_catalog, pg_temp as $$
  select _gnomon.branch_changed_since(cr.branch, r.coord)
    from gnomon.review r join gnomon.change_request cr on cr.id = r.cr
   where r.id = review_id
$$;

-- Approved: enough reviewers whose latest verdict is approve and not stale, and no reviewer's
-- latest verdict is reject. With stale_approvals = keep, approvals never go stale.
create function gnomon._cr_approved(cr bigint) returns bool language sql stable as $$
  with latest as (select distinct on (reviewer) reviewer, verdict, id from gnomon.review
                   where review.cr = _cr_approved.cr and verdict <> 'comment' order by reviewer, id desc)
  select count(*) filter (where verdict = 'approve'
                            and (gnomon._cfg('stale_approvals') = 'keep' or not gnomon.review_stale(latest.id)))
           >= (select required_approvals from gnomon.change_request where id = cr)
         and count(*) filter (where verdict = 'reject') = 0
    from latest
$$;

create function gnomon.add_check(name text, sql text, expect text default 'empty', target text default 'main') returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  if not pg_has_role(_gnomon.who(), 'gnomon_admin', 'member') then
    raise exception 'adding checks requires gnomon_admin' using errcode = '42501', hint = '[gnomon:adding_checks_requires_gnomon_admin]';
  end if;
  insert into gnomon."check"(name, sql, expect, target, created_by) values (name, sql, expect, (gnomon._branch_row(target)).id, _gnomon.who()::name)
    on conflict on constraint check_pkey do update set sql = excluded.sql, expect = excluded.expect, target = excluded.target;
end $$;
grant execute on function gnomon.add_check(text, text, text, text) to public;

create function gnomon.drop_check(name text) returns void language sql volatile as $$
  delete from gnomon."check" c where c.name = drop_check.name
$$;

-- Run one check in the current context. Returns (passed, detail).
-- Checks see the tracked schemas (and public) by name, whichever search_path the caller had.
create function _gnomon.check_path() returns text language sql stable as $$
  select coalesce(string_agg(distinct quote_ident(nsp), ', '), 'public') || ', public' from gnomon.tracked
$$;

create function _gnomon.run_check(c gnomon."check", out passed bool, out detail text) language plpgsql volatile as $$
declare n bigint; v bool;
begin
  if c.expect = 'true' then
    execute c.sql into v;
    passed := coalesce(v, false); detail := format('result: %s', v);
  else
    execute format('select count(*) from (%s) q', c.sql) into n;
    passed := case when c.expect = 'empty' then n = 0 else n > 0 end;
    detail := format('%s row(s)', n);
  end if;
exception when others then
  passed := false; detail := 'error: ' || sqlerrm;
end $$;

-- Checks on a branch (the change request's view of the data), on request.
-- (a definer, so a role that may write the branch, an agent included, runs them;
-- the checks are gnomon_admin's SQL and already run with gnomon's rights inside merges)
create function gnomon.run_checks(branch text, cr bigint default null)
returns table(check_name text, passed bool, detail text) language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch := gnomon._branch_row(branch); c gnomon."check"; r record;
        ob text := current_setting('gnomon.branch', true); oa text := current_setting('gnomon.as_of', true);
        sp text := current_setting('search_path');
begin
  if b.id <> 0 and not (gnomon._may_write(b) or gnomon._may_manage(b)) then
    raise exception 'role % may not run checks on branch "%"', _gnomon.who(), b.name using errcode = '42501', hint = '[gnomon:branch_not_writable]';
  end if;
  perform set_config('search_path', _gnomon.check_path(), true);
  perform set_config('gnomon._orig_path', '', true);
  perform gnomon.use(b.name, null, true);
  for c in select * from gnomon."check" order by name loop
    select * into r from _gnomon.run_check(c);
    insert into gnomon.check_run(cr, check_name, on_branch, phase, passed, detail) values (cr, c.name, b.id, 'branch', r.passed, r.detail);
    check_name := c.name; passed := r.passed; detail := r.detail;
    return next;
  end loop;
  perform set_config('gnomon.branch', coalesce(ob, ''), true);
  perform set_config('gnomon.as_of', coalesce(oa, ''), true);
  perform set_config('search_path', sp, true);
end $$;

-- Inside the merge transaction, against the merged state; any failure aborts the merge.
-- A merge needs its branch's open change request approved, and one at all into main when
-- require_change_request is on. Returns that change request's id.
create function gnomon._merge_gate(source int, target int) returns bigint language plpgsql stable as $$
declare cr gnomon.change_request;
begin
  select * into cr from gnomon.change_request where branch = source and status in ('open', 'approved') order by id desc limit 1;
  if cr.id is not null and not gnomon._cr_approved(cr.id) then
    if cr.status = 'approved' then
      raise exception 'change request % was approved, but its branch changed after the approval', cr.id
        using errcode = '42501', hint = 'Ask for a new review of what the branch holds now. [gnomon:approval_stale]';
    end if;
    raise exception 'change request % for this branch is not approved', cr.id using errcode = '42501',
      hint = '[gnomon:not_approved]';
  end if;
  if cr.id is null and target = 0 and gnomon._cfg('require_change_request') = 'on' then
    raise exception 'merges into main require an approved change request' using errcode = '42501', hint = '[gnomon:change_request_required]';
  end if;
  -- merges into main only inside the merge window, when one is set
  if target = 0 and coalesce(gnomon._cfg('merge_window'), '') <> '' then
    declare w text[] := regexp_match(gnomon._cfg('merge_window'), '^\s*(\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})\s*$'); nowt time := localtime;
    begin
      if w is null then raise exception 'merge_window must look like 09:00-17:00, not %', gnomon._cfg('merge_window') using hint = '[gnomon:merge_window_must_look_like]'; end if;
      if not (case when w[1]::time <= w[2]::time then nowt >= w[1]::time and nowt < w[2]::time
                   else nowt >= w[1]::time or nowt < w[2]::time end) then
        raise exception 'merges into main run between % and % only', w[1], w[2] using errcode = '55000', hint = '[gnomon:merge_window]';
      end if;
    end;
  end if;
  return cr.id;
end $$;

create function gnomon._merge_checks(mid bigint, source int, target int) returns void language plpgsql volatile as $$
declare cr gnomon.change_request; c gnomon."check"; r record; failed text := '';
        ob text := current_setting('gnomon.branch', true); oa text := current_setting('gnomon.as_of', true);
        sp text := current_setting('search_path');
begin
  select * into cr from gnomon.change_request where id = gnomon._merge_gate(_merge_checks.source, _merge_checks.target);
  perform set_config('search_path', _gnomon.check_path(), true);
  perform set_config('gnomon._orig_path', '', true);
  perform gnomon.use(coalesce((select name from gnomon.branch where id = target), 'main'), null, true);
  for c in select * from gnomon."check" where "check".target = _merge_checks.target order by name loop
    select * into r from _gnomon.run_check(c);
    insert into gnomon.check_run(cr, merge_id, check_name, on_branch, phase, passed, detail)
    values (cr.id, mid, c.name, target, 'merge', r.passed, r.detail);
    if not r.passed then failed := failed || format('%s (%s); ', c.name, r.detail); end if;
  end loop;
  perform set_config('gnomon.branch', coalesce(ob, ''), true);
  perform set_config('gnomon.as_of', coalesce(oa, ''), true);
  perform set_config('search_path', sp, true);
  if failed <> '' then
    raise exception 'merge % rolled back: checks failed on the merged state: %', mid, failed using errcode = '23514', hint = '[gnomon:merge_rolled_back_checks]';
  end if;
end $$;

-------------------------------------------------------------------------------
-- Masked branches: one routing schema per mask profile
-------------------------------------------------------------------------------
create function gnomon.create_mask_profile(name text, note text default null) returns int
language sql volatile as $$
  insert into gnomon.mask_profile(name, note) values (name, note)
    on conflict on constraint mask_profile_pkey do update set note = coalesce(excluded.note, mask_profile.note)
  returning id
$$;

create function gnomon.add_mask_rule(profile text, tbl regclass, col name, expr text) returns void
language plpgsql volatile as $$
begin

  tbl := _gnomon.base_rel(tbl);  if not exists (select 1 from pg_attribute where attrelid = tbl and attname = col and not attisdropped) then
    raise exception 'column % of % does not exist', col, tbl using hint = '[gnomon:column_does_not_exist]';
  end if;
  insert into gnomon.mask_rule(profile, tbl, col, expr) values (profile, tbl, col, expr)
    on conflict on constraint mask_rule_pkey do update set expr = excluded.expr;
end $$;

create function _gnomon.mask_schema(profile_id int, nsp name) returns text language sql immutable as $$
  select format('gnomon_r_%s__m%s', nsp, profile_id)
$$;

-- Masked write path: restore the real value of any masked column whose new value equals its mask.
create function _gnomon.masked_write(tid int, profile text, op text, o jsonb, n jsonb) returns jsonb
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked := _gnomon.trow(tid); c _gnomon.ctx := gnomon._ctx(); real jsonb; m record; masked jsonb; r jsonb;
        who text := _gnomon.who(); q text := _gnomon.qrel(_gnomon.trow(tid)); mv text;
begin
  mv := _gnomon.mask_schema((select id from gnomon.mask_profile where name = profile), t.nsp) || '.' || quote_ident(t.relname);
  if c.main_now then raise exception 'masked roles write branches only' using errcode = '42501', hint = '[gnomon:masked_roles_write_branches]'; end if;
  -- the checks of every branch write: as_of, the branch's status, privileges, confinement
  perform gnomon._write_check(c, tid, op, who, mv::regclass);
  if op <> 'INSERT' then
    real := (select x.r from _gnomon.read_rows(tid, row((select name from gnomon.branch where id = c.branch), null)::gnomon.ref,
                                                 jsonb_build_array(_gnomon.keyj(t, o))) x limit 1);
    if real is null then raise exception 'row changed concurrently' using errcode = '40001', hint = '[gnomon:row_changed_concurrently]'; end if;
    if op = 'UPDATE' then
      for m in select * from gnomon.mask_rule mr where mr.profile = masked_write.profile and mr.tbl = t.rel loop
        execute format('select to_jsonb(%s) from jsonb_populate_record(null::%s, $1) as %I', m.expr, q, t.relname) into masked using real;
        if (n -> m.col::text) is not distinct from masked then
          n := jsonb_set(n, array[m.col::text], coalesce(real -> m.col::text, 'null'::jsonb));
        end if;
      end loop;
    end if;
    o := real;
  end if;
  perform _gnomon.apply_branch(tid, c, lower(op), o, n);
  return n;
end $$;
grant execute on function _gnomon.masked_write(int, text, text, jsonb, jsonb) to public;

create function gnomon.build_mask_profile(profile text) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare p gnomon.mask_profile; t gnomon.tracked; s text; sel text; ms text; r record; cr record;
        prev text := coalesce(current_setting('gnomon._in_ddl', true), '');
begin
  select * into p from gnomon.mask_profile where name = profile;
  if p.name is null then raise exception 'unknown mask profile "%"', profile using hint = '[gnomon:unknown_mask_profile]'; end if;
  -- our own DDL: the event triggers stay out. Dropping the mask schema below is a DROP SCHEMA,
  -- which would otherwise take down every pass-through view (on_ddl_start) and have
  -- on_ddl_end build this profile again from under us. The caller's state is restored at the end.
  perform set_config('gnomon._in_ddl', '1', true);
  for s in select distinct nsp from gnomon.tracked loop
    ms := _gnomon.mask_schema(p.id, s);
    execute format('drop schema if exists %I cascade', ms);
    execute format('create schema %I', ms);
    execute format('alter schema %I owner to gnomon_reader', ms);
    -- tracked tables: masking expressions in the select list over the routing view
    for t in select * from gnomon.tracked where nsp = s loop
      select string_agg(case when mr.expr is not null then format('(%s) as %I', mr.expr, a.attname) else format('%I.%I', t.relname, a.attname) end,
                        ', ' order by a.attnum)
        into sel
        from pg_attribute a left join gnomon.mask_rule mr on mr.profile = p.name and mr.tbl = t.rel and mr.col = a.attname
       where a.attrelid = t.rel and a.attnum > 0 and not a.attisdropped;
      execute format('create view %I.%I as select %s from %s as %I', ms, t.relname, sel, _gnomon.robj(t), t.relname);
      execute format('alter view %I.%I owner to gnomon_reader', ms, t.relname);
      execute format($f$create or replace function %I.%I() returns trigger language plpgsql as $b$
        declare r jsonb;
        begin
          r := _gnomon.masked_write(%s, %L, TG_OP, case when TG_OP <> 'INSERT' then to_jsonb(OLD) end, case when TG_OP <> 'DELETE' then to_jsonb(NEW) end);
          if TG_OP = 'DELETE' then return OLD; end if;
          return NEW;
        end $b$ $f$, ms, t.relname || '__mw', t.id, p.name);
      execute format('create trigger gnomon_mw instead of insert or update or delete on %I.%I for each row execute function %I.%I()',
                     ms, t.relname, ms, t.relname || '__mw');
    end loop;
    -- untracked tables and views: masked or plain pass-through, read-only
    for r in select c.oid::regclass as rel, c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = s and c.relkind in ('r','p','v','m','f')
                and not exists (select 1 from gnomon.tracked tt where tt.rel = c.oid) loop
      select string_agg(case when mr.expr is not null then format('(%s) as %I', mr.expr, a.attname) else format('%I.%I', r.relname, a.attname) end,
                        ', ' order by a.attnum)
        into sel
        from pg_attribute a left join gnomon.mask_rule mr on mr.profile = p.name and mr.tbl = r.rel and mr.col = a.attname
       where a.attrelid = r.rel and a.attnum > 0 and not a.attisdropped;
      begin
        execute format('create view %I.%I as select %s from %s as %I', ms, r.relname, sel,
                       coalesce((select format('%I.%I', 'gnomon_r_' || s, r.relname) where exists (
                         select 1 from pg_class c2 join pg_namespace n2 on n2.oid = c2.relnamespace where n2.nspname = 'gnomon_r_' || s and c2.relname = r.relname)),
                         r.rel::text), r.relname);
        execute format('alter view %I.%I owner to gnomon_reader', ms, r.relname);
      exception when others then
        raise warning 'gnomon: no masked view for %: %', r.rel, sqlerrm;
      end;
    end loop;
    -- roles confined to this profile see only this schema
    for cr in select role from gnomon.confined where mask_profile = p.name loop
      execute format('grant usage on schema %I to %I', ms, cr.role);
      execute format('grant select, insert, update, delete on all tables in schema %I to %I', ms, cr.role);
      execute format('grant execute on all functions in schema %I to %I', ms, cr.role);
    end loop;
  end loop;
  perform set_config('gnomon._in_ddl', prev, true);
end $$;

-------------------------------------------------------------------------------
-- Held outbox: rows written on a branch stay in its heads until merge
-------------------------------------------------------------------------------
create function _gnomon.outbox_notify() returns trigger language plpgsql as $$
begin
  perform pg_notify(TG_ARGV[0], json_build_object('table', TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, 'row', to_jsonb(NEW))::text);
  return null;
end $$;

create function gnomon.outbox(tbl regclass, channel text default 'gnomon_outbox') returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
begin
  perform _gnomon.require_manage(_gnomon.base_rel(tbl));

  tbl := _gnomon.base_rel(tbl);  update gnomon.tracked set outbox = true where rel = tbl;
  if not found then raise exception '% must be tracked to act as a held outbox', tbl using hint = '[gnomon:must_tracked_act_held]'; end if;
  execute format('drop trigger if exists gnomon_outbox on %s', tbl);
  -- fires on main only: direct writes deliver now, branch writes deliver when merged
  execute format('create trigger gnomon_outbox after insert on %s for each row execute function _gnomon.outbox_notify(%L)', tbl, channel);
end $$;

-- Delivery bookkeeping: rows that reached main since the consumer's last poll.
create function gnomon.outbox_poll(consumer text, tbl regclass, lim int default 100)
returns table(key jsonb, row_data jsonb, vkey int8) language plpgsql volatile as $$
declare cname text := 'outbox:' || consumer || ':' || tbl::text;
begin

  tbl := _gnomon.base_rel(tbl);  if not exists (select 1 from gnomon.consumer where name = cname) then
    perform gnomon.feed_create(cname, gnomon.coord_text((select track_coord from gnomon.tracked where rel = tbl)));
  end if;
  return query select f.key, f.new, f.vkey from gnomon.feed_poll(cname, lim) f where f.tbl = outbox_poll.tbl and f.op = 'insert';
end $$;
