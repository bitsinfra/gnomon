-- The branch DML matrix, executable. SQL-only expectations; with the C module
-- loaded (gnomon.c_module = on) the gap rows are expected to work instead.
create table m (id int primary key, v text, n int default 0);
create table m2 (id int primary key, m_id int references m(id), w int);
insert into m select g, 'v' || g, g from generate_series(1, 10) g;
insert into m2 select g, g, g * 2 from generate_series(1, 10) g;
select gnomon.track('m'); select gnomon.track('m2');
select gnomon.create_branch('dml');
select gnomon.use('dml');
select coalesce(current_setting('gnomon.c_module', true), '') = 'on' as cmod \gset

-- SELECT, joins, CTEs, window functions, prepared statements: work
select t.eq((select count(*) from m join m2 on m2.m_id = m.id), 10::bigint, 'join');
select t.eq((with c as (select id, sum(n) over (order by id) s from m) select max(s) from c), 55::bigint, 'CTE + window');
prepare p(int) as select v from m where id = $1;
update m set v = 'branch' where id = 1;
select t.eq((select v from m where id = 1), 'branch', 'read after write on the branch');
-- INSERT, UPDATE, DELETE, RETURNING, COPY FROM: work
insert into m values (11, 'new');
with d as (delete from m where id = 11 returning id) select t.eq(count(*), 1::bigint, 'DELETE ... RETURNING') from d;
copy m(id, v) from program 'printf "12\ttwelve\n"';
select t.eq((select v from m where id = 12), 'twelve', 'COPY FROM');
-- MERGE: works on PG17+
select current_setting('server_version_num')::int >= 170000 as pg17 \gset
\if :pg17
merge into m using (values (1, 'merged'), (13, 'thirteen')) s(id, v) on m.id = s.id
  when matched then update set v = s.v when not matched then insert (id, v) values (s.id, s.v);
select t.eq((select v from m where id = 13), 'thirteen', 'MERGE insert arm');
select t.eq((select v from m where id = 1), 'merged', 'MERGE update arm');
\endif

\if :cmod
insert into m values (1, 'dup') on conflict (id) do update set v = excluded.v;
select t.eq((select v from m where id = 1), 'dup', 'C module: ON CONFLICT (cols) DO UPDATE');
insert into m values (1, 'ignored') on conflict do nothing;
select t.eq((select v from m where id = 1), 'dup', 'C module: ON CONFLICT DO NOTHING');
truncate m2;
select t.eq((select count(*) from m2), 0::bigint, 'C module: TRUNCATE rewritten');
select t.eq((select v from public.m where id = 1), 'dup', 'C module: schema-qualified names are redirected');
\else
-- ON CONFLICT DO NOTHING without a target: accepted, but there is no conflict check
select t.fails($$insert into m values (2, 'dup') on conflict do nothing$$, '23505', 'SQL-only: ON CONFLICT DO NOTHING still raises on a duplicate');
insert into m values (14, 'fourteen') on conflict do nothing;
select t.eq((select v from m where id = 14), 'fourteen', 'SQL-only: ON CONFLICT DO NOTHING inserts new rows');
-- ON CONFLICT (cols): an error
select t.fails($$insert into m values (2, 'x') on conflict (id) do update set v = excluded.v$$, '42P10', 'SQL-only: ON CONFLICT (cols) errors');
-- TRUNCATE: refused, gnomon.truncate() instead
select t.fails('truncate m2', null, 'SQL-only: TRUNCATE on a routing view fails');
-- schema-qualified names read main and writes to tracked tables are refused (no grants are needed for that to hold)
select t.eq((select v from public.m where id = 1), 'v1', 'SQL-only: schema-qualified reads see main');
select t.fails($$update public.m set v = 'via qualified name' where id = 1$$, '25006', 'SQL-only: a schema-qualified write to a tracked table is refused on a branch');
select t.fails($$insert into public.m values (999, 'q')$$, '25006', 'SQL-only: a schema-qualified insert is refused on a branch');
-- FOR UPDATE returns rows (the missing lock is checked in test/shell/dml_locks.sh)
select t.eq((select count(*) from (select * from m where id in (2, 3) for update) x), 2::bigint, 'SQL-only: FOR UPDATE returns rows');
\endif

-- DDL on a branch is out of scope: it changes main's table
select gnomon.use('main');
select t.eq((select v from m where id = 1), 'v1', 'main untouched by all of the above');

-- PostgREST pre-request: a header picks the branch for the request's transaction
begin;
select set_config('request.headers', '{"x-gnomon-branch": "dml"}', true);
select gnomon.postgrest_pre_request();
select t.eq(current_setting('gnomon.branch'), 'dml', 'pre-request sets the branch from the header');
select t.eq((select v from gnomon_r_public.m where id = 1), case when :'cmod' then 'dup' when :'pg17' then 'merged' else 'branch' end, 'request reads the branch through its profile');
commit;
select t.eq(coalesce(current_setting('gnomon.branch', true), ''), '', 'the branch lasts one transaction (transaction pooling safe)');
select t.ok(gnomon.postgrest_config() like '%db-pre-request%', 'postgrest config helper');
