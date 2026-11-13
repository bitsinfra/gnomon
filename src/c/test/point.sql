-- Point reads by primary key through routing views (the C read path): the planner hook
-- puts _gnomon.c_point in the view's place; every answer must equal the view's own.
create table acct (id int primary key, name text, bal int);
insert into acct select g, 'a' || g, 100 from generate_series(1, 100) g;
select gnomon.track('acct');
create table ck (a int, b int, v int, primary key (a, b));
insert into ck values (1, 1, 1);
select gnomon.track('ck');
create table tk (k text primary key, v int);
insert into tk values ('x', 1), ('y', 2);
select gnomon.track('tk');
select gnomon.coordinate_text() as c0 \gset

-- rows of a query run as a top-level statement (so the planner hook sees it)
create function pq(q text) returns jsonb language plpgsql as $$
declare r record; a jsonb := '[]';
begin
  for r in execute q loop a := a || jsonb_build_array(to_jsonb(r)); end loop;
  return a;
end $$;
-- how the read was answered: 1 none, 2 main's row, 3 the branch head, 4 the view, 5 main's row
-- rebuilt from its history (0: not rewritten)
create function pk(q text, kind int, msg text) returns void language plpgsql as $$
declare s0 int8[]; s1 int8[]; fast jsonb; slow jsonb; got int := 0;
begin
  perform set_config('gnomon.c_point_reads', 'on', false);
  s0 := _gnomon.c_point_stats();
  fast := pq(q);
  s1 := _gnomon.c_point_stats();
  for i in 1..5 loop if s1[i] > s0[i] then got := i; end if; end loop;
  perform set_config('gnomon.c_point_reads', 'off', false);
  slow := pq(q);
  perform set_config('gnomon.c_point_reads', 'on', false);
  perform t.eq(fast, slow, msg || ': same rows as the view');
  perform t.eq(got, kind, msg || ': answered by');
end $$;
create function plan_of(q text) returns text language plpgsql as $$
declare l text; r text := '';
begin
  for l in execute 'explain (costs off) ' || q loop r := r || l || E'\n'; end loop;
  return r;
end $$;

-- a branch, now
select gnomon.create_branch('f');
select gnomon.use('f');
update acct set name = 'branch' where id = 2;
delete from acct where id = 3;
select t.ok(plan_of('select * from acct where id = 2') like '%Custom Scan (GnomonPoint)%', 'planned as the custom scan');
select t.ok(plan_of('select name from acct where id = 2 and bal > 1') like '%Filter:%', 'other conditions filter the scan');
select t.ok((select string_agg(l, ' ') from (select plan_of('select name from acct where id = 2') l) x) is not null, 'explain');
do $$ declare l text; begin for l in explain (verbose, costs off) select name, bal from acct where id = 2 and name <> 'x' loop end loop; end $$;
select t.eq((select name from _gnomon.c_point('gnomon_r_public.acct'::regclass, 1::int2, 2) as x(id int, name text, bal int)),
            'branch', 'the function form, called directly');
select pk('select * from acct where id = 2', 3, 'branch head');
select pk('select * from acct where id = 3', 1, 'deleted on the branch');
select pk('select * from acct where id = 4', 2, 'untouched: main''s row');
select pk('select * from acct where id = 4000', 1, 'no such key');
select pk('select * from acct where id = null', 0, 'null key');
select pk('select name, bal * 2 as b2 from acct where 2 = id', 3, 'columns, expressions, key on the right');
select pk('select name from acct where id = 2 and bal > 50', 3, 'other conditions kept');
select pk('select name from acct where id = 2 and bal > 500', 3, 'other conditions filter');
select pk('select * from acct where id = 4 order by name limit 1', 2, 'order and limit');
select pk('select * from acct where name = ''a4''', 0, 'not by key');
select pk('select * from acct where id = 4 or id = 5', 0, 'not one key');
select pk('select * from acct where id = 4::int8', 0, 'cross-type key');
select pk('select a.* from acct a join acct b on b.id = a.id where a.id = 4', 0, 'joins keep the plan');
select pk('select * from ck where a = 1 and b = 1', 0, 'composite keys keep the plan');
-- main changed the key since the branch was made: history, through the view
select gnomon.use('main');
update acct set bal = 7 where id = 5;
update acct set bal = 8 where id = 6;
select gnomon.coordinate_text() as c1 \gset
select gnomon.use('f');
select pk('select * from acct where id = 5', 5, 'main changed since the cutoff');
select pk('select * from acct where id = 7', 2, 'main changed other keys');
-- the branch's own writes in the same transaction
begin;
update acct set bal = 1 where id = 8;
delete from acct where id = 9;
insert into acct values (1000, 'new', 0);
select pk('select bal from acct where id = 8', 3, 'own update');
select pk('select bal from acct where id = 9', 1, 'own delete');
select pk('select bal from acct where id = 1000', 3, 'own insert');
commit;

-- a child branch: keys its parent touched come from the parent's history (the view)
select gnomon.create_branch('g', 'f');
select gnomon.use('g');
update acct set name = 'child' where id = 10;
delete from acct where id = 11;
select pk('select * from acct where id = 10', 3, 'child head');
select pk('select * from acct where id = 11', 1, 'deleted on the child');
select pk('select * from acct where id = 2', 4, 'parent''s row');
select pk('select * from acct where id = 3', 4, 'deleted on the parent');
select pk('select * from acct where id = 12', 2, 'untouched on both');
select pk('select * from acct where id = 5', 5, 'main changed before the parent was made');

-- a key that many branches touched: more rows than one scan reads, so level by level
select gnomon.use('main');
do $$
begin
  for i in 1..70 loop
    perform gnomon.create_branch('many' || i, case when i = 70 then 'f' else 'main' end);
    perform gnomon.use('many' || i);
    execute format('update acct set bal = %s where id = 40', i);
  end loop;
  perform gnomon.use('main');
end $$;
select gnomon.create_branch('many_child', 'many70');
select gnomon.use('many_child');
select pk('select bal from acct where id = 40', 4, 'hot key: the parent''s row');
select pk('select bal from acct where id = 41', 2, 'hot table, cold key');
select gnomon.use('many5');
select pk('select bal from acct where id = 40', 3, 'hot key: the head');
select gnomon.use('f');
select pk('select bal from acct where id = 40', 2, 'hot key, untouched on this lineage');

-- the touched-key filter: untouched keys skip the touched-key scan; touched ones never do; without
-- its trigger it is not used; with the trigger back it rebuilds from the rows that are there
select gnomon.use('main');
create table ft (id int primary key, v int);
insert into ft select g, g from generate_series(1, 100) g;
select gnomon.track('ft');
select t.ok(exists (select 1 from pg_trigger where tgrelid = '_gnomon.ft__bk'::regclass and tgname = 'gnomon_c_filter'), 'track() attaches the filter');
select gnomon.create_branch('fb');
select gnomon.use('fb');
update ft set v = -1 where id = 1;
select gnomon.create_branch('fc', 'fb');
select gnomon.use('fc');
update ft set v = -2 where id = 2;
create function fs() returns int8[] language sql as $$ select (_gnomon.c_point_stats())[6:7] $$;
select fs() as f0 \gset
select pk('select * from ft where id = 1', 4, 'filter: touched on the parent');
select pk('select * from ft where id = 2', 3, 'filter: touched here');
select fs() as f1 \gset
select t.eq((:'f1'::int8[])[1] - (:'f0'::int8[])[1], 0::int8, 'touched keys are never skipped');
select pk('select * from ft where id = 3', 2, 'filter: untouched');
select pk('select * from ft where id = 4', 2, 'filter: untouched (again)');
select fs() as f2 \gset
select t.ok((:'f2'::int8[])[1] - (:'f1'::int8[])[1] >= 1, 'untouched keys skip the touched-key scan');
-- without the trigger, no filter (and a key touched meanwhile is not lost)
select gnomon.use('main');
drop trigger gnomon_c_filter on _gnomon.ft__bk;
select gnomon.use('fc');
update ft set v = -5 where id = 5;
select fs() as f3 \gset
select pk('select * from ft where id = 5', 3, 'no filter trigger: the touched key');
select pk('select * from ft where id = 6', 2, 'no filter trigger: untouched');
select fs() as f4 \gset
select t.eq((:'f4'::int8[])[1] - (:'f3'::int8[])[1], 0::int8, 'no filter without its trigger');
select gnomon.use('main');
select _gnomon.c_filter_attach(id) from gnomon.tracked where rel = 'ft'::regclass;
select gnomon.use('fc');
select pk('select * from ft where id = 5', 3, 'filter rebuilt: the key touched without the trigger');
select pk('select * from ft where id = 7', 2, 'filter rebuilt: untouched');
select pk('select * from ft where id = 1', 4, 'filter rebuilt: the parent''s key');
select fs() as f5 \gset
select t.ok((:'f5'::int8[])[1] - (:'f4'::int8[])[1] >= 1, 'the rebuilt filter is used');
set gnomon.c_touched_filter = off;
select pk('select * from ft where id = 8', 2, 'filter off: untouched');
reset gnomon.c_touched_filter;

-- main as of a coordinate
select gnomon.use('main', :'c1');
select pk('select * from acct where id = 5', 2, 'past read, key unchanged since');
select pk('select * from acct where id = 4', 2, 'past read, untouched');
select gnomon.use('main');
update acct set bal = 9 where id = 4;
select gnomon.use('main', :'c1');
select pk('select * from acct where id = 4', 5, 'past read, key changed since');
select pk('select * from acct where id = 5', 2, 'past read, other key changed');
-- main deleted or replaced a row after the cutoff; frozen rows keep their own xmin
select gnomon.use('main');
delete from acct where id = 30;
delete from acct where id = 31;
insert into acct values (31, 'again', 1);
insert into acct values (2000, 'later', 1);
vacuum (freeze) acct;
select gnomon.use('main', :'c1');
select pk('select * from acct where id = 30', 5, 'past read, deleted since');
select pk('select * from acct where id = 31', 5, 'past read, deleted and inserted again since');
select pk('select * from acct where id = 2000', 1, 'past read, inserted since (frozen now)');
select pk('select * from acct where id = 32', 2, 'past read, frozen and unchanged');
select gnomon.use('f');
select pk('select * from acct where id = 30', 5, 'branch, main deleted since the fork');
select pk('select * from acct where id = 2000', 1, 'branch, main inserted since the fork');
select pk('select * from acct where id = 32', 2, 'branch, frozen and unchanged');
-- the explicit routing view while reading main now
select gnomon.use('main');
select pk('select * from gnomon_r_public.acct where id = 4', 2, 'main now through the view');
-- before the table was tracked: the view's error
select gnomon.use('main', :'c0');
select pk('select * from acct where id = 4', 5, 'key changed since c0');
select pk('select * from acct where id = 20', 2, 'key unchanged since c0');
select gnomon.use('main');
create table late (id int primary key, v int);
insert into late values (1, 1);
select gnomon.track('late');
select gnomon.use('main', :'c1');
select t.fails('select * from late where id = 1', '22023', 'past read before tracking still fails');
select gnomon.use('f');
select pk('select * from late where id = 1', 4, 'branch made before the table was tracked');
-- a branch as of a coordinate
select gnomon.use('f', :'c1');
select pk('select * from acct where id = 2', 4, 'branch as of a coordinate');

-- variable-length keys are wide (an internal id): the planner keeps the view
select gnomon.use('f');
update tk set v = 10 where k = 'x';
select pk($$select * from tk where k = 'x'$$, 0, 'wide key, branch head');
select pk($$select * from tk where k = 'y'$$, 0, 'wide key, main''s row');

-- prepared statements: a generic plan follows the branch it runs on
select gnomon.use('f');
set plan_cache_mode = force_generic_plan;
prepare p(int) as select name from acct where id = $1;
execute p(2) \gset pr_
select t.eq(:'pr_name'::text, 'branch', 'prepared: branch f');
select gnomon.use('g');
execute p(2) \gset pr_
select t.eq(:'pr_name'::text, 'branch', 'prepared: child g reads the parent''s row');
execute p(10) \gset pr_
select t.eq(:'pr_name'::text, 'child', 'prepared: child head');
-- the views are regenerated by DDL: the plan is rebuilt, not run against a dropped view
-- (DDL on main: from a branch session plain DDL is refused)
select gnomon.use('main');
alter table acct add column extra int;
select gnomon.use('g');
execute p(10) \gset pr_
select t.eq(:'pr_name'::text, 'child', 'prepared after DDL');
reset plan_cache_mode;
deallocate p;
select pk('select * from acct where id = 10', 3, 'after DDL: new column');

-- scratch branches: their own views
select gnomon.create_scratch('s', 'f') as sb \gset
select gnomon.use(:'sb');
update acct set name = 'scratch' where id = 12;
select pk('select name from acct where id = 12', 3, 'scratch head');
select pk('select name from acct where id = 2', 4, 'scratch: parent''s row');
select pk('select name from acct where id = 13', 2, 'scratch: main''s row');
select t.fails('select name from gnomon_r_public.acct where id = 12', null, 'a logged view refuses a scratch branch');

-- privileges: the function checks SELECT on the view
drop role if exists pt_reader;
drop role if exists pt_none;
create role pt_reader;
create role pt_none;
select gnomon.use('main');
grant select on public.acct to pt_reader;
grant usage on schema gnomon, gnomon_r_public to pt_reader, pt_none;
select gnomon.use('f');
set role pt_reader;
select t.eq((select name from acct where id = 2), 'branch', 'a granted role reads through the fast path');
reset role;
set role pt_none;
select t.fails('select name from gnomon_r_public.acct where id = 2', '42501', 'no grant: denied');
select t.fails(format('select * from _gnomon.c_point(%s, 1::int2, 2) as x(id int, name text, bal int, extra int)',
                      'gnomon_r_public.acct'::regclass::oid), '42501', 'the function checks the view');
reset role;

-- a view defined on a branch stores the query as written, never the point read's function
select gnomon.use('f');
create view public.pt_v as select name from acct where id = 2;
select t.ok(pg_get_viewdef('public.pt_v'::regclass) not like '%c_point%', 'CREATE VIEW keeps the routing view');
select pk('select name from public.pt_v', 0, 'a view over the routing view keeps its plan');
drop view public.pt_v;

-- a branch TRUNCATE: the view (cleared levels)
select gnomon.create_branch('tr', 'f');
select gnomon.use('tr');
select gnomon.truncate('acct');
select pk('select * from acct where id = 4', 4, 'after a branch truncate');
insert into acct values (5000, 'post', 1);
select pk('select * from acct where id = 5000', 3, 'a head written after the truncate');
select gnomon.use('f');
select pk('select * from acct where id = 4', 4, 'any truncate sends reads to the view');
select gnomon.use('main');
-- main's rows rebuilt from history in C, against the view: cumulative deltas over a lazy baseline,
-- nulls, keyframes, carry-forward into later partitions and into the default partition, deletes,
-- a column added since (its default), a value kept in the blob store (the view answers that)
select gnomon.use('main');
create table hr (id int primary key, a int, b text, c int, d text);
insert into hr select g, g, 'b' || g, g * 10, 'd' || g from generate_series(1, 20) g;
select gnomon.track('hr', part_span => greatest(100, pg_current_xact_id()::text::int8 / 500000 + 1));   -- small partitions, and large enough that a long-lived cluster's xids stay under the 999999 cap
-- the burns below are shares of the span, so they cross partitions whatever the span is
select (part_span * 5 / 2)::int as burn_past, (part_span * 6 / 5)::int as burn_one
  from gnomon.tracked where rel = 'hr'::regclass \gset
select gnomon.heartbeat() is not null;
create procedure burn(n int) language plpgsql as $$ begin for i in 1..n loop perform pg_current_xact_id(); commit; end loop; end $$;
update hr set a = -1 where id = 1;
update hr set b = 'x' where id = 1;
update hr set c = null where id = 1;
select gnomon.coordinate_text() as h1 \gset
update hr set a = -2 where id = 1;
call burn(:burn_past);               -- past the partitions made so far: the default partition
update hr set d = 'default' where id = 1;
update hr set a = -3, b = 'y', c = 3 where id = 2;
select gnomon.heartbeat() is not null;
call burn(:burn_one);
select gnomon.heartbeat() is not null;
update hr set d = 'later' where id = 1;
select gnomon.coordinate_text() as h2 \gset
update hr set a = -4 where id = 1;
update hr set c = 99 where id = 2;
delete from hr where id = 3;
update hr set d = (select string_agg(md5(g::text), '') from generate_series(1, 3000) g) where id = 5;
select gnomon.coordinate_text() as h3 \gset
update hr set d = 'small' where id = 5;
alter table hr add column e int default 7;
update hr set e = 8 where id = 1;
select t.ok((select count(distinct tableoid) from _gnomon.hr__v) >= 3, 'versions in several partitions and the default one');
select gnomon.use('main', :'h1');
select pk('select * from hr where id = 1', 5, 'rebuilt: deltas over the baseline, a null, a column added since');
select pk('select * from hr where id = 2', 5, 'rebuilt: the baseline');
select pk('select * from hr where id = 3', 5, 'rebuilt: deleted since');
select pk('select * from hr where id = 4', 2, 'unchanged');
select gnomon.use('main', :'h2');
select pk('select * from hr where id = 1', 5, 'rebuilt: a delta over a carried-forward keyframe');
select pk('select * from hr where id = 2', 5, 'rebuilt: a keyframe');
select pk('select * from hr where id = 3', 5, 'rebuilt: deleted since, from a later partition');
select gnomon.use('main', :'h3');
select pk('select * from hr where id = 3', 1, 'deleted before the cutoff');
select pk('select * from hr where id = 5', 4, 'a value in the blob store: the view');
select pk('select a, e from hr where id = 1', 5, 'rebuilt: some columns');
select gnomon.create_branch('hb', 'main', at => :'h2');
select gnomon.use('hb');
select pk('select * from hr where id = 1', 5, 'a branch from the past: main rebuilt at its fork');
select pk('select * from hr where id = 6', 2, 'a branch from the past: unchanged');
select gnomon.use('main');

-- the extension dropped and created again in this session: the rewrite finds the new function
select gnomon.use('main');
drop extension gnomon_c cascade;
create extension gnomon_c;
select gnomon.use('f');
select pk('select * from acct where id = 4', 4, 'after gnomon_c was created again');
select gnomon.use('main');
drop owned by pt_reader, pt_none;
drop role pt_reader;
drop role pt_none;
