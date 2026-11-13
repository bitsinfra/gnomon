-- Plan shapes the routing views rely on, asserted on every PostgreSQL version the suite runs
-- on: a planner change that breaks them fails here, not in production.

create function t.plan(q text) returns text language plpgsql as $$
declare r record; p text := '';
begin
  for r in execute 'explain (costs off) ' || q loop p := p || r."QUERY PLAN" || E'\n'; end loop;
  return p;
end $$;

create table pacc (id int primary key, owner text not null, doc jsonb not null, bal int not null);
insert into pacc select g, 'o' || g, jsonb_build_object('k', g), 0 from generate_series(1, 50000) g;
create index on pacc using gin (doc);
create table pord (id int primary key, acc_id int not null, amt int not null);
insert into pord select g, 1 + (g * 7) % 50000, 1 from generate_series(1, 50000) g;
create index on pord (acc_id);
select gnomon.track('pacc');
select gnomon.track('pord');
analyze pacc; analyze pord;
drop role if exists gt_app;
create role gt_app login;
grant select, insert, update, delete on pacc, pord to gt_app;

-- tracking adds a permissive policy only; main's plans are unchanged, non-leakproof
-- operators included
set role gt_app;
select t.ok(t.plan($$select * from pacc where doc @> '{"k": 5}'$$) ~ 'Bitmap Index Scan', 'main: jsonb @> still uses its GIN index after tracking');
select t.ok(t.plan('select * from pacc where id = 5') ~ 'Index Scan using pacc_pkey', 'main: point read by key is an index scan');
reset role;

-- branch reads through the routing view
select gnomon.create_branch('plans');
update pacc set bal = 1 where id between 1 and 20;   -- main moves on: arm 3 and the probes have work
set role gt_app;
select gnomon.use('plans');
update pacc set bal = 2 where id between 10 and 30;  -- the branch writes some rows
analyze;   -- (as the superuser below sees it; gt_app cannot analyze)
reset role;
analyze _gnomon.pacc__bk; analyze _gnomon.pacc__b; analyze _gnomon.pacc__v;
set role gt_app;
select gnomon.use('plans');
-- a point read probes indexes; it never scans main's table (the arms are bare tables)
select t.ok(t.plan('select * from pacc where id = 5') !~ 'Seq Scan on pacc( |$)', 'branch: a point read does not scan main''s table');
-- a join pushes the join key into the arms: an index probe per row, no full scan of 50,000 rows
select t.ok(t.plan('select o.id, a.bal from pord o join pacc a on a.id = o.acc_id where o.id between 1 and 10') !~ 'Seq Scan on pacc( |$)',
            'branch: a join reaches main''s rows through their index');
-- a large scan gets its per-row probes hashed (the NOT EXISTS of the arm-1 policy)
select t.ok(t.plan('select count(*) from pacc') ~ '(hashed SubPlan|Hash Anti Join|Hash Right Anti Join)',
            'branch: a full scan hashes the touched-key and changed-key probes');
-- and an ordinary role reads through them (with the C module: its point-read custom scan)
select t.eq((select bal from pacc where id = 15), 2, 'branch point read of a branch row, as an ordinary role');
select t.eq((select bal from pacc where id = 5), 0, 'branch point read of a row changed on main since the fork');
select t.eq((select bal from pacc where id = 40000), 0, 'branch point read of an untouched row');
select gnomon.use('main');
reset role;


-- search views: a restriction with a non-leakproof operator reaches the GIN index on
-- a branch, with the same rows as the routing view
drop role if exists gt_conf_plans;
create role gt_conf_plans login;
grant select on pacc to gt_conf_plans;
select gnomon.confine('gt_conf_plans', array['plans']);
select gnomon.sync('pacc');
set role gt_app;
select gnomon.use('plans');
update pacc set doc = '{"k": 15, "x": 1}' where id = 15;
select t.ok(t.plan($$select * from pacc where doc @> '{"k": 25}'$$) !~ 'Bitmap Index Scan on pacc_doc', 'the routing view scans for jsonb @>');
select gnomon.use('plans', null, false, 'search');
select t.ok(t.plan($$select * from pacc where doc @> '{"k": 25}'$$) ~ 'Bitmap Index Scan on pacc_doc', 'the search view uses the GIN index');
create temp table sv_rows as select * from pacc where doc @> '{"k": 15}' or doc @> '{"k": 25}' or doc @> '{"k": 40000}';
select gnomon.use('plans');
select t.eq((select count(*) from (select * from pacc where doc @> '{"k": 15}' or doc @> '{"k": 25}' or doc @> '{"k": 40000}' except select * from sv_rows) x), 0::bigint, 'same rows as the routing view');
select t.eq((select count(*) from sv_rows), 3::bigint, 'including the branch''s own change');
select gnomon.use('plans', null, false, 'search');
update pacc set bal = 9 where id = 40000;
select gnomon.use('plans');
select t.eq((select bal from pacc where id = 40000), 9, 'writes through a search view land on the branch');
select gnomon.use('main');
reset role;
-- never for confined roles
set role gt_conf_plans;
select t.fails($$select gnomon.use('plans', null, false, 'search')$$, '42501', 'a confined role cannot choose search views');
select t.fails($$select * from gnomon_q_public.pacc limit 1$$, '42501', 'nor read them directly');
reset role;
select gnomon.unconfine('gt_conf_plans');
drop owned by gt_conf_plans; drop role gt_conf_plans;
-- a branch on a schema version: the version's view of a changed table keeps the
-- routing view's plan shape for keyed reads and joins, plus a keyed probe of the side table for
-- the added column
select gnomon.create_branch('vplans');
select gnomon.use('vplans');
select gnomon.ddl($$alter table pacc add column tier text default 'basic'$$);
update pacc set tier = 'gold' where id between 100 and 200;
select gnomon.use('main');
analyze _gnomon.branch_column;
set role gt_app;
select gnomon.use('vplans');
select t.ok(t.plan('select * from pacc where id = 5') !~ 'Seq Scan on pacc( |$)', 'version: a point read does not scan main''s table');
select t.ok(t.plan('select * from pacc where id = 5') !~ 'Seq Scan on branch_column', 'version: nor the side table');
select t.ok(t.plan('select o.id, a.tier from pord o join pacc a on a.id = o.acc_id where o.id between 1 and 10') !~ 'Seq Scan on pacc( |$)',
            'version: a join reaches main''s rows through their index');
select t.eq((select tier from pacc where id = 150), 'gold', 'version: a branch value');
select t.eq((select tier from pacc where id = 5), 'basic', 'version: the default for main''s rows');
select gnomon.use('main');
reset role;
drop owned by gt_app;
drop role gt_app;
