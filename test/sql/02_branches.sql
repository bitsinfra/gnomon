-- Branches. Lineage and cutoffs, isolation, nested branches, as-of on a branch,
-- INSTEAD OF writes with constraint and trigger emulation, scratch branches, TRUNCATE,
-- untracked tables, confinement, branch diff.

create table customer (id int generated always as identity primary key, email text not null unique, name text,
                       created_at timestamptz not null default now(), lname text generated always as (lower(name)) stored);
create table orders (id bigserial primary key, customer_id int not null references customer(id) on delete cascade,
                     amount numeric(10,2) not null check (amount > 0), status text not null default 'new');
create table audit (id bigserial primary key, what text not null, at timestamptz default now());
create table lookup (code text primary key, label text);       -- untracked
insert into lookup values ('a', 'Alpha');
insert into customer(email, name) select 'c' || g || '@x.io', 'Name ' || g from generate_series(1, 20) g;
insert into orders(customer_id, amount) select 1 + g % 20, g from generate_series(1, 40) g;

-- a user trigger that writes an audit row (unqualified name) and stamps the row
create function stamp_order() returns trigger language plpgsql as $$
begin
  new.status := coalesce(nullif(new.status, ''), 'new');
  insert into audit(what) values (tg_op || ' order ' || new.id);
  return new;
end $$;
create trigger stamp_order before insert or update on orders for each row execute function stamp_order();

select gnomon.track('customer'); select gnomon.track('orders'); select gnomon.track('audit');
select t.ok(to_regclass('gnomon_r_public.lookup') is not null, 'untracked table gets a pass-through view');

-- create a branch: one insert plus a coordinate capture
select gnomon.create_branch('feature');
select gnomon.use('feature');
select t.eq((select count(*) from customer), 20::bigint, 'branch sees main at the fork');

-- writes on the branch
update customer set name = 'Branch Name' where id = 1;
insert into customer(email, name) values ('new@x.io', 'New');
delete from orders where id = 1;
select t.eq((select lname from customer where id = 1), 'branch name', 'generated column computed on the branch');
select t.ok((select id from customer where email = 'new@x.io') > 20, 'identity draws from main''s sequence');
update orders set amount = 99 where id = 2 returning *;
select t.eq((select status from orders where id = 2), 'new', 'user BEFORE trigger fired on the branch');
select t.ok((select count(*) from audit where what like 'UPDATE order 2') = 1, 'trigger side effect landed on the branch');
-- RETURNING, MERGE and COPY work through the routing view
with r as (update customer set name = 'R' where id = 3 returning id) select t.eq(count(*), 1::bigint, 'RETURNING') from r;
select current_setting('server_version_num')::int >= 170000 as pg17 \gset
\if :pg17
merge into customer c using (values ('merge@x.io', 'M')) s(email, name) on c.email = s.email
  when not matched then insert (email, name) values (s.email, s.name);
select t.ok(exists (select 1 from customer where email = 'merge@x.io'), 'MERGE through the routing view (PG17+)');
\endif
copy orders(customer_id, amount) from program 'printf "5\t12.50\n6\t7\n"';
select t.eq((select count(*) from orders where amount = 12.50), 1::bigint, 'COPY FROM through the routing view');

-- main does not see branch writes
select gnomon.use('main');
select t.eq((select name from customer where id = 1), 'Name 1', 'main unaffected by branch update');
select t.ok(not exists (select 1 from customer where email = 'new@x.io'), 'main unaffected by branch insert');
select t.ok(exists (select 1 from orders where id = 1), 'main unaffected by branch delete');
select t.ok(not exists (select 1 from audit where what like 'UPDATE order 2'), 'main unaffected by branch trigger side effects');

-- isolation: main's changes after the fork are invisible on the branch
update customer set name = 'Main Change' where id = 5;
insert into customer(email, name) values ('main-only@x.io', 'Main');
delete from customer where id = 20;
select gnomon.use('feature');
select t.eq((select name from customer where id = 5), 'Name 5', 'cutoff hides main update');
select t.ok(not exists (select 1 from customer where email = 'main-only@x.io'), 'cutoff hides main insert');
select t.ok(exists (select 1 from customer where id = 20), 'cutoff hides main delete');

-- the arms partition the key space exactly: every key once
select t.eq((select count(*) from customer), (select count(distinct id) from customer), 'no key appears twice');
select t.eq((select count(*) from orders), (select count(distinct id) from orders), 'no order appears twice');

-- constraint emulation
select t.fails($$insert into customer(email, name) values ('c2@x.io', 'dup')$$, '23505', 'unique clash with an ancestor row');
select t.fails($$insert into customer(email, name) values ('new@x.io', 'dup')$$, '23505', 'unique clash with a branch row');
select t.fails($$insert into orders(customer_id, amount) values (9999, 1)$$, '23503', 'FK to a missing parent');
select t.fails($$insert into orders(customer_id, amount) values (1, -5)$$, '23514', 'CHECK constraint on the branch');
select t.fails($$update customer set email = null where id = 4$$, '23502', 'NOT NULL on the branch');
-- ON DELETE CASCADE emulated through the child's routing view
select t.ok((select count(*) from orders where customer_id = 7) > 0, 'customer 7 has orders');
delete from customer where id = 7;
select t.eq((select count(*) from orders where customer_id = 7), 0::bigint, 'cascade deleted the orders on the branch');
select gnomon.use('main');
select t.ok((select count(*) from orders where customer_id = 7) > 0, 'cascade stayed on the branch');

-- nested branches see their parent at the fork, frozen
select gnomon.use('feature');
select gnomon.create_branch('child', 'feature');
update customer set name = 'feature after child' where id = 2;
select gnomon.use('child');
select t.eq((select name from customer where id = 1), 'Branch Name', 'child sees parent changes before the fork');
select t.eq((select name from customer where id = 2), 'Name 2', 'child does not see parent changes after the fork');
select t.eq((select name from customer where id = 5), 'Name 5', 'child sees main at the parent''s cutoff');
update customer set name = 'child edit' where id = 1;
select gnomon.use('feature');
select t.eq((select name from customer where id = 1), 'Branch Name', 'parent unaffected by child');
select gnomon.create_branch('grandchild', 'child');
select gnomon.use('grandchild');
select t.eq((select name from customer where id = 1), 'child edit', 'grandchild reads through two levels');
select t.ok(not exists (select 1 from orders where customer_id = 7), 'grandchild inherits the cascade from two levels up');

-- as-of on a branch
select gnomon.use('feature');
select gnomon.coordinate_text() as fc \gset
update customer set name = 'later' where id = 3;
select gnomon.use('feature', :'fc');
select t.eq((select name from customer where id = 3), 'R', 'as-of on a branch');
select t.fails($$update customer set name = 'x' where id = 3$$, '25006', 'as-of on a branch is read-only');
select gnomon.use('feature');
select t.eq((select name from customer where id = 3), 'later', 'branch now');

-- branch diff against its base
select t.ok((select count(*) from gnomon.diff('feature') where tbl = 'public.customer'::regclass) > 0, 'branch diff has changes');
select t.ok(exists (select 1 from gnomon.diff('feature') where kind = 'delete' and key = '{"id": 7}'), 'branch diff shows the delete');
select t.ok(exists (select 1 from gnomon.diff('main', 'feature') where key = '{"id": 5}'), 'branch vs main now includes main''s change');

-- concurrent-update detection is covered by test/shell/concurrency.sh

-- untracked tables: reads work, writes from a branch fail
select t.eq((select label from lookup where code = 'a'), 'Alpha', 'untracked table readable on a branch');
select t.fails($$insert into lookup values ('b', 'Beta')$$, '42501', 'untracked table refuses branch writes');
do $$ begin
  update lookup set code = code;
  perform t.ok(false, 'an update of an untracked table on a branch');
exception when insufficient_privilege then
  perform t.ok(sqlerrm like '%lookup is not tracked, so a branch cannot write it%', 'the refusal says why');
end $$;

-- TRUNCATE on a branch writes a cleared marker
select coalesce(current_setting('gnomon.c_module', true), '') = 'on' as cmod \gset
\if :cmod
\else
select t.fails('truncate orders', null, 'TRUNCATE through the routing view fails (SQL-only gap)');
\endif
select gnomon.truncate('orders');
select t.eq((select count(*) from orders), 0::bigint, 'branch truncate clears the table on the branch');
insert into orders(customer_id, amount) values (1, 3);
select t.eq((select count(*) from orders), 1::bigint, 'inserts after a branch truncate');
select gnomon.use('main');
select t.ok((select count(*) from orders) > 30, 'main unaffected by branch truncate');
select gnomon.use('child');
select t.ok((select count(*) from orders) > 30, 'child forked before the truncate is unaffected');

-- scratch branches use unlogged tables and are swept by TTL
select gnomon.create_scratch('t') as sb \gset
select gnomon.use(:'sb');
update customer set name = 'scratch' where id = 1;
select t.eq((select count(*) from _gnomon.customer__b_u), 1::bigint, 'scratch branch writes go to unlogged tables');
select t.eq((select name from customer where id = 1), 'scratch', 'scratch branch read');
select t.ok(current_setting('search_path') like '%gnomon_r_public\_\_s,%', 'gnomon.use routes a scratch branch through the scratch schema');
-- constraints, foreign keys and cascades on a scratch branch probe the scratch views
insert into customer(email, name) values ('s1@x.io', 'S1');
select t.fails($$insert into customer(email, name) values ('s1@x.io', 'dup')$$, '23505', 'unique key against a scratch-branch row');
insert into orders(customer_id, amount) select id, 5 from customer where email = 's1@x.io';
select t.fails($$insert into orders(customer_id, amount) values (-1, 1)$$, '23503', 'foreign key on a scratch branch');
delete from customer where email = 's1@x.io';
select t.eq((select count(*) from orders o where not exists (select 1 from customer c where c.id = o.customer_id)), 0::bigint,
            'ON DELETE CASCADE on a scratch branch');
select t.ok(exists (select 1 from gnomon.diff(:'sb') d where d.key = '{"id": 1}' and d.col = 'name'), 'diff of a scratch branch');
-- a scratch context read through the logged schema is refused, never answered without its rows
set search_path = gnomon_r_public, public;
select t.fails('select * from customer where id = 1', '55000', 'logged routing views refuse a scratch branch');
select gnomon.use(:'sb');
-- nested scratch branches; a logged branch cannot stand on a scratch one
select gnomon.create_branch('sc-child', :'sb', 'scratch');
select t.fails(format($$select gnomon.create_branch('lg-child', %L)$$, :'sb'), null, 'no logged branch from a scratch branch');
select gnomon.use('sc-child');
select t.eq((select name from customer where id = 1), 'scratch', 'nested scratch branch reads its parent');
update customer set name = 'scratch child' where id = 2;
select gnomon.use(:'sb');
select t.eq((select name from customer where id = 2), 'Name 2', 'parent scratch branch unaffected by its child');
select t.ok(gnomon.connection_options(:'sb') like '%gnomon_r_public__s%', 'connection recipe for a scratch branch');
select gnomon.use('main');
select gnomon.merge('sc-child', :'sb');
select gnomon.use(:'sb');
select t.eq((select name from customer where id = 2), 'scratch child', 'merge between scratch branches');
select gnomon.use('main');
select gnomon.drop_branch('sc-child');
update gnomon.branch set last_used = now() - interval '2 hours' where name = :'sb';
select t.eq(gnomon.sweep_scratch(), 1, 'abandoned scratch branch swept');

-- confinement: a role that can write only its branch and cannot merge
drop role if exists gt_agent;
create role gt_agent login;
grant select, insert, update, delete on customer, orders, audit to gt_agent;
grant usage, select on all sequences in schema public to gt_agent;
select gnomon.confine('gt_agent', array['feature']);
set role gt_agent;
select t.fails($$update customer set name = 'x' where id = 1$$, '42501', 'confined role has no DML on main');
select gnomon.use('feature');
update customer set name = 'agent edit' where id = 9;
select t.eq((select name from customer where id = 9), 'agent edit', 'confined role writes its branch');
select t.fails($$select gnomon.use('child')$$, '42501', 'confined role cannot read another branch (read isolation)');
select t.fails($$select set_config('gnomon.branch', 'child', false), set_config('search_path', 'gnomon_r_public, public', false);
                 select name from customer where id = 9$$, '42501', 'not by setting gnomon.branch either');
select gnomon.use('main');
select t.fails($$select gnomon.merge('feature')$$, '42501', 'confined role cannot merge');
select gnomon.create_branch('agent-own');
select gnomon.use('agent-own');
update customer set name = 'own' where id = 10;
select gnomon.use('main');
reset role;

-- a table tracked after a branch exists reads, on that branch, as of its tracking point
select gnomon.use('main');
create table late (id int primary key, v int);
insert into late values (1, 1), (2, 2);
select gnomon.track('late');
update late set v = 10 where id = 1;
select gnomon.use('feature');
select t.eq(t.rows('select * from late'), '[{"id": 1, "v": 1}, {"id": 2, "v": 2}]'::jsonb, 'late-tracked table on an older branch');
update late set v = 20 where id = 2;
select t.eq((select v from late where id = 2), 20, 'and it can be written there');
select gnomon.use('main');
select t.eq((select v from late where id = 2), 2, 'main unaffected');

-- DDL on untracked tables in a routed schema: their pass-through views follow, never block it
create table scratchpad (id int primary key, a int);
select t.ok(to_regclass('gnomon_r_public.scratchpad') is not null and to_regclass('gnomon_r_public__s.scratchpad') is not null,
            'pass-through views in both routing schemas');
alter table scratchpad add column b text;
alter table scratchpad alter column a type bigint;
select t.ok(exists (select 1 from information_schema.columns where table_schema = 'gnomon_r_public' and table_name = 'scratchpad' and column_name = 'b'),
            'pass-through view follows ADD COLUMN');
drop table scratchpad;
select t.ok(to_regclass('gnomon_r_public.scratchpad') is null and to_regclass('gnomon_r_public__s.scratchpad') is null,
            'DROP TABLE of an untracked table needs no CASCADE');
select t.ok(to_regclass('gnomon_r_public.lookup') is not null, 'other pass-through views are untouched');

-- dropping a branch removes its rows
select gnomon.drop_branch('grandchild');
select t.ok(not exists (select 1 from gnomon.branch where name = 'grandchild'), 'branch dropped');
select t.eq((select count(*) from gnomon.branches), (select count(*) from gnomon.branch where id <> 0)::bigint, 'branches view');

-- key changes on a branch follow ON UPDATE, not ON DELETE (a key change is stored as a delete
-- plus an insert): NO ACTION refuses while referenced, CASCADE moves the children, SET NULL
-- clears them, as on main
create table kp (id int primary key, name text);
create table kc_cascade (id int primary key, p int references kp(id) on delete cascade);   -- ON UPDATE NO ACTION
create table kc_upd (id int primary key, p int references kp(id) on update cascade on delete cascade);
create table kc_null (id int primary key, p int references kp(id) on update set null on delete cascade);
insert into kp values (1, 'one'), (2, 'two'), (3, 'three'), (4, 'four');
insert into kc_cascade values (1, 1);
insert into kc_upd values (1, 2), (2, 2);
insert into kc_null values (1, 3);
select gnomon.track('kp'); select gnomon.track('kc_cascade'); select gnomon.track('kc_upd'); select gnomon.track('kc_null');
select t.fails($$update kp set id = 100 where id = 1$$, '23503', 'main refuses a referenced key change (NO ACTION)');
select gnomon.create_branch('keys');
select gnomon.use('keys');
select t.fails($$update kp set id = 100 where id = 1$$, '23503', 'branch refuses it too, not cascading the delete');
select t.ok(exists (select 1 from kc_cascade where p = 1), 'the child is still there');
update kp set id = 200 where id = 2;
select t.eq((select string_agg(id || ':' || p, ',' order by id) from kc_upd), '1:200,2:200', 'ON UPDATE CASCADE moves the children');
update kp set id = 300 where id = 3;
select t.eq((select string_agg(id || ':' || coalesce(p::text, 'null'), ',' order by id) from kc_null), '1:null', 'ON UPDATE SET NULL');
update kp set id = 400 where id = 4;   -- unreferenced: a plain key change
select t.eq((select string_agg(id::text, ',' order by id) from kp), '1,200,300,400', 'key changes on the branch');
select gnomon.use('main');
select t.eq((select string_agg(id::text, ',' order by id) from kp), '1,2,3,4', 'main untouched');
select gnomon.merge('keys');
select t.eq((select string_agg(id || ':' || p, ',' order by id) from kc_upd), '1:200,2:200', 'merged children follow their parent');

-- renaming a tracked table, or moving it to another schema: it stays tracked, under its new name
create table rn_old (id int primary key, v int);
insert into rn_old values (1, 1), (2, 1);
select gnomon.track('rn_old');
select gnomon.coordinate_text() as rn_c \gset
update rn_old set v = 2;
select gnomon.create_branch('rnb');
alter table rn_old rename to rn_new;
select t.ok(exists (select 1 from gnomon.tracked where rel = 'rn_new'::regclass and relname = 'rn_new'), 'a renamed table stays tracked');
update rn_new set v = 3 where id = 2;
select t.eq((select count(*) from gnomon.history('rn_new', '{"id": 2}')), 3::bigint, 'writes after the rename are versioned');
select gnomon.use('main', :'rn_c');
select t.eq((select v from rn_new where id = 1), 1, 'its past reads under the new name');
select gnomon.use('rnb');
select t.eq((select v from rn_new where id = 1), 2, 'branches read it under the new name');
update rn_new set v = 20 where id = 1;
select gnomon.use('main');
create schema other;
alter table rn_new set schema other;
select t.ok(exists (select 1 from gnomon.tracked where rel = 'other.rn_new'::regclass and nsp = 'other'), 'a table moved to another schema stays tracked');
select t.ok(to_regclass('gnomon_r_other.rn_new') is not null and to_regclass('gnomon_r_public.rn_new') is null, 'its routing view moved with it');
select gnomon.merge('rnb');
select t.eq((select v from other.rn_new where id = 1), 20, 'a branch made before the move merges into it');

-- a unique index that is not a constraint holds against ancestor rows too
create table uq (id int primary key, code text);
create unique index uq_code on uq (code);
insert into uq values (1, 'a');
select gnomon.track('uq');
select gnomon.create_branch('uqb');
select gnomon.use('uqb');
select t.fails($$insert into uq values (2, 'a')$$, '23505', 'a plain unique index holds against ancestor rows on a branch');
insert into uq values (2, 'b');
select t.fails($$insert into uq values (3, 'b')$$, '23505', 'and against the branch''s own rows');
select gnomon.use('main');

reset role;
select gnomon.unconfine('gt_agent');
drop owned by gt_agent;
drop role gt_agent;

-- blame on a branch credits it with what it changed only, for a row main never wrote since tracking
create table bl (id int primary key, a text, b text);
insert into bl values (1, 'a', 'b');
select gnomon.track('bl');
select gnomon.create_branch('bl-b');
select gnomon.use('bl-b');
update bl set b = 'changed' where id = 1;
select gnomon.use('main');
select t.eq((select string_agg(col || ':' || on_branch, ',' order by col) from gnomon.blame('bl', '{"id": 1}', 'bl-b')),
            'a:main,b:bl-b,id:main', 'blame on the branch');
select t.eq((select op from gnomon.history('bl', '{"id": 1}', 'bl-b') limit 1), 'baseline', 'its history starts at the row as tracked');
select t.eq((select count(*) from gnomon.history('bl', '{"id": 1}')), 0::bigint, 'main''s history is still empty');
