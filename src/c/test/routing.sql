-- C module: transparent routing, branch DML, read-set tracking, C versioning trigger.
select t.eq(current_setting('gnomon.c_module'), 'on', 'module loaded');
create table acct (id int primary key, owner text not null, bal int not null default 0);
create table plain_t (id int primary key, v int);
insert into acct select g, 'o' || g, 100 from generate_series(1, 10) g;
insert into plain_t values (1, 1);
select gnomon.track('acct');
select gnomon.create_branch('f');

-- SET gnomon.branch alone routes; schema-qualified names too
set gnomon.branch = 'f';
update public.acct set bal = 1 where id = 1;
update acct set bal = 2 where id = 2;
select t.eq((select bal from public.acct where id = 1), 1, 'qualified write and read on the branch');
select t.eq((select bal from acct where id = 2), 2, 'unqualified write and read on the branch');
select t.eq((select count(*) from acct a join public.acct b using (id)), 10::bigint, 'joins route both sides');
select t.eq((select bal from (select * from public.acct) s where id = 1), 1, 'subqueries route');
select t.fails('insert into public.plain_t values (2, 2)', '42501', 'untracked tables refuse branch writes');
-- a branch reads through a view, which has no system columns: refused by name, not routed blind
select t.fails('select xmin from public.acct where id = 1', '0A000', 'a system column on a branch is refused');
select t.fails('select count(*) from acct a where exists (select 1 where a.ctid is not null)', '0A000', 'also from a sublink');
select t.fails('insert into acct values (40, ''x'', 1) returning tableoid', '0A000', 'also in RETURNING');
select t.eq((select to_jsonb(a) ->> 'bal' from public.acct a where id = 1), '1', 'whole-row reads route');
reset gnomon.branch;
select t.ok((select xmin is not null from public.acct where id = 1), 'main keeps its system columns');
select t.eq((select bal from acct where id = 1), 100, 'main unaffected');

-- COPY routes too: COPY FROM writes the branch, COPY TO reads it, untracked tables refuse COPY FROM
set gnomon.branch = 'f';
copy acct (id, owner, bal) from stdin;
30	copied	3
\.
select t.eq((select bal from acct where id = 30), 3, 'COPY FROM writes the branch');
copy public.acct to program 'cat > gn_copy_test.copy';   -- (in the data directory)
copy acct (id, bal) to program 'cat > gn_copy_test2.copy';
select t.fails($$copy plain_t from program 'echo 5	5'$$, null, 'COPY FROM into an untracked table is refused on a branch');
reset gnomon.branch;
select t.ok(not exists (select 1 from acct where id = 30), 'COPY FROM left main alone');
create temp table copied (like acct);
copy copied from 'gn_copy_test.copy';
select t.eq((select bal from copied where id = 1), 1, 'COPY TO read the branch');
select t.eq((select count(*) from copied where id = 30), 1::bigint, 'COPY TO read the branch''s inserts');
create temp table copied2 (id int, bal int);
copy copied2 from 'gn_copy_test2.copy';
select t.eq((select bal from copied2 where id = 1), 1, 'COPY TO with a column list');
copy (select 1) to program 'rm -f gn_copy_test.copy gn_copy_test2.copy';

-- a scratch branch routes through the scratch schema (its unlogged tables), qualified names too
select gnomon.create_branch('sc', kind => 'scratch');
set gnomon.branch = 'sc';
update public.acct set bal = 9 where id = 1;
insert into acct values (20, 'scratch row', 1);
select t.eq((select bal from public.acct where id = 1), 9, 'scratch branch: qualified write and read');
select t.eq((select count(*) from acct where id = 20), 1::bigint, 'scratch branch: unqualified insert and read');
reset gnomon.branch;
select t.eq((select count(*) from _gnomon.acct__b_u), 2::bigint, 'scratch writes land in the unlogged tables');
select t.eq((select count(*) from _gnomon.acct__b where gn_branch = (select id from gnomon.branch where name = 'sc')), 0::bigint,
            'and not in the logged ones');
set gnomon.branch = 'f';
select t.eq((select bal from acct where id = 1), 1, 'switching back to a logged branch in the same session');
reset gnomon.branch;

-- as_of alone routes reads to the past
select gnomon.coordinate_text() as c0 \gset
update acct set bal = 7 where id = 3;
select set_config('gnomon.as_of', :'c0', false);
select t.eq((select bal from public.acct where id = 3), 100, 'gnomon.as_of alone reads the past');
reset gnomon.as_of;

-- ON CONFLICT on a branch
set gnomon.branch = 'f';
insert into acct values (1, 'x', 50) on conflict (id) do update set bal = excluded.bal;
select t.eq((select bal from acct where id = 1), 50, 'ON CONFLICT DO UPDATE on a branch');
insert into acct values (1, 'y', 60) on conflict do nothing;
select t.eq((select bal from acct where id = 1), 50, 'ON CONFLICT DO NOTHING on a branch');
insert into acct values (11, 'n', 11) on conflict (id) do update set bal = excluded.bal;
select t.eq((select bal from acct where id = 11), 11, 'ON CONFLICT inserts new rows');
prepare up(int, int) as insert into acct values ($1, 'p', $2) on conflict (id) do update set bal = excluded.bal;
execute up(4, 44); execute up(4, 45);
select t.eq((select bal from acct where id = 4), 45, 'prepared upsert on a branch, twice');
select t.eq(coalesce(current_setting('gnomon._upsert', true), ''), '', 'upsert spec cleared after the statement');
insert into acct values (12, 'q', 5);
select t.fails($$insert into acct values (5, 'dup', 6)$$, '23505', 'plain duplicate insert still fails');

-- TRUNCATE on a branch
reset gnomon.branch;
create table tr (id int primary key);
insert into tr values (1), (2);
select gnomon.track('tr');
set gnomon.branch = 'f';
truncate tr;
select t.eq((select count(*) from tr), 0::bigint, 'TRUNCATE rewritten to gnomon.truncate on a branch');
reset gnomon.branch;
select t.eq((select count(*) from tr), 2::bigint, 'main unaffected by branch TRUNCATE');

-- FOR UPDATE copies up and locks (the blocking behaviour is tested in locks.sh)
set gnomon.branch = 'f';
select t.eq((select count(*) from (select * from acct where id in (6, 7) for update) x), 2::bigint, 'FOR UPDATE returns rows');
select t.eq((select count(*) from _gnomon.acct__bk where id in (6, 7)), 2::bigint, 'FOR UPDATE took the branch row locks');
reset gnomon.branch;

-- read-set tracking and stale-read detection
select gnomon.create_branch('reader');
set gnomon.branch = 'reader';
set gnomon.track_reads = on;
select owner from acct where id = 8;
reset gnomon.track_reads;
update acct set bal = 999 where id = 9;     -- a write, so the branch has something to merge
reset gnomon.branch;
update acct set owner = 'changed on main' where id = 8;
select t.ok(exists (select 1 from gnomon.stale_reads('reader') where key = '{"id": 8}'), 'stale read detected');
select gnomon.merge('reader') as m \gset
select t.eq((select (stats ->> 'stale_reads')::int from gnomon.merge where id = :m), 1, 'merge reports the stale read');
select t.ok(not exists (select 1 from _gnomon.read_set rs join gnomon.branch b on b.id = rs.branch where b.name = 'reader'), 'a merged branch''s read set is cleared');
-- a read, then a rebase, then main changing what was read before the rebase: still stale
select gnomon.create_branch('reader2');
select gnomon.track_reads('reader2');            -- per branch: gnomon.use() turns tracking on
select gnomon.use('reader2');
select t.eq(current_setting('gnomon.track_reads'), 'on', 'a tracking branch turns read tracking on');
select owner from acct where id = 4;
update acct set bal = 444 where id = 4;
select gnomon.use('main');
reset gnomon.track_reads;
update acct set owner = 'main moved' where id = 5;
select gnomon.use('reader2');
select owner from acct where id = 6;             -- read with the old cutoff
select gnomon.use('main');
select gnomon.rebase('reader2');
update acct set owner = 'changed after the rebase' where id = 3;
select t.ok(not exists (select 1 from gnomon.stale_reads('reader2') where key = '{"id": 6}'), 'an unchanged read is not stale');
update acct set owner = 'changed after the read' where id = 6;
select t.ok(exists (select 1 from gnomon.stale_reads('reader2') where key = '{"id": 6}'), 'a read before a rebase is still checked against what it saw');
-- a branch older than a table's tracking reads it as of the tracking point (main has no history
-- before it): its reads are checked against that point, and done() and merge() go through
create table late (id int primary key, v text);
insert into late values (1, 'a'), (2, 'b');
select gnomon.create_branch('early');
select gnomon.track('late');
set gnomon.branch = 'early';
set gnomon.track_reads = on;
select v from late where id in (1, 2);
reset gnomon.track_reads;
insert into late values (3, 'from the branch');
reset gnomon.branch;
select t.eq((select count(*) from _gnomon.read_set rs join gnomon.branch b on b.id = rs.branch where b.name = 'early'), 2::bigint, 'reads of a table tracked after the branch are recorded');
select t.ok(not exists (select 1 from gnomon.stale_reads('early')), 'reads of a table tracked after the branch: none stale while main is unchanged');
update late set v = 'changed on main' where id = 2;
select t.ok((select array_agg(key) from gnomon.stale_reads('early')) = array['{"id": 2}'::jsonb], 'reads of a table tracked after the branch: a changed row is stale');
select gnomon.merge('early') as m \gset
select t.eq((select (stats ->> 'stale_reads')::int from gnomon.merge where id = :m), 1, 'a branch older than a table''s tracking merges, reporting its stale read');

-- the C versioning trigger writes the same history as the PL/pgSQL one
create table ct (id int primary key, a int, b text, c jsonb, big text);
insert into ct select g, g, 'b' || g, jsonb_build_object('g', g), null from generate_series(1, 20) g;
select gnomon.track('ct');
select gnomon.use_c_trigger('ct');
select t.ok((select tgfoid = '_gnomon.c_version_trigger'::regproc from pg_trigger where tgrelid = 'ct'::regclass and tgname = 'gnomon_v'), 'C trigger attached');
create table t.cs (step int, coord text, rows jsonb);
create procedure t.cwork(n int) language plpgsql as $$
begin
  for i in 1..n loop
    case i % 4
      when 0 then delete from ct where id = 1 + (i * 7) % 25;
      when 1 then insert into ct values (1 + (i * 7) % 25, i, 'n', '{}', null) on conflict (id) do update set a = ct.a + 1;
      when 2 then update ct set b = b || '.', big = (select string_agg(md5(g::text || i), '') from generate_series(1, 300) g) where id = 1 + (i * 3) % 20;
      else update ct set a = a + 1, b = 'z', c = '{"z": 1}' where id % 4 = i % 4;
    end case;
    commit;
    insert into t.cs select i, gnomon.coordinate_text(), (select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]') from ct x);
    commit;
  end loop;
end $$;
call t.cwork(60);
do $$
declare s record; got jsonb;
begin
  for s in select * from t.cs order by step loop
    perform set_config('gnomon.as_of', s.coord, false);
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]') into got from ct x;
    perform t.eq(got, s.rows, format('C trigger replay at step %s', s.step));
  end loop;
  perform set_config('gnomon.as_of', '', false);
end $$;
select t.ok((select count(*) from _gnomon.blob) > 0, 'C trigger stores large values in the blob store');
select t.ok((select count(*) from _gnomon.ct__v where gn_flags & 2 <> 0 and gn_flags & 8 = 0) > 0, 'C trigger writes deltas');
select gnomon.use_c_trigger('ct', false);
