-- With the C module: a branch on a schema version routes qualified names to
-- the version's views; SET gnomon.branch alone on such a branch is refused by name rather than
-- reading main's shape; routing touches the branch's last_used, which expiry reads.
create table acct (id int primary key, owner text);
insert into acct select g, 'o' || g from generate_series(1, 5) g;
select gnomon.track('acct');
select gnomon.create_branch('v');
select gnomon.use('v');
select gnomon.ddl($$alter table acct add column tier text default 'basic'$$);
update acct set tier = 'gold' where id = 1;
-- qualified names route to the version's views for main's columns; a branch-only column needs
-- the unqualified name (PostgreSQL resolves columns before the module swaps the table)
update public.acct set owner = 'branch' where id = 2;
select t.eq((select owner || '/' || tier from acct where id = 2), 'branch/basic', 'a qualified write lands on the branch');
select t.eq((select owner from public.acct where id = 2), 'branch', 'a qualified read sees it');
select t.fails('select tier from public.acct', '42703', 'a branch-only column by a qualified name');
select gnomon.use('main');
set gnomon.branch = 'v';
select t.fails('select * from acct', '0A000', 'SET gnomon.branch alone on a versioned branch is refused');
reset gnomon.branch;
select t.eq((select owner from acct where id = 2), 'o2', 'main reads as before');

select gnomon.create_branch('plain');
update gnomon.branch set last_used = now() - interval '1 hour' where name = 'plain';
set gnomon.branch = 'plain';
select count(*) from acct;
reset gnomon.branch;
select t.ok((select last_used > now() - interval '1 minute' from gnomon.branch where name = 'plain'), 'routing touches last_used');
-- read-only transactions do not
update gnomon.branch set last_used = now() - interval '1 hour' where name = 'plain';
begin read only;
set local gnomon.branch = 'plain';
select count(*) from acct;
commit;
select t.ok((select last_used < now() - interval '30 minutes' from gnomon.branch where name = 'plain'), 'not in a read-only transaction');

-- The C trigger keeps the current version partition open only until its statement ends, so DDL
-- later in the same transaction can alter or drop it (a migration's backfill and ADD COLUMN in
-- one transaction).
create table mig (id int primary key, a int, b text);
insert into mig select g, g, 'x' from generate_series(1, 20) g;
select gnomon.track('mig');
select t.eq((select tgfoid::regproc::text from pg_trigger where tgrelid = 'mig'::regclass and tgname = 'gnomon_v'),
            '_gnomon.c_version_trigger', 'mig is versioned by the C trigger');
begin;
update mig set a = a + 1 where id <= 10;
alter table mig add column c int default 7;
update mig set c = 8 where id = 1;
update mig set a = 0;
commit;
select t.eq((select a || '/' || c from mig where id = 1), '0/8', 'a write, an ADD COLUMN and more writes in one transaction');
create function t.mig_fn() returns void language plpgsql as $$
begin
  update mig set a = a + 1 where id = 2;
  alter table mig add column e int;
  update mig set e = 5 where id = 2;
end $$;
select t.mig_fn();
select t.eq((select e from mig where id = 2), 5, 'a write, an ADD COLUMN and a write in one function');
begin;
update mig set a = a + 1 where id = 3;
savepoint s;
update mig set a = -1 where id = 3;
rollback to s;
alter table mig add column d int;
commit;
select t.eq((select a from mig where id = 3), 1, 'a write, a rolled-back savepoint, then DDL');
begin;
update mig set a = a + 1 where id = 4;
select gnomon.untrack('mig');
rollback;
select t.ok(exists (select 1 from gnomon.tracked where rel = 'mig'::regclass), 'a write then untrack in one transaction');
