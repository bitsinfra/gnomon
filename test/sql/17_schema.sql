-- Schema changes on a branch: additions. A column, a table, an index and a comment
-- made on a branch are seen there (and on its children) only; plain DDL from a branch session is
-- refused; what a branch cannot change is refused by name; the merge brings the DDL and the values
-- to main and closes the version; a column main added since with another type is a conflict.
create table acct (id int primary key, owner text not null, bal int not null default 0);
create table item (id int primary key, acct_id int not null references acct(id), qty int);
insert into acct select g, 'o' || g, g * 10 from generate_series(1, 20) g;
insert into item select g, (g % 20) + 1, g from generate_series(1, 40) g;
select gnomon.track('acct');
select gnomon.track('item');
create view acct_names as select id, owner from acct;
select gnomon.create_branch('feat');
select gnomon.create_branch('other');

select gnomon.use('feat');
-- (with the C module plain DDL goes to gnomon.ddl instead: src/c/test/ddl_search.sql)
select coalesce(current_setting('gnomon.c_module', true), '') = 'on' as cmod17 \gset
\if :cmod17
\else
select t.fails($$alter table acct add column tier text$$, '0A000', 'plain DDL on a branch session is refused');
\endif
select t.eq(gnomon.ddl($$alter table acct add column tier text not null default 'basic'$$) #>> '{changes,0,op}', 'add_column', 'an added column is recorded');
select t.ok(current_setting('search_path') like '%gnomon_r_public__v%', 'the session reads the version''s views');
select t.ok(gnomon.connection_options('feat') like '%gnomon_r_public__v%', 'connection options name them');
select t.eq((select count(*) from acct where tier = 'basic'), 20::bigint, 'every row reads the default');
update acct set tier = 'gold' where id <= 3;
insert into acct (id, owner, tier) values (21, 'o21', 'silver');
insert into acct (id, owner) values (22, 'o22');
select t.eq((select string_agg(tier, ',' order by id) from acct where id in (1, 2, 3, 4, 21, 22)), 'gold,gold,gold,basic,silver,basic', 'writes of the column');
update acct set bal = bal + 1 where id = 1;
select t.eq((select tier from acct where id = 1), 'gold', 'a write of other columns keeps the value');
select t.eq((select bal from acct where id = 1), 11, 'and writes them');
select t.fails($$update acct set tier = null where id = 2$$, '23502', 'NOT NULL holds for the column');
select gnomon.ddl($$alter table acct add column grade text default 'a'$$);
update acct set grade = null where id = 5;
select t.ok((select grade is null from acct where id = 5), 'an explicit null is kept, not the default');
select t.eq((select grade from acct where id = 6), 'a', 'next to the default');
select t.eq((select count(*) from acct_names), 22::bigint, 'untracked relations pass through');
select t.eq((select count(*) from item i join acct a on a.id = i.acct_id where a.tier = 'gold'), 6::bigint, 'joins through the version');
select t.eq((select tier from acct a where a.id = (select acct_id from item where id = 2)), 'gold', 'keyed reads');
select t.fails($$select tier from gnomon_r_public.acct$$, '42703', 'the plain routing view is unchanged');
-- the rest of the DML matrix through the version's view: delete, key change, re-insert, RETURNING
insert into acct (id, owner, tier) values (30, 'o30', 'temp');
delete from acct where id = 30;
select t.eq((select count(*) from acct where id = 30), 0::bigint, 'a delete through the version view');
insert into acct (id, owner) values (30, 'o30 again');
select t.eq((select tier from acct where id = 30), 'basic', 'a re-insert reads its own value, not the deleted row''s');
update acct set id = 31, tier = 'moved' where id = 30;
select t.eq((select tier from acct where id = 31), 'moved', 'a key change carries the value');
select t.eq((select count(*) from acct where id = 30), 0::bigint, 'and leaves no row behind');
update acct set tier = 'ret' where id = 31 returning tier || '/' || owner as ret \gset
select t.eq(:'ret'::text, 'ret/o30 again', 'RETURNING the new column');
insert into acct (id, owner) values (32, 'o32') returning id || ':' || tier as ret2 \gset
select t.eq(:'ret2'::text, '32:basic', 'RETURNING defaults');
delete from acct where id in (31, 32);
select t.fails($$insert into acct (id, owner) values (1, 'dup')$$, '23505', 'the key stays unique through the version view');

-- a sibling and main do not see it
select gnomon.use('other');
select t.fails($$select tier from acct$$, '42703', 'a sibling does not see the column');
select gnomon.use('main');
select t.fails($$select tier from acct$$, '42703', 'main does not see the column');
select t.eq((select count(*) from acct), 20::bigint, 'nor the rows');

-- a table, an index, a comment, a column of the new table
select gnomon.use('feat');
select t.eq(gnomon.ddl($$create table note (id int primary key, acct_id int references acct(id), body text)$$) #>> '{changes,0,op}', 'create_table', 'a new table');
insert into note values (1, 1, 'hello'), (2, 21, 'new acct');
select t.eq((select count(*) from note), 2::bigint, 'the new table holds the branch''s rows');
select t.eq((select body from note n join acct a on a.id = n.acct_id where a.tier = 'silver'), 'new acct', 'and joins');
select t.eq(gnomon.ddl($$create index on acct (tier)$$) #>> '{changes,0,op}', 'create_index', 'an index is recorded');
select t.eq(gnomon.ddl($$comment on column acct.tier is 'membership tier'$$) #>> '{changes,0,op}', 'comment', 'a comment');
select t.eq(gnomon.ddl($$alter table note add column pinned bool not null default false$$) #>> '{changes,0,op}', 'add_column', 'a column on the new table');
select t.eq((select count(*) from note where not pinned), 2::bigint, 'its rows read the default');
update note set pinned = true where id = 1;
select gnomon.use('main');
select t.ok(to_regclass('public.note') is null, 'main has no table note');
select gnomon.use('other');
select t.fails($$select * from note$$, '42P01', 'nor a sibling');

-- what a branch still refuses, by name (constraints, renames, drops and type changes are in 19_schema_changes)
select gnomon.use('feat');
select t.fails($$select gnomon.ddl('alter table acct drop column id')$$, '0A000', 'dropping a key column');
select t.fails($$select gnomon.ddl('alter table acct rename column id to acct_id')$$, '0A000', 'renaming a key column');
select t.fails($$select gnomon.ddl('alter table acct alter column id type bigint')$$, '0A000', 'retyping a key column');
select t.fails($$select gnomon.ddl('alter table acct drop column owner')$$, '0A000', 'dropping main''s NOT NULL column without a default');
select t.fails($$select gnomon.ddl('alter table acct alter column bal drop not null')$$, '0A000', 'relaxing main''s NOT NULL');
select t.fails($$select gnomon.ddl('alter table acct add column at timestamptz default now()')$$, '0A000', 'a volatile default');
select t.fails($$select gnomon.ddl('alter table acct add column n int not null')$$, '0A000', 'not null without a default');
select t.fails($$select gnomon.ddl('alter table acct add constraint neg check (bal < 0)')$$, '23514', 'a check the branch''s rows break');
select t.fails($$select gnomon.ddl('alter table acct add constraint ex exclude using btree (owner with =)')$$, '0A000', 'an exclusion constraint');
select t.fails($$select gnomon.ddl('create table nokey (a int)')$$, '0A000', 'a table without a key');
select t.fails($$select gnomon.ddl('drop table acct')$$, '2BP01', 'a table another table references');
select t.fails($$select gnomon.ddl('alter table public.acct add column x int')$$, '42501', 'a qualified name reaching main');
select t.fails($$select gnomon.ddl('select 1')$$, '0A000', 'a statement that changes nothing');
select t.eq((select count(*) from gnomon.schema_changes('feat')), 6::bigint, 'six changes recorded');
select t.ok(not exists (select 1 from pg_namespace where nspname like 'gnomon\_shadow\_%'), 'no shadow is left behind');
select t.eq((select count(*) from gnomon.schema_diff('feat')), 12::bigint, 'the values set on the branch');

-- a child stands on its parent's version; merged into the parent, its values come along
select gnomon.create_branch('feat/child', 'feat');
select gnomon.use('feat/child');
select t.eq((select tier from acct where id = 1), 'gold', 'a child sees its parent''s column and values');
update acct set tier = 'platinum' where id = 4;
select gnomon.use('feat');
select t.eq((select tier from acct where id = 4), 'basic', 'the child''s value stays on the child');
select gnomon.use('main');
select t.fails($$select gnomon.merge('feat/child', 'main')$$, '0A000', 'a child of the version cannot reach main before its owner');
select t.fails($$select gnomon.merge('feat', 'other')$$, '0A000', 'a versioned branch merges into main only');
select gnomon.merge('feat/child', 'feat');
select gnomon.use('feat');
select t.eq((select tier from acct where id = 4), 'platinum', 'the child''s values came along');

-- a non-superuser runs DDL on its branch with its own privileges
select gnomon.use('main');
drop role if exists gt_sdev;
create role gt_sdev;
grant select, insert, update, delete on acct, item to gt_sdev;
set role gt_sdev;
select gnomon.create_branch('sd');
select gnomon.use('sd');
select t.eq(gnomon.ddl($$alter table acct add column z int$$) #>> '{changes,0,column}', 'z', 'a role that does not own the table');
select t.fails($$select gnomon.ddl('alter table acct add column y int; create role gt_evil superuser')$$, '42501', 'nothing past its own privileges');
select gnomon.use('main');
reset role;
select gnomon.drop_branch('sd');
select t.ok(not exists (select 1 from pg_namespace where nspname like 'gnomon\_r\_public\_\_v' || (select max(id) from gnomon.schema_version)), 'a dropped branch takes its version''s views');
select t.eq((select status from gnomon.schema_version order by id desc limit 1), 'dropped', 'and closes it');

-- a dropped branch takes its new table with it, and the tables it referenced still write
-- (from a new session: compiled functions would otherwise hide a stale name)
select gnomon.create_branch('gone');
select gnomon.use('gone');
select gnomon.ddl($$create table scrap (id int primary key, acct_id int references acct(id))$$);
insert into scrap values (1, 3);
select gnomon.use('main');
select gnomon.drop_branch('gone');
\c
select gnomon.create_branch('after-drop');
select gnomon.use('after-drop');
update acct set owner = 'still writes' where id = 3;
select t.fails('delete from acct where id = 5', '23503', 'and still check foreign keys');
select t.eq((select owner from acct where id = 3), 'still writes', 'tables a dropped version referenced still write');
select gnomon.use('main');
select gnomon.drop_branch('after-drop');

-- the merge: DDL, values and rows reach main; the version is closed. An index on a large table
-- is left for CREATE INDEX CONCURRENTLY after it (every table counts as large here)
select gnomon.set('ddl_concurrent_rows', '0');
select gnomon.merge('feat') as mf \gset
select t.ok(not exists (select 1 from pg_indexes where tablename = 'acct' and indexdef like '%(tier)%'), 'the index is not built in the merge');
select t.ok((select stats -> 'indexes_to_build' ->> 0 from gnomon.merge where id = :mf) like 'CREATE INDEX CONCURRENTLY IF NOT EXISTS % ON public.acct %', 'the merge lists it to build concurrently');
select x from jsonb_array_elements_text((select stats -> 'indexes_to_build' from gnomon.merge where id = :mf)) x \gexec
select gnomon.set('ddl_concurrent_rows', '1000000');
select t.eq((select status from gnomon.merge where id = :mf), 'applied', 'the merge applied');
select t.eq((select string_agg(coalesce(tier, '-'), ',' order by id) from acct where id in (1, 2, 3, 4, 21, 22)), 'gold,gold,gold,platinum,silver,basic', 'main has the values');
select t.ok((select grade is null from acct where id = 5) and (select grade from acct where id = 6) = 'a', 'the explicit null and the default');
select t.eq((select count(*) from acct where tier = 'basic'), 17::bigint, 'and the default elsewhere');
select t.eq((select bal from acct where id = 1), 11, 'and the branch''s other writes');
select t.eq((select count(*) from note), 2::bigint, 'the new table is on main with its rows');
select t.ok((select pinned from note where id = 1), 'with its column');
select t.ok(to_regclass('public.note') is not null, 'in the user schema');
select t.ok(exists (select 1 from gnomon.tracked where nsp = 'public' and relname = 'note'), 'tracked there');
select t.ok(exists (select 1 from pg_indexes where tablename = 'acct' and indexdef like '%(tier)%'), 'the index was built');
select t.eq(col_description('acct'::regclass, (select attnum from pg_attribute where attrelid = 'acct'::regclass and attname = 'tier')::int), 'membership tier', 'the comment');
select t.eq((select status from gnomon.schema_version where created_on_branch = (select id from gnomon.branch where name = 'feat')), 'merged', 'the version is closed');
select t.ok(not exists (select 1 from pg_namespace where nspname like 'gnomon\_r\_public\_\_v%' or nspname like 'gnomon\_sv%' or nspname like 'gnomon\_r\_gnomon\_sv%'), 'its schemas are gone');
select t.ok((select schema_version is null from gnomon.branch where name = 'feat'), 'the branch stands on main''s shape');
select t.eq((select count(*) from _gnomon.branch_column), 0::bigint, 'the side values are gone');
\c
select gnomon.create_branch('after-merge');
select gnomon.use('after-merge');
update acct set owner = 'after' where id = 1;
insert into note values (3, 1, 'on a branch after the merge');
delete from note where id = 3;
select t.eq((select owner from acct where id = 1), 'after', 'a new session writes the merged tables on a branch');
select gnomon.use('main');
select gnomon.drop_branch('after-merge');
select gnomon.use('feat');
select t.eq((select tier from acct where id = 21), 'silver', 'the branch reads the real column');
select gnomon.use('other');
select t.eq((select count(*) from acct), 20::bigint, 'a sibling reads main''s new shape');
select t.ok(to_regclass('public.note') is not null, 'and its new table');

-- a column main added since with another type is a schema conflict
select gnomon.use('main');
select gnomon.create_branch('c1');
select gnomon.use('c1');
select gnomon.ddl($$alter table acct add column region text$$);
update acct set region = 'eu' where id = 1;
select gnomon.use('main');
alter table acct add column region int;
select t.ok(exists (select 1 from gnomon.warning w join gnomon.branch b on b.id = w.branch
                     where b.name = 'c1' and w.kind = 'schema' and w.col = 'region' and w.detail ->> 'main' = 'integer'), 'main adding a clashing column warns the branch at once');
select gnomon.merge('c1') as mc \gset
select t.eq((select status from gnomon.merge where id = :mc), 'conflicts', 'another type is a schema conflict');
select t.eq((select kind from gnomon.conflict where merge_id = :mc), 'schema', 'of kind schema');
-- the same definition main added meanwhile is adopted: the branch still reads its values
select gnomon.use('main');
select gnomon.create_branch('c2');
select gnomon.use('c2');
select gnomon.ddl($$alter table acct add column zone text$$);
update acct set zone = 'north' where id = 1;
select gnomon.use('main');
alter table acct add column zone text;
update acct set zone = 'south' where id = 2;
select gnomon.use('c2');
select t.eq((select zone from acct where id = 1), 'north', 'the branch reads its value over main''s new column');
select gnomon.use('main');
select gnomon.merge('c2') as mc2 \gset
select t.eq((select status from gnomon.merge where id = :mc2), 'applied', 'the same definition is adopted');
select t.eq((select string_agg(coalesce(zone, '-'), ',' order by id) from acct where id <= 3), 'north,south,-', 'with the branch''s values and main''s');

-- an incremental merge commits the DDL and the values first, then the rows in batches
select gnomon.use('main');
select gnomon.create_branch('inc');
select gnomon.use('inc');
select gnomon.ddl($$alter table acct add column flag bool not null default false$$);
update acct set flag = true where id <= 4;
insert into acct (id, owner, flag) values (50, 'o50', true);
select gnomon.use('main');
call gnomon.merge_incremental('inc', batch => 2);
select t.eq((select count(*) from acct where flag), 5::bigint, 'an incremental merge brings the column and its values');
select t.eq((select status from gnomon.merge order by id desc limit 1), 'applied', 'and applies');

-- a serial key on a table the branch creates, an index on it, an identity key on main's table
-- after the branch's DDL, and the values of an added column in the diff
select gnomon.use('main');
create table seq_main (id bigint generated always as identity primary key, body text not null);
insert into seq_main (body) values ('m1'), ('m2'), ('m3');
select gnomon.track('seq_main');
select gnomon.create_branch('serials');
select gnomon.use('serials');
select gnomon.ddl($$create table tag (id serial primary key, name text not null)$$);
select gnomon.ddl($$create index on tag (name)$$);
select gnomon.ddl($$alter table seq_main add column pinned bool not null default false$$);
insert into tag (name) values ('a'), ('b');
select t.eq((select string_agg(id::text, ',' order by id) from tag), '1,2', 'a serial key draws on the branch');
insert into seq_main (body) values ('on the branch');
select t.eq((select count(*) from seq_main), 4::bigint, 'an identity key draws on a branch with a schema version');
update seq_main set pinned = true where id = 1;
update seq_main set body = 'both', pinned = true where id = 2;
select gnomon.use('main');
select t.eq((select count(*) from gnomon.diff('serials', null, array['seq_main'::regclass]) where col = 'pinned'), 2::bigint,
            'the diff shows the values in the added column');
select t.eq((select updates from gnomon.diff_summary('serials') where tbl = 'seq_main'::regclass), 2::bigint, 'and counts their rows');
select gnomon.merge('serials') as ms \gset
select t.eq((select status from gnomon.merge where id = :ms), 'applied', 'a new table with an index merges');
select t.ok(exists (select 1 from pg_indexes where tablename = 'tag' and indexdef like '%(name)%'), 'with its index');
insert into tag (name) values ('c');
select t.eq((select max(id) from tag), 3, 'its sequence came along');
select t.eq(pg_get_serial_sequence('public.tag', 'id'), 'public.tag_id_seq', 'owned by its column');
select t.eq((select string_agg(pinned::text, ',' order by id) from seq_main where id <= 3), 'true,true,false', 'the added column''s values merged');

drop owned by gt_sdev;
drop role gt_sdev;
