-- With the C module: a branch session's plain DDL goes to gnomon.ddl, queries that
-- need an index the branch policy would hide read the search views, and the module's
-- counters are kept in shared memory.
create function t.plan(q text) returns text language plpgsql as $$
declare r record; p text := '';
begin
  for r in execute 'explain (costs off) ' || q loop p := p || r."QUERY PLAN" || E'\n'; end loop;
  return p;
end $$;

create table acct (id int primary key, owner text not null, doc jsonb not null default '{}', bal int not null default 0);
insert into acct select g, 'o' || g, jsonb_build_object('k', g), 0 from generate_series(1, 20000) g;
create index acct_doc on acct using gin (doc);
select gnomon.track('acct');
analyze acct;

-- 1. plain DDL from a branch session changes the branch's schema version, not main
select gnomon.create_branch('mig');
set gnomon.branch = 'mig';
alter table acct add column tier text default 'basic';
select t.eq((select tier from acct where id = 1), 'basic', 'a plain ALTER TABLE on a branch session changes the branch');
update acct set tier = 'gold' where id = 2;
create table note (id int primary key, acct_id int references acct(id), body text);
insert into note values (1, 2, 'hi');
select t.eq((select count(*) from note), 1::bigint, 'a plain CREATE TABLE makes a table on the branch');
create index on acct (tier);
comment on column acct.tier is 'the customer''s tier';
create temp table gc_tmp (x int);
insert into gc_tmp values (1);
select t.eq((select count(*) from gc_tmp), 1::bigint, 'a temporary table passes through');
select t.fails('alter table acct add column v int default (random() * 10)::int', '0A000', 'what gnomon.ddl refuses is refused by name');
select gnomon.use('main');
select t.fails('select tier from acct', '42703', 'main does not have the column');
select t.ok(to_regclass('public.note') is null, 'nor the table');
select t.eq((select string_agg(op, ',' order by seq) from gnomon.schema_changes('mig')), 'add_column,create_table,create_index,comment', 'all recorded as the branch''s schema changes');
select t.ok((select value from _gnomon.c_counters() where name = 'ddl_redirects') >= 4, 'counted in shared memory');
select gnomon.merge('mig') as mm \gset
select t.eq((select status from gnomon.merge where id = :mm), 'applied', 'the merge brings them to main');
select t.eq((select tier from acct where id = 2), 'gold', 'with the branch''s values');
select t.eq((select count(*) from note), 1::bigint, 'and its table');

-- 2. search views per query, for roles that may read the table itself
drop role if exists gc_search_app;
create role gc_search_app login;
grant select, insert, update, delete on acct to gc_search_app;
select gnomon.create_branch('srch');
set role gc_search_app;
set gnomon.branch = 'srch';
update acct set doc = '{"k": 25, "b": 1}' where id = 30;
select t.ok(t.plan($$select * from acct where doc @> '{"k": 25}'$$) ~ 'Bitmap Index Scan on acct_doc', 'a jsonb @> on a branch reaches the GIN index');
select t.eq((select string_agg(id::text, ',' order by id) from acct where doc @> '{"k": 25}'), '25,30', 'with the branch''s rows');
select t.ok(t.plan($$select a.id from acct a join acct b on b.id = a.id where a.doc @> '{"k": 25}'$$) !~ 'gnomon_q_', 'a join stays on the routing views');
select t.ok(t.plan('select * from acct where id = 5') !~ 'gnomon_q_', 'a keyed read stays on the routing view');
set gnomon.c_search_views = off;
select t.ok(t.plan($$select * from acct where doc @> '{"k": 25}'$$) !~ 'Bitmap Index Scan on acct_doc', 'gnomon.c_search_views = off: the routing view');
reset gnomon.c_search_views;
reset gnomon.branch;
reset role;
select t.ok((select value from _gnomon.c_counters() where name = 'search_view_queries') >= 1, 'counted in shared memory');
-- never for a confined role
drop role if exists gc_conf;
create role gc_conf login;
grant select on acct to gc_conf;
select gnomon.confine('gc_conf', array['srch']);
set role gc_conf;
set gnomon.branch = 'srch';
select t.ok(t.plan($$select * from acct where doc @> '{"k": 25}'$$) !~ 'Bitmap Index Scan on acct_doc', 'a confined role never gets the search view');
select t.eq((select string_agg(id::text, ',' order by id) from acct where doc @> '{"k": 25}'), '25,30', 'and reads the same rows');
reset gnomon.branch;
reset role;
select gnomon.unconfine('gc_conf');
drop owned by gc_conf; drop role gc_conf;
drop owned by gc_search_app; drop role gc_search_app;
-- the counters are shared: point reads from every session add up
select t.ok((select count(*) from _gnomon.c_counters()) = 10, 'ten counters');
select t.ok(exists (select 1 from gnomon.metrics() where name = 'gnomon_c_point_reads_total' and labels ->> 'answer' = 'main'), 'gnomon.metrics() includes them');
select t.ok((select value from gnomon.metrics() where name = 'gnomon_c_search_view_queries_total') >= 1, 'by name');
