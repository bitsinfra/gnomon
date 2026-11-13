-- Merge fuzzing: random base/ours/theirs per strategy, checking the invariants.
-- The case count is :fuzz_n per strategy (default 2000 here; a long run, as CI's nightly job does:
-- `psql -v fuzz_n=1000000 -f test/sql/08_merge_fuzz.sql`).
\if :{?fuzz_n}
\else
\set fuzz_n 2000
\endif

create function t.rnd_value(strategy text) returns jsonb language plpgsql volatile as $$
declare r float8 := random();
begin
  case strategy
    when 'counter' then return to_jsonb((random() * 20)::int - 10);
    when 'set' then return (select coalesce(jsonb_agg(x), '[]') from (select distinct ((random() * 6)::int) x from generate_series(1, (random() * 4)::int)) s);
    when 'jsonb' then return (select coalesce(jsonb_object_agg('k' || ((random() * 4)::int), case when random() < 0.3 then jsonb_build_object('n', (random() * 3)::int) else to_jsonb((random() * 3)::int) end), '{}')
                                from generate_series(1, (random() * 4)::int));
    when 'text3' then return to_jsonb(array_to_string(array(select chr(97 + (random() * 4)::int) from generate_series(1, 3 + (random() * 4)::int)), E'\n'));
    else return case when r < 0.1 then 'null'::jsonb else to_jsonb((random() * 5)::int) end;
  end case;
end $$;

-- a random variation of a value (so sides often share structure with the base)
create function t.vary(strategy text, b jsonb) returns jsonb language plpgsql volatile as $$
declare lines text[];
begin
  if random() < 0.35 then return b; end if;
  if strategy = 'text3' and jsonb_typeof(b) = 'string' and random() < 0.8 then
    lines := string_to_array(b ->> 0, E'\n');
    lines[1 + (random() * (cardinality(lines) - 1))::int] := chr(65 + (random() * 4)::int);
    return to_jsonb(array_to_string(lines, E'\n'));
  end if;
  if strategy = 'jsonb' and jsonb_typeof(b) = 'object' and random() < 0.8 then
    return b || jsonb_build_object('k' || ((random() * 4)::int), (random() * 3)::int);
  end if;
  return t.rnd_value(strategy);
end $$;

create function t.setof(j jsonb) returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(x order by x), '[]') from (select distinct x from jsonb_array_elements(coalesce(j, '[]')) x) s
$$;

create function t.fuzz(strategy text, n int) returns int language plpgsql volatile as $$
declare b jsonb; o jsonb; th jsonb; r jsonb; r2 jsonb; s jsonb; rb jsonb; dm jsonb; fails int := 0; i int;
begin
  for i in 1..n loop
    b := t.rnd_value(strategy); o := t.vary(strategy, b); th := t.vary(strategy, b);
    -- identities
    if strategy <> 'counter' and (_gnomon.m3_value(strategy, b, o, o, 'c') -> 'v') is distinct from o then raise exception 'FAILED % merge(b,x,x)=x: % %', strategy, b, o; end if;
    if (_gnomon.m3_value(strategy, b, b, th, 'c') -> 'v') is distinct from th then raise exception 'FAILED % merge(b,b,t)=t: % %', strategy, b, th; end if;
    if (_gnomon.m3_value(strategy, b, o, b, 'c') -> 'v') is distinct from o then raise exception 'FAILED % merge(b,o,b)=o: % %', strategy, b, o; end if;
    r := _gnomon.m3_value(strategy, b, o, th, 'c');
    r2 := _gnomon.m3_value(strategy, b, th, o, 'c');
    -- conflicts are symmetric when the sides are swapped
    if (r ? 'c') <> (r2 ? 'c') then raise exception 'FAILED % conflict symmetry: b=% o=% t=%', strategy, b, o, th; end if;
    if r ? 'c' then continue; end if;
    -- counters: result - base = (ours - base) + (theirs - base)
    if strategy = 'counter' and jsonb_typeof(b) = 'number' and
       ((r ->> 'v')::numeric - (b::text)::numeric) <> (((o::text)::numeric - (b::text)::numeric) + ((th::text)::numeric - (b::text)::numeric)) then
      raise exception 'FAILED counter arithmetic: b=% o=% t=% r=%', b, o, th, r;
    end if;
    -- jsonb: every path changed on only one side has that side's value
    if strategy = 'jsonb' and jsonb_typeof(r -> 'v') = 'object' then
      if exists (select 1 from jsonb_each(o) e where (b -> e.key) is distinct from e.value and (b -> e.key) is not distinct from (th -> e.key)
                  and (r -> 'v' -> e.key) is distinct from e.value) then
        raise exception 'FAILED jsonb lost an ours-only change: b=% o=% t=% r=%', b, o, th, r;
      end if;
    end if;
    -- applying a merge twice is a no-op. For state-based strategies even re-applying theirs over
    -- the old base changes nothing; counters and sets are operation-based, and for them the
    -- system makes the second merge a no-op by moving the base (tested in 03_merge).
    -- text3 (diff3) may instead report a conflict when repeated lines make the alignment
    -- ambiguous, as GNU diff3 does; it must never silently produce a different text (a clean
    -- result is a fixed point of re-applying either side).
    if strategy not in ('set', 'counter') then
      r2 := _gnomon.m3_value(strategy, b, r -> 'v', th, 'c');
      if (r2 -> 'v') is distinct from (r -> 'v') and not (strategy = 'text3' and r2 ? 'c') then
        raise exception 'FAILED % idempotence: b=% o=% t=% r=% again=%', strategy, b, o, th, r, r2;
      end if;
    end if;
    -- (undo(merge) and rebase-then-merge are properties of whole merges: t.fuzz_rows below runs
    -- them on tables, through gnomon.merge, gnomon.rebase and gnomon.undo_merge)
  end loop;
  return n;
end $$;

-- Whole merges on random rows: with two branches made identically, a direct merge of
-- one and a rebase-then-merge of the other leave main the same (when neither conflicts), and
-- undo_merge restores main exactly as it was before the merge.
create table fz (id int primary key, a int not null, n int not null, j jsonb not null);
insert into fz select g, g, 100, jsonb_build_object('x', g, 'y', 0) from generate_series(1, 12) g;
select gnomon.track('fz');
select gnomon.set_merge_strategy('fz', 'n', 'counter');
select gnomon.set_merge_strategy('fz', 'j', 'jsonb');

create function t.fz_state() returns jsonb language sql as $$
  select coalesce(jsonb_agg(to_jsonb(f) order by f.id), '[]') from public.fz f   -- (qualified: main's rows)
$$;
-- random edits as SQL text, so two branches can get the same ones
create function t.fz_edits(k int) returns text[] language plpgsql volatile as $$
declare e text[] := '{}'; id int; r float8;
begin
  for i in 1..1 + (random() * 4)::int loop
    id := 1 + (random() * 13)::int; r := random();
    e := e || case
      when r < 0.3 then format('update fz set a = %s where id = %s', (random() * 50)::int, id)
      when r < 0.55 then format('update fz set n = n + %s where id = %s', (random() * 10)::int - 5, id)
      when r < 0.75 then format('update fz set j = j || jsonb_build_object(%L, %s) where id = %s', (array['x', 'y', 'z'])[1 + (random() * 2)::int], (random() * 9)::int, id)
      when r < 0.85 then format('delete from fz where id = %s and id > 12', id)   -- only rows the fuzz added
      else format('insert into fz values (%s, 0, 0, ''{}'') on conflict do nothing', 100 + k * 10 + i) end;
  end loop;
  return e;
end $$;
create function t.fz_apply(edits text[]) returns void language plpgsql as $$
declare q text;
begin
  foreach q in array edits loop
    begin
      execute q;
    exception when unique_violation or check_violation then null;   -- (an edit that does not apply here)
    end;
  end loop;
end $$;

-- (a procedure: every step commits, as an application's would; inside one transaction a
-- coordinate does not include that transaction's own writes)
create procedure t.fuzz_rows(n int) language plpgsql as $$
declare be text[]; me text[]; s0 jsonb; x jsonb; y jsonb; ma bigint; mb bigint; ok_direct bool; compared int := 0; undone int := 0;
begin
  for k in 1..n loop
    perform gnomon.use('main');
    perform gnomon.create_branch('fa' || k); perform gnomon.create_branch('fb' || k);
    commit;
    be := t.fz_edits(k);
    perform gnomon.use('fa' || k); perform t.fz_apply(be); commit;
    perform gnomon.use('fb' || k); perform t.fz_apply(be); commit;
    perform gnomon.use('main');
    me := t.fz_edits(k + 1000);
    perform t.fz_apply(me); commit;
    s0 := t.fz_state();
    -- the direct merge, rolled back once its result is known
    ok_direct := false; x := null;
    begin
      ma := gnomon.merge('fa' || k);
      if (select status from gnomon.merge where id = ma) = 'applied' then ok_direct := true; x := t.fz_state(); end if;
      raise exception using errcode = 'P0001', message = 'gn_fuzz_rollback';
    exception when sqlstate 'P0001' then
      if sqlerrm <> 'gn_fuzz_rollback' then raise; end if;
    end;
    commit;
    if t.fz_state() is distinct from s0 then raise exception 'FAILED fuzz_rows: the rolled-back merge left changes'; end if;
    -- rebase the twin, then merge it
    perform gnomon.rebase('fb' || k); commit;
    if not exists (select 1 from gnomon.conflict c join gnomon.branch b on b.id = c.branch where b.name = 'fb' || k) then
      mb := gnomon.merge('fb' || k); commit;
      if (select status from gnomon.merge where id = mb) = 'applied' then
        y := t.fz_state();
        if ok_direct then
          if x is distinct from y then
            raise exception 'FAILED rebase+merge <> merge: edits % main % direct % rebased %', be, me, x, y;
          end if;
          compared := compared + 1;
        end if;
        -- undo(merge) restores main when nothing else changed
        perform gnomon.undo_merge(mb); commit;
        if t.fz_state() is distinct from s0 then
          raise exception 'FAILED undo(merge): edits % main % before % after undo %', be, me, s0, t.fz_state();
        end if;
        undone := undone + 1;
      end if;
    end if;
    perform gnomon.drop_branch('fa' || k, true); perform gnomon.drop_branch('fb' || k, true);
    delete from gnomon.conflict where branch is not null or merge_id is not null;
    commit;
  end loop;
  if compared = 0 or undone = 0 then raise exception 'FAILED fuzz_rows exercised nothing (compared %, undone %)', compared, undone; end if;
  raise notice 'fuzz_rows: % rebase+merge comparisons, % undos', compared, undone;
end $$;
call t.fuzz_rows(least(greatest(:fuzz_n / 40, 20), 300));

-- Sibling merges: two siblings merged into each other and then into main leave
-- main as merging both into main directly does, when nothing conflicts. (Counter columns are left
-- out: a delta that reaches main twice, once through the sibling, is counted twice.)
create function t.fz_edits_nc(k int) returns text[] language plpgsql volatile as $$
declare e text[] := '{}'; id int; r float8;
begin
  for i in 1..1 + (random() * 3)::int loop
    id := 1 + (random() * 13)::int; r := random();
    e := e || case
      when r < 0.45 then format('update fz set a = %s where id = %s', (random() * 50)::int, id)
      when r < 0.85 then format('update fz set j = j || jsonb_build_object(%L, %s) where id = %s', (array['x', 'y', 'z'])[1 + (random() * 2)::int], (random() * 9)::int, id)
      else format('insert into fz values (%s, 0, 0, ''{}'') on conflict do nothing', 5000 + k * 10 + i) end;
  end loop;
  return e;
end $$;
create procedure t.fuzz_siblings(n int) language plpgsql as $$
declare ea text[]; eb text[]; s0 jsonb; x jsonb; y jsonb; m1 bigint; m2 bigint; m3 bigint; ok bool; compared int := 0;
begin
  for k in 1..n loop
    perform gnomon.use('main');
    perform gnomon.create_branch('sa' || k); perform gnomon.create_branch('sb' || k); commit;
    ea := t.fz_edits_nc(k); eb := t.fz_edits_nc(k + 500);
    perform gnomon.use('sa' || k); perform t.fz_apply(ea); commit;
    perform gnomon.use('sb' || k); perform t.fz_apply(eb); commit;
    perform gnomon.use('main');
    perform t.fz_apply(t.fz_edits_nc(k + 900)); commit;
    s0 := t.fz_state();
    -- both into main directly, rolled back
    x := null; ok := false;
    begin
      m1 := gnomon.merge('sa' || k);
      m2 := gnomon.merge('sb' || k);
      if (select bool_and(status = 'applied') from gnomon.merge where id in (m1, m2)) then ok := true; x := t.fz_state(); end if;
      raise exception using errcode = 'P0001', message = 'gn_fuzz_rollback';
    exception when sqlstate 'P0001' then
      if sqlerrm <> 'gn_fuzz_rollback' then raise; end if;
    end;
    commit;
    if ok then
      y := null;
      begin
        m1 := gnomon.merge('sa' || k, 'sb' || k);
        m2 := gnomon.merge('sb' || k);
        m3 := gnomon.merge('sa' || k);
        if (select bool_and(status = 'applied') from gnomon.merge where id in (m1, m2, m3)) then y := t.fz_state(); end if;
        -- and a repeated sibling merge is a no-op
        raise exception using errcode = 'P0001', message = 'gn_fuzz_rollback';
      exception when sqlstate 'P0001' then
        if sqlerrm <> 'gn_fuzz_rollback' then raise; end if;
      end;
      commit;
      if y is not null then
        if x is distinct from y then
          raise exception 'FAILED siblings: a % b % direct % via sibling %', ea, eb, x, y;
        end if;
        compared := compared + 1;
      end if;
    end if;
    if t.fz_state() is distinct from s0 then raise exception 'FAILED fuzz_siblings: a rolled-back merge left changes'; end if;
    perform gnomon.drop_branch('sa' || k, true); perform gnomon.drop_branch('sb' || k, true);
    delete from gnomon.conflict where branch is not null or merge_id is not null;
    commit;
  end loop;
  if compared = 0 then raise exception 'FAILED fuzz_siblings exercised nothing'; end if;
  raise notice 'fuzz_siblings: % comparisons', compared;
end $$;
call t.fuzz_siblings(least(greatest(:fuzz_n / 80, 10), 150));

-- Revert: after random inserts, deletes, updates and key changes, a revert to a
-- coordinate leaves no difference between that coordinate and now.
create procedure t.fuzz_revert(n int) language plpgsql as $$
declare c0 text; e text[]; id int; r float8; d bigint;
begin
  for k in 1..n loop
    perform gnomon.use('main');
    c0 := gnomon.coordinate_text(); commit;
    e := '{}';
    for i in 1..1 + (random() * 5)::int loop
      id := 1 + (random() * 13)::int; r := random();
      e := e || case
        when r < 0.3 then format('update fz set a = %s, j = j || ''{"r": %s}'' where id = %s', (random() * 50)::int, k, id)
        when r < 0.5 then format('delete from fz where id = %s', id)
        when r < 0.7 then format('update fz set id = id + 20000 where id = %s', id)
        else format('insert into fz values (%s, 1, 1, ''{}'') on conflict do nothing', 9000 + (random() * 20)::int) end;
    end loop;
    perform t.fz_apply(e); commit;
    perform gnomon.revert_tables(array['fz']::regclass[], c0); commit;
    select count(*) into d from gnomon.diff(c0, 'main');
    if d <> 0 then raise exception 'FAILED revert: edits % left % differences', e, d; end if;
  end loop;
  raise notice 'fuzz_revert: % reverts', n;
end $$;
call t.fuzz_revert(least(greatest(:fuzz_n / 80, 10), 150));

select t.fuzz('conflict', :fuzz_n);
select t.fuzz('counter', :fuzz_n);
select t.fuzz('set', :fuzz_n);
select t.fuzz('jsonb', :fuzz_n);
select t.fuzz('text3', :fuzz_n);

-- row-level: insert/delete/update cases keep their meaning
select t.eq((_gnomon.m3_row(null, null, '{"id":1,"v":1}', '{}', '{id}')).action, 'insert', 'row insert');
select t.eq((_gnomon.m3_row('{"id":1,"v":1}', '{"id":1,"v":1}', null, '{}', '{id}')).action, 'delete', 'row delete');
select t.ok(jsonb_array_length((_gnomon.m3_row('{"id":1,"v":1}', '{"id":1,"v":2}', null, '{}', '{id}')).conflicts) = 1, 'delete vs update conflicts');
select t.ok(jsonb_array_length((_gnomon.m3_row('{"id":1,"v":1}', null, '{"id":1,"v":3}', '{}', '{id}')).conflicts) = 1, 'update vs delete conflicts');
select t.eq((_gnomon.m3_row('{"id":1,"v":1,"w":1}', '{"id":1,"v":2,"w":1}', '{"id":1,"v":1,"w":3}', '{}', '{id}')).result, '{"id":1,"v":2,"w":3}'::jsonb, 'column-wise row merge');
select t.eq((_gnomon.m3_row('{"id":1,"n":10}', '{"id":1,"n":7}', '{"id":1,"n":7}', '{"n":"counter"}', '{id}')).result, '{"id":1,"n":4}'::jsonb, 'counter rows: equal deltas on both sides both apply');
