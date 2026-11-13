-- Schema changes on a branch: constraints, renames, drops, type changes and dropped tables on a
-- branch. The branch reads and writes the new shape and its constraints hold there; main and a
-- sibling do not see it; the merge brings each change to main; a change main made since in
-- another way is a conflict.
create table cust (id int primary key, name text not null, email text, score int not null default 0, note text default 'n');
create table ord (id int primary key, cust_id int not null references cust(id), qty int not null);
create table scratchy (id int primary key, x int);
insert into cust select g, 'c' || g, 'c' || g || '@x.io', g, 'note' from generate_series(1, 10) g;
insert into ord select g, (g % 10) + 1, g from generate_series(1, 20) g;
insert into scratchy values (1, 1);
select gnomon.track('cust');
select gnomon.track('ord');
select gnomon.track('scratchy');
select gnomon.create_branch('s');
select gnomon.create_branch('sib');
select gnomon.use('s');

-- rename, drop, type change (with up and down), dropped table
select t.eq(gnomon.ddl('alter table cust rename column name to full_name') #>> '{changes,0,op}', 'rename_column', 'a rename');
select t.eq((select full_name from cust where id = 1), 'c1', 'a renamed column reads main''s values');
update cust set full_name = 'Carol' where id = 1;
insert into cust (id, full_name) values (11, 'eleven');
select t.eq((select full_name from cust where id = 1), 'Carol', 'and writes under its new name');
select t.fails('select name from cust', '42703', 'the old name is gone on the branch');
select t.eq(gnomon.ddl('alter table cust drop column note') #>> '{changes,0,op}', 'drop_column', 'a drop');
select t.fails('select note from cust', '42703', 'a dropped column is gone on the branch');
insert into cust (id, full_name, email) values (12, 'twelve', 'x@y.io');
select t.eq(gnomon.ddl('alter table cust alter column score type numeric(10,2) using score / 10.0', up => 'score / 10.0', down => '(score * 10)::int') #>> '{changes,0,op}',
            'alter_type', 'a type change');
select t.eq((select score from cust where id = 5), 0.50::numeric, 'main''s values read through up');
update cust set score = 2.5 where id = 5;
select t.eq((select score from cust where id = 5), 2.50::numeric, 'a write keeps its value in the new type');
select t.fails($$select gnomon.ddl('alter table cust alter column email type int', up => 'pg_sleep(0)::int')$$, null, 'up must convert');
select t.eq(gnomon.ddl('drop table scratchy') #>> '{changes,0,op}', 'drop_table', 'a dropped table');
select t.fails('select * from scratchy', '42P01', 'is gone on the branch');
select t.fails('insert into scratchy values (2, 2)', '42P01', 'for writes too');
-- a column added, renamed and retyped on the branch
select gnomon.ddl('alter table ord add column tag text');
select gnomon.ddl('alter table ord rename column tag to label');
update ord set label = 'rush' where id = 1;
select t.eq((select label from ord where id = 1), 'rush', 'an added column renamed');

-- NOT NULL, defaults, check, unique, foreign key (row 11 has no email yet)
select t.fails($$select gnomon.ddl('alter table cust alter column email set not null')$$, '23502', 'NOT NULL the branch''s rows break is refused');
update cust set email = 'eleven@x.io' where id = 11;
select gnomon.ddl('alter table cust alter column email set not null');
select t.fails($$insert into cust (id, full_name) values (13, 'thirteen')$$, '23502', 'NOT NULL holds on the branch');
select gnomon.ddl($$alter table cust alter column email set default 'none@x.io'$$);
insert into cust (id, full_name) values (13, 'thirteen');
select t.eq((select email from cust where id = 13), 'none@x.io', 'a default set on the branch');
select gnomon.ddl('alter table cust add constraint score_pos check (score >= 0)');
select t.fails('update cust set score = -1 where id = 2', '23514', 'a check holds on the branch');
select gnomon.ddl('alter table cust add constraint email_u unique (email)');
select t.fails($$insert into cust (id, full_name, email) values (14, 'dup', 'c3@x.io')$$, '23505', 'a unique constraint holds');
update cust set email = email where id = 3;
select t.eq((select email from cust where id = 3), 'c3@x.io', 'a row may keep its own value');
select gnomon.ddl('alter table ord add column ref_cust int');
select gnomon.ddl('alter table ord add constraint ord_ref foreign key (ref_cust) references cust (id)');
select t.fails('update ord set ref_cust = 999 where id = 1', '23503', 'a foreign key on a new column holds');
update ord set ref_cust = 11 where id = 1;
select t.eq((select ref_cust from ord where id = 1), 11, 'to a row that exists on the branch only');
select gnomon.ddl('create unique index ord_label_u on ord (label)');
select t.fails($$update ord set label = 'rush' where id = 2$$, '23505', 'a unique index on the branch');
select gnomon.ddl('alter table cust drop constraint score_pos');
update cust set score = -1 where id = 2;
select t.eq((select score from cust where id = 2), -1.00::numeric, 'a constraint the branch dropped no longer holds');
update cust set score = 0.2 where id = 2;

-- main and a sibling see none of it
select gnomon.use('sib');
select t.eq((select name || '/' || note || '/' || score from cust where id = 1), 'c1/note/1', 'a sibling reads main''s shape');
select t.eq((select count(*) from scratchy), 1::bigint, 'and the table the branch dropped');
update cust set score = score where id = 4;
select gnomon.use('main');
select t.eq((select name from cust where id = 1), 'c1', 'main is unchanged');
select t.fails('select full_name from cust', '42703', 'main has no renamed column');

-- the merge: every change reaches main, with the branch's rows
select gnomon.merge('s') as m \gset
select t.eq((select status from gnomon.merge where id = :m), 'applied', 'the merge applied');
select t.eq((select full_name from cust where id = 1), 'Carol', 'main has the rename and the value');
select t.ok(not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'cust' and column_name in ('name', 'note')),
            'and the drop');
select t.eq((select data_type from information_schema.columns where table_schema = 'public' and table_name = 'cust' and column_name = 'score'), 'numeric', 'and the type');
select t.eq((select score from cust where id = 5), 2.50::numeric, 'the branch''s value in the new type');
select t.eq((select score from cust where id = 3), 0.30::numeric, 'main''s rows converted by up');
select t.eq((select score from cust where id = 2), 0.20::numeric, 'and written ones');
select t.ok(to_regclass('public.scratchy') is null, 'the dropped table');
select t.eq((select count(*) from cust where id in (11, 12, 13)), 3::bigint, 'the branch''s rows');
select t.eq((select is_nullable from information_schema.columns where table_schema = 'public' and table_name = 'cust' and column_name = 'email'), 'NO', 'NOT NULL');
select t.eq((select column_default from information_schema.columns where table_schema = 'public' and table_name = 'cust' and column_name = 'email'), '''none@x.io''::text', 'the default');
select t.ok(exists (select 1 from pg_constraint where conname = 'email_u' and contype = 'u'), 'the unique constraint');
select t.ok(not exists (select 1 from pg_constraint where conname = 'score_pos'), 'not the one the branch dropped');
select t.ok(exists (select 1 from pg_constraint where conname = 'ord_ref' and contype = 'f' and convalidated), 'the foreign key, validated');
select t.ok(exists (select 1 from pg_indexes where indexname = 'ord_label_u'), 'the unique index');
select t.eq((select label || '/' || ref_cust from ord where id = 1), 'rush/11', 'the added, renamed column and the foreign key''s value');
select t.fails($$insert into cust (id, full_name, email) values (20, 'dup', 'c3@x.io')$$, '23505', 'main enforces the unique constraint now');
-- a new session writes the changed tables on a branch
\c
select gnomon.create_branch('after');
select gnomon.use('after');
update cust set full_name = 'after' where id = 2;
update ord set label = 'later' where id = 3;
select t.eq((select full_name from cust where id = 2), 'after', 'a branch after the merge writes the new shape');
select t.fails($$insert into cust (id, full_name, email) values (21, 'dup2', 'c4@x.io')$$, '23505', 'with main''s new constraints');
select gnomon.use('main');
select gnomon.drop_branch('after');
select gnomon.use('sib');
select t.eq((select full_name from cust where id = 1), 'c1', 'the sibling reads main''s new shape, at its base');
select t.eq((select score from cust where id = 4), 0.40::numeric, 'its rows converted too');
select gnomon.use('main');

-- main renamed a column the branch also renamed: a schema conflict
select gnomon.create_branch('c');
select gnomon.use('c');
select gnomon.ddl('alter table ord rename column qty to quantity');
select gnomon.use('main');
alter table ord rename column qty to amount;
select gnomon.merge('c') as mc \gset
select t.eq((select status from gnomon.merge where id = :mc), 'conflicts', 'a rename main made differently is a conflict');
select t.eq((select kind from gnomon.conflict where merge_id = :mc limit 1), 'schema', 'of kind schema');
select t.ok(exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'ord' and column_name = 'amount'), 'main is untouched by it');

-- expressions gnomon evaluates with its own rights (the branch's rows checked when a constraint
-- is added, the merge's VALIDATE and inserts on main) may call pg_catalog functions only: a
-- function of the caller's would run as gnomon
create function public.gn_untrusted(int) returns bool language sql as 'select true';
create function public.gn_untrusted_text() returns text language sql as 'select ''x''';
create domain public.gn_dz as int check (public.gn_untrusted(value));
select gnomon.create_branch('u');
select gnomon.use('u');
select t.fails($$select gnomon.ddl('alter table ord add constraint ord_u check (public.gn_untrusted(amount))')$$, '42501', 'a check calling a function outside pg_catalog is refused');
select t.fails($$select gnomon.ddl('alter table ord alter column amount set default length(public.gn_untrusted_text())')$$, '42501', 'so is such a default');
select t.fails($$select gnomon.ddl('create table nu (id int primary key, v int check (public.gn_untrusted(v)))')$$, '42501', 'and a new table''s check');
select t.fails($$select gnomon.ddl('create table nu (id int primary key, v text default public.gn_untrusted_text())')$$, '42501', 'and its default');
select t.fails($$select gnomon.ddl('alter table ord add column dz public.gn_dz')$$, '42501', 'and a column of a domain whose check calls one');
select t.eq(gnomon.ddl('alter table ord add constraint ord_pos check (amount >= 0 and length(amount::text) < 10)') #>> '{changes,0,op}', 'add_check', 'pg_catalog''s functions and operators are fine');
select gnomon.use('main');
select gnomon.drop_branch('u');

-- a foreign key added on a branch holds from both sides: on the branch a referenced row cannot be
-- deleted or re-keyed while a row (as the branch sees it) points at it
create table fpar (id int primary key, n text);
create table fchild (id int primary key, par_id int);
insert into fpar values (1, 'a'), (2, 'b'), (3, 'c');
insert into fchild values (1, 1), (2, null);
select gnomon.track('fpar');
select gnomon.track('fchild');
select gnomon.create_branch('fk2');
select gnomon.use('fk2');
select gnomon.ddl('alter table fchild add constraint fchild_par foreign key (par_id) references fpar(id)');
select t.fails('delete from fpar where id = 1', '23503', 'a referenced row cannot be deleted on the branch');
select t.fails('update fpar set id = 10 where id = 1', '23503', 'nor its key changed');
delete from fpar where id = 3;
update fpar set id = 20 where id = 2;
update fpar set n = 'x' where id = 1;
select t.eq((select string_agg(id || ':' || n, ',' order by id) from fpar), '1:x,20:b', 'unreferenced rows go or change key, referenced ones change other columns');
update fchild set par_id = 20 where id = 2;
select t.fails('delete from fpar where id = 20', '23503', 'a row referenced since is held too');
select t.fails('insert into fchild values (3, 99)', '23503', 'and the referencing side still checks');
select gnomon.use('main');
select t.eq((select count(*) from fpar), 3::bigint, 'main is untouched');
select gnomon.merge('fk2') as mfk \gset
select t.eq((select status from gnomon.merge where id = :mfk), 'applied', 'the merge validates the key on main');
select t.eq((select string_agg(id || ':' || coalesce(par_id::text, '-'), ',' order by id) from fchild), '1:1,2:20', 'with the branch''s rows');
select t.ok(exists (select 1 from pg_constraint where conname = 'fchild_par' and convalidated), 'the constraint is on main, validated');
