-- SCD type-2 views, series and events, the graph, metrics.
create table cust (id int primary key, name text not null, tier text not null default 'basic');
create table ord (id int primary key, cust int not null references cust(id), total int not null);
create table line (id int primary key, ord int not null references ord(id), sku text not null);
create index on ord (cust);
insert into cust select g, 'c' || g from generate_series(1, 5) g;
insert into ord select g, 1 + g % 5, g * 10 from generate_series(1, 10) g;
insert into line select g, 1 + g % 10, 'sku' || g from generate_series(1, 20) g;
select gnomon.track('cust'); select gnomon.track('ord'); select gnomon.track('line');
select gnomon.tick();
update cust set tier = 'gold' where id = 1;
select gnomon.tick();
update cust set name = 'Ann' where id = 1;
update cust set tier = 'silver' where id = 2;
delete from line where id = 20;
select gnomon.tick();

-- SCD type 2: rows valid at each tick equal the as-of read there
select gnomon.scd2('cust');
select t.eq((select count(*) from cust_history where id = 1), 3::bigint, 'tracked, gold, Ann');
select t.eq((select count(*) from cust_history where id = 1 and is_current), 1::bigint, 'one current row');
select t.eq((select count(*) from cust_history where id = 3), 1::bigint, 'a row never changed: one row since tracking');
select t.eq((select name from cust_history where id = 1 and is_current), 'Ann', 'the current version');
do $$
declare tk gnomon.tick; a jsonb; b jsonb;
begin
  for tk in select * from gnomon.tick order by id loop
    perform gnomon.use('main', gnomon.coord_text(tk.coord));
    select coalesce(jsonb_agg(jsonb_build_array(id, name, tier) order by id), '[]') into a from cust;
    perform gnomon.use('main');
    select coalesce(jsonb_agg(jsonb_build_array(id, name, tier) order by id), '[]') into b from cust_history h
     where h.valid_from <= tk.at and (h.valid_to is null or h.valid_to > tk.at);
    perform t.eq(b, a, 'SCD rows valid at tick ' || tk.id || ' equal the as-of read');
  end loop;
end $$;
select gnomon.scd2('line');
select t.eq((select count(*) from line_history where id = 20 and is_current), 0::bigint, 'a deleted row has no current version');
select t.ok((select valid_to from line_history where id = 20) is not null, 'its validity ended');
select t.ok((select count(*) from gnomon.scd2_changes('cust', (select gnomon.coord_text(coord) from gnomon.tick order by id limit 1))) >= 2, 'changes for incremental loads');

-- series and events
select t.eq((select string_agg(value #>> '{}', ',' order by at) from gnomon.series('cust', '1', 'tier')), 'basic,gold', 'a column over time');
select t.ok((select count(*) from gnomon.metric_series('select count(*) from cust where tier <> ''basic''', (select min(at) from gnomon.tick), now(), '1 second', 1000)) >= 1, 'a metric over time');
select t.eq((select value from gnomon.metric_series_incremental('cust', 'count', null, 'tier <> ''basic''') order by vkey desc limit 1), 2::numeric, 'an incremental count');
select t.ok(exists (select 1 from gnomon.events('cust', '2') where rel = 'cust'::regclass and op = 'update'), 'events of a row');

-- the graph
select t.eq((select count(*) from gnomon.neighbors('cust', '1', 1) where level = 1 and rel = 'ord'::regclass), 2::bigint, 'children by foreign key');
select t.ok(exists (select 1 from gnomon.neighbors('ord', '1', 1) where rel = 'cust'::regclass), 'the parent');
select t.ok(exists (select 1 from gnomon.neighbors('cust', '1', 2) where level = 2 and rel = 'line'::regclass), 'two levels deep');
select t.eq((select count(*) from gnomon.neighbors('cust', '1', 3, 'both', 4) where level > 0), 4::bigint, 'capped (the start row comes on top)');
select gnomon.link('cust_by_name', 'line', array['sku'], 'cust', array['name']);
update line set sku = 'Ann' where id = 1;
select t.ok(exists (select 1 from gnomon.neighbors('line', '1', 1) where via = 'link:cust_by_name'), 'a declared link');
select gnomon.create_branch('g');
select gnomon.use('g');
update ord set total = 0 where id = 1;
insert into line values (99, 1, 'new');
select t.ok(exists (select 1 from gnomon.neighbors('ord', '1', 1) where rel = 'public.line'::regclass and row_key = '{"id": 99}'), 'neighbors follow the session''s branch');
select gnomon.use('main');
select t.eq(jsonb_array_length(gnomon.impact('g') -> 'nodes'), 2, 'impact: the changed rows');
select t.eq(jsonb_array_length(gnomon.impact('g') -> 'edges'), 1, 'and the edge between them');
select t.ok(exists (select 1 from gnomon.doctor() where check_name = 'fk_index public.line'), 'doctor: a foreign key without an index');

-- metrics
select t.ok(exists (select 1 from gnomon.metrics() where name = 'gnomon_version_bytes' and labels ->> 'table' = 'public.cust'), 'version bytes per table');
select t.ok(gnomon.metrics_text() like '%# TYPE gnomon_tick_lag_seconds gauge%', 'Prometheus text');
select t.eq((select value from gnomon.metrics() where name = 'gnomon_ledger_verification_ok'), -1::float8, 'no verification yet');
select count(*) from gnomon.verify_ledger();
select t.eq((select value from gnomon.metrics() where name = 'gnomon_ledger_verification_ok'), 1::float8, 'the last verification''s result');
select t.ok((select value from gnomon.metrics() where name = 'gnomon_ledger_last_verification_seconds') between 0 and 60, 'and its age');
