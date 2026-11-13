-- A table kept in dbt's snapshot shape from the change feed (gnomon.dbt_snapshot,
-- the gnomon_dbt package's materialization). The rows valid at any tick equal the as-of read
-- there; a second run applies only what changed since; hard deletes close rows; a run twice
-- over the same changes changes nothing.
create table cust (id int primary key, name text not null, tier text);
insert into cust select g, 'c' || g, 'basic' from generate_series(1, 12) g;
select gnomon.track('cust');
create table t.ticks (n int primary key, coord text, at timestamptz);
create procedure t.work(base int) language plpgsql as $$
begin
  for i in 1..6 loop
    update cust set tier = 'gold' || (base + i) where id = (base + i) % 12 + 1;
    commit;
    if i % 3 = 0 then delete from cust where id = (base + i) % 12 + 1; insert into cust values (100 + base + i, 'new', 'x'); commit; end if;
    perform gnomon._do_tick(true);
    commit;
    insert into t.ticks select coalesce(max(n), 0) + 1, gnomon.coordinate_text(), (select max(at) from gnomon.tick) from t.ticks;
    commit;
    perform pg_sleep(0.01);
  end loop;
end $$;
call t.work(0);
select t.eq((gnomon.dbt_snapshot('cust', 'public.cust_snap')) ->> 'first', 'true', 'the first run loads the history');
create function t.at_tick(c text, at timestamptz) returns jsonb language plpgsql as $$
declare want jsonb; got jsonb;
begin
  perform gnomon.use('main', c);
  select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'tier', tier) order by id) into want from cust;
  perform gnomon.use('main');
  select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'tier', tier) order by id) into got from public.cust_snap
   where dbt_valid_from <= at and (dbt_valid_to is null or dbt_valid_to > at);
  return jsonb_build_object('want', want, 'got', got);
end $$;
do $$ declare k record; r jsonb; begin
  for k in select * from t.ticks loop
    r := t.at_tick(k.coord, k.at);
    perform t.eq(r -> 'got', r -> 'want', 'snapshot rows valid at tick ' || k.n || ' equal the as-of read');
  end loop;
end $$;
call t.work(10);
select t.eq((gnomon.dbt_snapshot('cust', 'public.cust_snap')) ->> 'first', 'false', 'a later run is incremental');
do $$ declare k record; r jsonb; begin
  for k in select * from t.ticks loop
    r := t.at_tick(k.coord, k.at);
    perform t.eq(r -> 'got', r -> 'want', 'after the second run, tick ' || k.n);
  end loop;
end $$;
select t.eq(((gnomon.dbt_snapshot('cust', 'public.cust_snap')) ->> 'inserted')::int, 0, 'a run with nothing new adds nothing');
select t.ok((select count(*) = count(distinct dbt_scd_id) from public.cust_snap), 'dbt_scd_id is unique');
select t.ok((select count(*) from public.cust_snap where dbt_valid_to is null) = (select count(*) from cust), 'one open row per live row');
