-- Workflows: revert, checkpoints and rewind, dry runs, parallel attempts,
-- sibling merges and cherry-pick, scheduled merges, scenarios, bisect,
-- action tables and auto-merge policies.
drop role if exists gt_bot; drop role if exists gt_merger;
create table cust (id int primary key, name text not null, tier text not null default 'basic');
create table inv (id int primary key, cust int not null references cust(id) on delete cascade, amount int not null);
insert into cust select g, 'c' || g from generate_series(1, 10) g;
insert into inv select g, 1 + g % 10, g * 100 from generate_series(1, 20) g;
select gnomon.track('cust'); select gnomon.track('inv');
select gnomon.tick();

-------------------------------------------------------------------------------
-- revert: rows set to their past state, itself undoable
select gnomon.coordinate_text() as c0 \gset
update cust set name = 'oops' where id <= 3;
delete from inv where id = 5;
insert into cust values (11, 'new');
insert into inv values (21, 11, 1);
select t.eq((gnomon.revert('cust', :'c0', dry_run => true) -> 'tables' -> 0 -> 'updates' -> 0 ->> 'name'), 'c1', 'dry run lists the revert');
select t.eq((select name from cust where id = 1), 'oops', 'a dry run changes nothing');
select gnomon.revert('cust', :'c0', keys => '[1, 2]');
select t.eq((select string_agg(name, ',' order by id) from cust where id <= 3), 'c1,c2,oops', 'revert of chosen keys');
select gnomon.revert_tables(array['cust', 'inv']::regclass[], :'c0');
select t.eq((select count(*) from gnomon.diff(:'c0', 'main')), 0::bigint, 'after a revert of both tables the diff from the past is empty');
select t.ok((select meta ? 'revert' from gnomon.xact order by at desc limit 1), 'the revert is in the commit log');
-- revert of columns only, and by a filter
update cust set name = 'x', tier = 'gold' where id = 4;
select gnomon.revert('cust', :'c0', columns => array['tier']);
select t.eq((select name || '/' || tier from cust where id = 4), 'x/basic', 'only the chosen columns go back');
update cust set tier = 'gold' where id in (5, 6);
select gnomon.revert('cust', :'c0', filter => 'id = 5');
select t.eq((select string_agg(tier, ',' order by id) from cust where id in (5, 6)), 'basic,gold', 'only rows matching the filter');
select gnomon.revert('cust', :'c0');

-------------------------------------------------------------------------------
-- checkpoints and rewind on a branch
select gnomon.create_branch('work');
select gnomon.use('work');
update cust set name = 'w1' where id = 1;
select gnomon.checkpoint('before-risky', 'work');
update cust set name = 'w2' where id = 1;
update cust set name = 'w2' where id = 2;
delete from inv where id = 3;
insert into cust values (12, 'twelve');
select gnomon.use('main');
select gnomon.rewind('work', 'before-risky');
select gnomon.use('work');
select t.eq((select string_agg(name, ',' order by id) from cust where id in (1, 2)), 'w1,c2', 'rewind restores the checkpoint');
select t.eq((select count(*) from inv where id = 3), 1::bigint, 'a deleted row comes back');
select t.eq((select count(*) from cust where id = 12), 0::bigint, 'an inserted row goes');
select gnomon.use('main');
select t.eq((select count(*) from gnomon.diff('work@tag:before-risky', 'work')), 0::bigint, 'the branch equals its checkpoint');

-------------------------------------------------------------------------------
-- dry run: diff and checks, nothing kept
select gnomon.add_check('positive', 'select * from inv where amount < 0');
select gnomon.dry_run(array['update inv set amount = -1 where id = 1', 'insert into cust values (99, ''dry'')'], 'work') as dr \gset
select t.eq(((:'dr'::jsonb) ->> 'ok')::bool, true, 'dry run ran');
select t.eq(jsonb_array_length((:'dr'::jsonb) -> 'summary'), 2, 'it reports both tables');
select t.eq(((:'dr'::jsonb) -> 'checks' -> 0 ->> 'passed')::bool, false, 'and the failing check');
select gnomon.use('work');
select t.eq((select amount from inv where id = 1), 100, 'nothing kept on the branch');
select gnomon.use('main');
select t.eq((select count(*) from gnomon.branch where name like 'dry-%'), 0::bigint, 'no scratch branch left behind');
select t.eq(((gnomon.dry_run(array['update nosuch set x = 1'])) ->> 'ok')::bool, false, 'a failing statement is reported');
select gnomon.drop_check('positive');

-------------------------------------------------------------------------------
-- sibling merges: base is the parent at the earlier fork
select gnomon.create_branch('sib-a');
select gnomon.create_branch('sib-b');
select gnomon.use('sib-a'); update cust set name = 'from a' where id = 7; update cust set tier = 'a' where id = 8;
select gnomon.use('sib-b'); update cust set tier = 'b' where id = 7;
select gnomon.use('main');
select t.eq((select count(*) from gnomon.merge_preview('sib-a', 'sib-b') where action <> 'none'), 2::bigint, 'preview of a sibling merge');
select gnomon.merge('sib-a', 'sib-b');
select gnomon.use('sib-b');
select t.eq((select name || '/' || tier from cust where id = 7), 'from a/b', 'a row changed on both siblings in different columns merges');
select t.eq((select tier from cust where id = 8), 'a', 'and one changed on the source only arrives');
select gnomon.use('main');
select t.eq((select name from cust where id = 7), 'c7', 'main is untouched');
select t.eq((select count(*) from gnomon.change_request where status = 'merged'), 0::bigint, 'no change request marked merged by a sibling merge');
-- a repeated sibling merge is a no-op; a later change on the source merges alone
select gnomon.merge('sib-a', 'sib-b') as m2 \gset
select t.eq((select (stats ->> 'inserted')::int + (stats ->> 'updated')::int + (stats ->> 'deleted')::int from gnomon.merge where id = :m2), 0, 'a repeated sibling merge changes nothing');
select gnomon.use('sib-a'); update cust set name = 'again' where id = 9; select gnomon.use('main');
select gnomon.merge('sib-a', 'sib-b') as m3 \gset
select t.eq((select (stats ->> 'updated')::int from gnomon.merge where id = :m3), 1, 'the next merge carries the new change only');
-- both siblings into main: equal to merging each directly
select gnomon.merge('sib-b');
select gnomon.merge('sib-a');
select t.eq((select name || '/' || tier from cust where id = 7), 'from a/b', 'siblings merged into each other and then main');
-- strict: a source that forked later carries its parent's changes in between
select gnomon.create_branch('early');
update cust set name = 'main moved' where id = 10;
select gnomon.create_branch('late');
select gnomon.use('late'); update cust set tier = 'late' where id = 10; select gnomon.use('main');
select t.fails($$select gnomon.merge('late', 'early', strict => true)$$, null, 'strict refuses a source that forked later');
select gnomon.merge('late', 'early');
select gnomon.use('early');
select t.eq((select name || '/' || tier from cust where id = 10), 'main moved/late', 'without strict it carries main''s change');
select gnomon.use('main');

-------------------------------------------------------------------------------
-- cherry-pick: one transaction of a branch onto main
select gnomon.create_branch('pick');
select gnomon.use('pick');
begin; update cust set name = 'picked' where id = 2; select pg_current_xact_id()::text as px \gset
commit;
update cust set name = 'not picked' where id = 3;
select gnomon.use('main');
select gnomon.cherry_pick(array[:'px'::xid8], 'pick', 'main') as cp \gset
select t.eq((select string_agg(name, ',' order by id) from cust where id in (2, 3)), 'picked,c3', 'cherry-pick applies that transaction only');
select gnomon.undo_merge(((:'cp'::jsonb) ->> 'merge')::bigint);
select t.eq((select name from cust where id = 2), 'c2', 'a cherry-pick undone is a no-op');

-------------------------------------------------------------------------------
-- parallel attempts
select gnomon.attempts_create(3, 'try') as tries \gset
select gnomon.use('try-1'); update cust set tier = 'one' where id = 1;
select gnomon.use('try-2'); update cust set tier = 'two' where id = 1; update cust set tier = 'two' where id = 2;
select gnomon.use('main');
select t.eq((select rows from gnomon.compare(array['try-1', 'try-2']) where branch = 'try-2'), 2::bigint, 'compare counts each attempt''s changes');
select t.eq((select count(*) from gnomon.diff('try-1', 'try-2')), 2::bigint, 'two attempts diff against each other');
select gnomon.attempts_pick('try', 'try-2') as pick_cr \gset
select t.eq((select count(*) from gnomon.branch where name in ('try-1', 'try-3') and status = 'open'), 0::bigint, 'the other attempts are dropped');
select t.eq((select status from gnomon.change_request where id = :pick_cr), 'open', 'the winner has a change request');

-------------------------------------------------------------------------------
-- scheduled merges, run by the job loop as a merger
select gnomon.create_branch('later');
select gnomon.use('later'); update cust set tier = 'scheduled' where id = 3; select gnomon.use('main');
select gnomon.schedule_merge('later', now() - interval '1 second');
select gnomon.create_branch('future');
select gnomon.schedule_merge('future', now() + interval '1 day');
select t.eq(gnomon.run_scheduled_merges(), 1, 'one merge was due');
select t.eq((select tier from cust where id = 3), 'scheduled', 'it merged');
select t.eq((select status from gnomon.scheduled_merge where branch = (select id from gnomon.branch where name = 'future')), 'pending', 'the other waits');
-- the loop's login is no superuser: an admin and merger runs them; an admin that is not a merger
-- has nothing to do until a merge is due, and then says so
drop role if exists gt_loop; drop role if exists gt_noloop;
create role gt_loop login; grant gnomon_admin, gnomon_merger to gt_loop;
create role gt_noloop login; grant gnomon_admin to gt_noloop;
select gnomon.create_branch('later2');
select gnomon.use('later2'); update cust set tier = 'by the loop' where id = 4; select gnomon.use('main');
set role gt_noloop;
select t.eq(gnomon.run_scheduled_merges(), 0, 'nothing due, nothing to do');
reset role;
select gnomon.schedule_merge('later2', now() - interval '1 second');
set role gt_noloop;
select t.fails($$select gnomon.run_scheduled_merges()$$, '42501', 'a due merge needs a merger');
reset role;
set role gt_loop;
select t.eq(gnomon.run_scheduled_merges(), 1, 'the loop''s merger runs it');
reset role;
select t.eq((select tier from cust where id = 4), 'by the loop', 'it merged');
select t.eq((select status from gnomon.scheduled_merge where branch = (select id from gnomon.branch where name = 'later2')), 'merged', 'and it is recorded');

-------------------------------------------------------------------------------
-- scenarios
select gnomon.scenario_create('discount');
select gnomon.scenario_apply('discount', 'update inv set amount = amount / 2');
select gnomon.scenario_create('deeper', 'discount');
select gnomon.scenario_apply('deeper', 'update inv set amount = amount / 2');
select gnomon.add_metric('revenue', 'select sum(amount) from inv');
update inv set amount = amount + 1 where id = 1;   -- main moves on: the baseline is the base
select t.eq((select pct from gnomon.compare(array['discount'], array['revenue'])), -50.00::numeric, 'a scenario against its base');
select t.eq((select pct from gnomon.compare(array['deeper'], array['revenue'])), -50.00::numeric, 'a nested scenario against its parent scenario');
select t.eq((select count(*) from gnomon.scenario_step where scenario = 'discount'), 1::bigint, 'steps are recorded');
select t.ok(gnomon.scenario_promote('discount') > 0, 'promote opens a change request');

-------------------------------------------------------------------------------
-- bisect: a fault planted at a known transaction
create table bal (id int primary key, v int not null);
insert into bal select g, 10 from generate_series(1, 5) g;
select gnomon.track('bal');
select gnomon.tick();
select gnomon.coordinate_text() as good \gset
update bal set v = 11 where id = 1; select gnomon.tick();
update bal set v = 12 where id = 2; select gnomon.tick();
begin; update bal set v = 13 where id = 3; update bal set v = -1 where id = 4; select pg_current_xact_id()::text as bad_xid \gset
commit;
update bal set v = 14 where id = 5; select gnomon.tick();
update bal set v = 15 where id = 1; select gnomon.tick();
select t.eq((select ref from gnomon.bisect('select * from bal where v < 0', :'good') order by step desc limit 1), :'bad_xid', 'bisect finds the transaction');
select t.ok((select detail -> 'changes' @> '[{"table": "bal"}]' from gnomon.bisect('select * from bal where v < 0', :'good') order by step desc limit 1), 'with its changes');

-------------------------------------------------------------------------------
-- action tables: rows on a branch send nothing until merged
select gnomon.create_action_table('actions');
select gnomon.create_branch('act');
select gnomon.use('act');
insert into actions (kind, payload) values ('email', '{"to": "a@x.io"}');
select gnomon.use('main');
select t.eq((select count(*) from gnomon.outbox_poll('mailer', 'actions')), 0::bigint, 'held on the branch');
select gnomon.merge('act');
select t.eq((select count(*) from gnomon.outbox_poll('mailer', 'actions')), 1::bigint, 'delivered after the merge');
select t.ok(gnomon.describe() -> 'tables' @> '[{"name": "actions", "action_table": true}]', 'describe marks it');

-------------------------------------------------------------------------------
-- auto-merge policies: a role without gnomon_merger merges what a policy allows
create role gt_bot login;
grant select, insert, update, delete on cust, inv, actions to gt_bot;
grant usage on all sequences in schema public to gt_bot;
select gnomon.create_merge_policy('small', array['gt_bot']::name[], '{"max_rows": 2, "tables": ["cust"], "columns": {"cust": ["tier"]}}');
set role gt_bot;
select gnomon.create_branch('bot-ok');
select gnomon.use('bot-ok'); update cust set tier = 'policy' where id = 5; select gnomon.use('main');
select t.ok((gnomon.policy_eval('bot-ok') ->> 'allowed')::bool, 'policy_eval allows it');
select gnomon.merge('bot-ok') as pm \gset
select t.eq((select stats ->> 'policy' from gnomon.merge where id = :pm), 'small', 'merged under the policy');
select gnomon.create_branch('bot-big');
select gnomon.use('bot-big'); update cust set tier = 'x' where id <= 3; select gnomon.use('main');
select t.ok(not (gnomon.policy_eval('bot-big') ->> 'allowed')::bool, 'too many rows');
select t.fails($$select gnomon.merge('bot-big')$$, '42501', 'refused by the policy');
select gnomon.create_branch('bot-col');
select gnomon.use('bot-col'); update cust set name = 'renamed' where id = 6; select gnomon.use('main');
select t.fails($$select gnomon.merge('bot-col')$$, '42501', 'a column the policy does not allow');
select gnomon.create_branch('bot-act');
select gnomon.use('bot-act'); insert into actions (kind) values ('refund'); select gnomon.use('main');
select t.fails($$select gnomon.merge('bot-act')$$, '42501', 'outbox tables are excluded');
reset role;
select t.eq((select tier from cust where id = 5), 'policy', 'the allowed merge reached main');
select t.eq((select name from cust where id = 6), 'c6', 'the refused ones did not');
select gnomon.drop_merge_policy('small');
set role gt_bot;
select t.fails($$select gnomon.merge('bot-big')$$, '42501', 'without the policy: needs gnomon_merger');
reset role;
drop owned by gt_bot; drop role gt_bot;
