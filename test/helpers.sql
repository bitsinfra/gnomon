-- Assertions for the SQL tests.
create schema t;
create function t.ok(cond bool, msg text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAILED: %', msg; end if;
end $$;
create function t.eq(a anyelement, b anyelement, msg text) returns void language plpgsql as $$
begin
  if a is distinct from b then raise exception 'FAILED: % (got %, expected %)', msg, a, b; end if;
end $$;
-- Run SQL and expect an error with a SQLSTATE (or any error when state is null).
create function t.fails(q text, state text default null, msg text default null) returns void language plpgsql as $$
begin
  begin
    execute q;
  exception when others then
    if state is not null and sqlstate <> state then
      raise exception 'FAILED: % raised % (%) instead of %', coalesce(msg, q), sqlstate, sqlerrm, state;
    end if;
    return;
  end;
  raise exception 'FAILED: % did not raise', coalesce(msg, q);
end $$;
-- Rows of a query as a sorted jsonb array, for comparisons.
create function t.rows(q text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute format('select coalesce(jsonb_agg(x order by x::text), ''[]'') from (%s) x', q) into r;
  return r;
end $$;
grant usage on schema t to public;
grant execute on all functions in schema t to public;
