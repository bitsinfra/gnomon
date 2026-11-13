-- Three-way merge, strategies, conflicts as rows, preview, partial merge,
-- rebase, early warning, undo (transaction, merge, role window), incremental merge.

create table item (id int primary key, name text not null, qty int not null default 0, tags jsonb not null default '[]',
                   meta jsonb not null default '{}', body text, price numeric(10,2));
insert into item select g, 'item ' || g, 10, '["a"]', jsonb_build_object('color', 'red', 'size', g), E'line1\nline2\nline3\nline4', 1.00
  from generate_series(1, 30) g;
select gnomon.track('item');
select gnomon.set_merge_strategy('item', 'qty', 'counter');
select gnomon.set_merge_strategy('item', 'tags', 'set');
select gnomon.set_merge_strategy('item', 'meta', 'jsonb');
select gnomon.set_merge_strategy('item', 'body', 'text3');
drop role if exists gt_merger; drop role if exists gt_plain;
create role gt_merger login;
grant gnomon_merger to gt_merger;

-------------------------------------------------------------------------------
-- a clean merge
select gnomon.create_branch('b1');
select gnomon.use('b1');
update item set name = 'renamed 1' where id = 1;
insert into item(id, name) values (100, 'new on b1');
delete from item where id = 2;
select gnomon.use('main');
select t.eq((select count(*) from gnomon.merge_preview('b1')), 3::bigint, 'preview lists three changes');
select t.eq((select name from item where id = 1), 'item 1', 'preview changes nothing');
select gnomon.merge('b1') as m1 \gset
select t.eq((select status from gnomon.merge where id = :m1), 'applied', 'merge applied');
select t.eq((select name from item where id = 1), 'renamed 1', 'merged update');
select t.ok(exists (select 1 from item where id = 100), 'merged insert');
select t.ok(not exists (select 1 from item where id = 2), 'merged delete');
select t.ok(exists (select 1 from gnomon.xact x where x.merge_id = :m1), 'merge recorded in the commit log');
-- merging again is a no-op; the base moved
select gnomon.merge('b1') as m1b \gset
select t.eq((select stats - 'stale_reads' from gnomon.merge where id = :m1b), '{"deleted": 0, "updated": 0, "inserted": 0}'::jsonb, 'second merge is a no-op');

-------------------------------------------------------------------------------
-- type-aware strategies: counter, set, jsonb, text3, ours/theirs, custom
select gnomon.create_branch('b2');
select gnomon.use('b2');
update item set qty = qty + 5, tags = '["a", "b"]', meta = meta || '{"size": 99}', body = E'line1 (branch)\nline2\nline3\nline4' where id = 3;
select gnomon.use('main');
update item set qty = qty - 2, tags = '["a", "c"]', meta = meta || '{"color": "blue"}', body = E'line1\nline2\nline3\nline4 (main)' where id = 3;
select gnomon.merge('b2') as m2 \gset
select t.eq((select status from gnomon.merge where id = :m2), 'applied', 'strategy merge applied');
select t.eq((select qty from item where id = 3), 13, 'counter: ours + (theirs - base)');
select t.eq((select tags from item where id = 3), '["a", "c", "b"]'::jsonb, 'set: union of additions');
select t.eq((select meta from item where id = 3), '{"color": "blue", "size": 99}'::jsonb, 'jsonb: recursive merge by key');
select t.eq((select body from item where id = 3), E'line1 (branch)\nline2\nline3\nline4 (main)', 'text3: non-overlapping hunks merge');

-------------------------------------------------------------------------------
-- conflicts are rows; resolve and resume
select gnomon.create_branch('b3');
select gnomon.use('b3');
update item set name = 'theirs name', price = 2.00 where id = 4;
update item set body = E'X\nline2\nline3\nline4' where id = 5;
delete from item where id = 6;
select gnomon.use('main');
update item set name = 'ours name' where id = 4;
update item set body = E'Y\nline2\nline3\nline4' where id = 5;
update item set name = 'changed on main' where id = 6;
select gnomon.merge('b3') as m3 \gset
select t.eq((select status from gnomon.merge where id = :m3), 'conflicts', 'merge stops on conflicts');
select t.eq((select count(*) from gnomon.conflict where merge_id = :m3), 3::bigint, 'three conflicts recorded');
select t.ok(exists (select 1 from gnomon.conflict where merge_id = :m3 and col = 'name' and kind = 'value'), 'value conflict on name');
select t.ok(exists (select 1 from gnomon.conflict where merge_id = :m3 and col = 'body' and kind = 'text-hunk'), 'overlapping text hunks conflict');
select t.ok(exists (select 1 from gnomon.conflict where merge_id = :m3 and kind = 'delete-update'), 'delete vs update conflict');
select t.eq((select name from item where id = 4), 'ours name', 'nothing applied while conflicted');
select gnomon.resolve(id, 'theirs') from gnomon.conflict where merge_id = :m3 and col = 'name';
select gnomon.resolve(id, 'value', '"Z\nline2\nline3\nline4"') from gnomon.conflict where merge_id = :m3 and col = 'body';
select gnomon.resolve(id, 'ours') from gnomon.conflict where merge_id = :m3 and kind = 'delete-update';
select gnomon.merge('b3', resume => :m3);
select t.eq((select status from gnomon.merge where id = :m3), 'applied', 'resumed merge applied');
select t.eq((select (name, price) from item where id = 4), row('theirs name'::text, 2.00::numeric(10,2)), 'resolution and non-conflicting column applied');
select t.eq((select body from item where id = 5), E'Z\nline2\nline3\nline4', 'value resolution applied');
select t.eq((select name from item where id = 6), 'changed on main', 'ours resolution keeps the row');

-------------------------------------------------------------------------------
-- merge invariants on single values (merge fuzzing lives in test/fuzz)
select t.eq(_gnomon.m3_value('conflict', '1', '2', '2', 'c') -> 'v', '2'::jsonb, 'merge(b, x, x) = x');
select t.eq(_gnomon.m3_value('conflict', '1', '1', '3', 'c') -> 'v', '3'::jsonb, 'merge(b, b, t) = t');
select t.eq(_gnomon.m3_value('conflict', '1', '2', '1', 'c') -> 'v', '2'::jsonb, 'merge(b, o, b) = o');
select t.ok(_gnomon.m3_value('conflict', '1', '2', '3', 'c') ? 'c', 'divergent values conflict');
create function pick_max(b jsonb, o jsonb, t jsonb) returns jsonb language sql as $$ select greatest(o, t) $$;
select t.eq(_gnomon.m3_value('pick_max', '1', '2', '3', 'c') -> 'v', '3'::jsonb, 'custom strategy');
select t.eq(_gnomon.diff3(E'a\nb\nc\nd', E'a\nB\nc\nd', E'a\nb\nc\nD') ->> 'v', E'a\nB\nc\nD', 'diff3 merges separated hunks');
select t.ok(_gnomon.diff3(E'a\nb\nc', E'a\nB\nc', E'a\nb\nC') ? 'conflict', 'diff3: adjacent hunks conflict, as in GNU diff3');
select t.eq(_gnomon.diff3(E'a\nb', E'x\na\nb', E'a\nb\ny') ->> 'v', E'x\na\nb\ny', 'diff3: inserts at both ends');

-------------------------------------------------------------------------------
-- partial merge: only the listed keys
select gnomon.create_branch('b4');
select gnomon.use('b4');
update item set name = 'p1' where id = 7;
update item set name = 'p2' where id = 8;
select gnomon.use('main');
select gnomon.merge('b4', keys => '[{"id": 7}]');
select t.eq((select name from item where id = 7), 'p1', 'partial merge applied the listed key');
select t.eq((select name from item where id = 8), 'item 8', 'partial merge left the other key');
select gnomon.merge('b4');
select t.eq((select name from item where id = 8), 'p2', 'the rest merges later');
-- partial merge by a key predicate, evaluated with the caller's rights
select gnomon.create_branch('b4p');
select gnomon.use('b4p');
update item set name = 'pred ' || id where id between 19 and 22;
select gnomon.use('main');
select t.eq(jsonb_array_length(gnomon.merge_where('b4p', 'item', 'id < 21', preview => true)), 2, 'predicate preview lists the matching keys');
select gnomon.merge_where('b4p', 'item', 'id < 21');
select t.eq((select string_agg(name, ',' order by id) from item where id between 19 and 22), 'pred 19,pred 20,item 21,item 22', 'partial merge by a key predicate');
select t.eq((select count(*) from gnomon.merge_preview('b4p', keys => '[{"id": 21}]')), 1::bigint, 'preview takes a key list too');

-------------------------------------------------------------------------------
-- rebase carries the branch onto main; early warnings
select gnomon.create_branch('b5');
select gnomon.watch();   -- sets the watch point
select gnomon.use('b5');
update item set name = 'b5 name' where id = 9;
update item set qty = 50 where id = 10;
select gnomon.use('main');
update item set name = 'main name' where id = 9;   -- conflicts with b5
update item set name = 'main 11' where id = 11;    -- untouched on b5
select t.ok(gnomon.watch() >= 1, 'watch found a conflict');
select t.ok(exists (select 1 from gnomon.warning w join gnomon.branch b on b.id = w.branch where b.name = 'b5' and w.key = '{"id": 9}'), 'early warning recorded');
select gnomon.rebase('b5');
select gnomon.use('b5');
select t.eq((select name from item where id = 11), 'main 11', 'rebase picks up main changes the branch did not touch');
select t.eq((select qty from item where id = 10), 50, 'rebase keeps branch changes');
select t.eq((select name from item where id = 9), 'b5 name', 'conflicting key keeps the branch value');
select gnomon.use('main');
select t.ok(exists (select 1 from gnomon.conflict c join gnomon.branch b on b.id = c.branch where b.name = 'b5'), 'rebase conflict listed on the branch');
-- changes made before a rebase are still merged after it (the merge's keys start at the last
-- merge, not at the rebase)
select gnomon.create_branch('b5b');
select gnomon.use('b5b');
update item set name = 'before the rebase' where id = 23;
select gnomon.use('main');
select gnomon.rebase('b5b');
select gnomon.merge('b5b');
select t.eq((select name from item where id = 23), 'before the rebase', 'a change made before a rebase is merged after it');

-- a branch main has left far behind is warned about, or rebased with auto_rebase on
insert into gnomon.setting(name, value) values ('warn_changes_since_base', '20') on conflict (name) do update set value = excluded.value;
select gnomon.watch();
select gnomon.create_branch('lagging');
select gnomon.create_branch('lagging2');
update item set qty = qty + 1;   -- 30 versions on main
select gnomon.watch();
select t.ok((select behind from gnomon.branches where name = 'lagging') >= 30, 'gnomon.branches shows how far main has moved since the base');
select t.ok(exists (select 1 from gnomon.warning w join gnomon.branch b on b.id = w.branch where b.name = 'lagging' and w.kind = 'behind-base'),
            'a branch past the threshold is warned about');
select gnomon.rebase('lagging');
select t.ok(not exists (select 1 from gnomon.warning w join gnomon.branch b on b.id = w.branch where b.name = 'lagging' and w.kind = 'behind-base')
            and (select behind from gnomon.branches where name = 'lagging') = 0, 'a rebase clears it');
insert into gnomon.setting(name, value) values ('auto_rebase', 'on') on conflict (name) do update set value = excluded.value;
delete from gnomon.warning;
update item set qty = qty - 1;
select gnomon.watch();
select t.eq((select behind from gnomon.branches where name = 'lagging2'), 0::bigint, 'auto_rebase rebases it instead');
delete from gnomon.setting where name in ('auto_rebase', 'warn_changes_since_base');

-------------------------------------------------------------------------------
-- undo: one transaction, with later edits becoming conflicts
update item set name = 'to undo', qty = 77 where id = 12;
select xid from gnomon.history('item', '{"id": 12}') order by vkey desc limit 1 \gset
select gnomon.undo(:'xid');
select t.eq((select (name, qty) from item where id = 12), row('item 12'::text, 10), 'undo restored the pre-image');
-- undo of an undo restores the original
select xid as uxid from gnomon.history('item', '{"id": 12}') order by vkey desc limit 1 \gset
select gnomon.undo(:'uxid');
select t.eq((select name from item where id = 12), 'to undo', 'undo of an undo');
-- a later edit to the same field makes undo refuse rather than overwrite silently
update item set name = 'v1' where id = 13;
select xid as x13 from gnomon.history('item', '{"id": 13}') order by vkey desc limit 1 \gset
update item set name = 'v2' where id = 13;
select t.fails(format('select gnomon.undo(%L)', :'x13'), '40001', 'undo conflicts with a later edit');
-- undo a merge
select gnomon.create_branch('b6');
select gnomon.use('b6');
update item set name = 'b6' where id = 14;
insert into item(id, name) values (200, 'b6 insert');
select gnomon.use('main');
select gnomon.merge('b6') as m6 \gset
select gnomon.undo_merge(:m6);
select t.eq((select name from item where id = 14), 'item 14', 'undo merge reverted the update');
select t.ok(not exists (select 1 from item where id = 200), 'undo merge reverted the insert');
select t.eq((select status from gnomon.merge where id = :m6), 'undone', 'merge marked undone');
-- undo everything a role did in a window
select gnomon._do_tick(true);
select pg_sleep(0.01);
select now() as t0 \gset
grant select, update on item to gt_merger;
set role gt_merger;
update item set name = 'by role' where id = 15;
update item set name = 'by role' where id = 16;
reset role;
select gnomon.undo_role('gt_merger', :'t0');
select t.eq((select count(*) from item where name = 'by role'), 0::bigint, 'role-window undo');

-------------------------------------------------------------------------------
-- permissions: only gnomon_merger members merge into main
create role gt_plain login;
grant select on item to gt_plain;
select gnomon.create_branch('b7');
set role gt_plain;
select t.fails($$select gnomon.merge('b7')$$, '42501', 'merge needs gnomon_merger');
reset role;
set role gt_merger;
select gnomon.merge('b7');
reset role;

-- a merger who is not a superuser settles the conflicts of a merge; a role that may not merge cannot
select gnomon.create_branch('b8');
select gnomon.use('b8');
update item set name = 'b8 side' where id = 20;
select gnomon.use('main');
update item set name = 'main side' where id = 20;
set role gt_merger;
select gnomon.merge('b8') as m8 \gset
reset role;
select t.eq((select status from gnomon.merge where id = :m8), 'conflicts', 'a conflict to settle');
select min(id) as c8 from gnomon.conflict where merge_id = :m8 \gset
set role gt_plain;
select t.fails(format('select gnomon.resolve(%s, %L)', :c8, 'theirs'), '42501', 'a role that may not merge cannot resolve');
select t.fails(format('select gnomon.resolve_all(%s, %L)', :m8, 'theirs'), '42501', 'nor resolve them all');
reset role;
set role gt_merger;
select gnomon.resolve(id, 'theirs') from gnomon.conflict where merge_id = :m8;
select t.eq((select resolved_by::text from gnomon.conflict where id = :c8), 'gt_merger', 'recorded as the merger');
select gnomon.merge('b8', resume => :m8);
reset role;
select t.eq((select name from item where id = 20), 'b8 side', 'resolved and resumed by the merger');

-------------------------------------------------------------------------------
-- branch into branch
select gnomon.create_branch('parent');
select gnomon.create_branch('kid', 'parent');
select gnomon.use('kid');
update item set name = 'from kid' where id = 17;
select gnomon.use('main');
select gnomon.merge('kid');
select gnomon.use('parent');
select t.eq((select name from item where id = 17), 'from kid', 'merged into the parent branch');
select gnomon.use('main');
select t.eq((select name from item where id = 17), 'item 17', 'main unaffected by a branch-to-branch merge');

-------------------------------------------------------------------------------
-- protected tables accept changes only through merges
create table setting (k text primary key, v text);
insert into setting values ('mode', 'a');
select gnomon.track('setting', protected => true);
select t.fails($$update setting set v = 'b'$$, '42501', 'protected table refuses a direct write');
select gnomon.create_branch('cfg');
select gnomon.use('cfg');
update setting set v = 'b';
select gnomon.use('main');
select gnomon.merge('cfg');
select t.eq((select v from setting), 'b', 'protected table changed through a merge');

-------------------------------------------------------------------------------
-- a custom strategy through merge() itself (it runs under a fixed search_path)
select gnomon.set_merge_strategy('item', 'price', 'pick_max');
select t.eq((select merge ->> 'price' from gnomon.tracked where rel = 'item'::regclass), 'public.pick_max', 'custom strategy stored qualified');
select gnomon.create_branch('cs');
select gnomon.use('cs');
update item set price = 7 where id = 18;
select gnomon.use('main');
update item set price = 5 where id = 18;
select gnomon.merge('cs') as mcs \gset
select t.eq((select status from gnomon.merge where id = :mcs), 'applied', 'custom strategy merge applied');
select t.eq((select price from item where id = 18), 7.00::numeric(10,2), 'custom strategy decided the value');
select t.fails($$select gnomon.set_merge_strategy('item', 'price', 'no_such_fn')$$, null, 'unknown strategy refused');

-------------------------------------------------------------------------------
-- incremental merges: a commit per batch, resumable, parents before children and deletes
-- children first, every batch locked and planned once, the same checks as merge()
create table ia (id int primary key, n int not null default 0, note text);
create table ic (id int primary key, a int not null references ia(id), v int);   -- NO ACTION
insert into ia select g, 0, 'a' || g from generate_series(1, 6) g;
insert into ic select g, 1 + g % 3, 0 from generate_series(1, 6) g;
-- the child is tracked first, so its id is the smaller: resume must follow the FK order, not ids
select gnomon.track('ic');
select gnomon.track('ia');
select gnomon.set_merge_strategy('ia', 'n', 'counter');
grant select, insert, update, delete on ia, ic to gt_merger;
select gnomon.create_branch('inc');
select gnomon.use('inc');
insert into ia values (10, 0, 'new parent');
insert into ic values (10, 10, 1), (11, 10, 2);              -- children of the new parent
delete from ic where a = 1;                                  -- the children of 1, then 1 itself
delete from ia where id = 1;
update ia set n = n + 5 where id between 2 and 6;            -- counters
update ia set note = 'theirs' where id = 2;                  -- conflicts with main below
update ic set v = 9 where id = 2;
select gnomon.use('main');
update ia set n = n + 1 where id between 2 and 6;
update ia set note = 'ours' where id = 2;
set role gt_merger;                                          -- not a superuser
call gnomon.merge_incremental('inc', batch => 2);
reset role;
select max(id) as mi from gnomon.merge \gset
select t.eq((select status from gnomon.merge where id = :mi), 'conflicts', 'incremental merge stops at a conflict');
select t.eq((select note from ia where id = 2), 'ours', 'nothing of the conflicted batch applied');
select gnomon.resolve(id, 'theirs') from gnomon.conflict where merge_id = :mi;
set role gt_merger;
call gnomon.merge_incremental('inc', resume => :mi, batch => 2);
reset role;
select t.eq((select status from gnomon.merge where id = :mi), 'applied', 'resumed incremental merge applied');
select t.eq((select note from ia where id = 2), 'theirs', 'the resolution was used');
select t.eq((select string_agg(n::text, ',' order by id) from ia where id between 2 and 6), '6,6,6,6,6', 'counters applied once: ours + (theirs - base)');
select t.ok(not exists (select 1 from ia where id = 1) and not exists (select 1 from ic where a = 1), 'deletes applied children first');
select t.eq((select string_agg(id || ':' || a, ',' order by id) from ic where a = 10), '10:10,11:10', 'children inserted after their parent');
select t.eq((select v from ic where id = 2), 9, 'the child table, after the parent in FK order, was merged');
select t.ok(not exists (select 1 from _gnomon.merge_pending where merge_id = :mi), 'no pending deletes left');
select t.ok(cardinality((select xids from gnomon.merge where id = :mi)) > 2, 'a transaction per batch');
-- the source reads what was merged where the merged value differs from its own
select gnomon.use('inc');
select t.eq((select n from ia where id = 3), 6, 'the source reads the merged counter');
select gnomon.use('main');
-- undo reverts every batch
select gnomon.undo_merge(:mi);
select t.eq((select string_agg(n::text, ',' order by id) from ia where id between 2 and 6), '1,1,1,1,1', 'undo of an incremental merge');
select t.ok(exists (select 1 from ia where id = 1) and not exists (select 1 from ia where id = 10), 'undo restored deletes and inserts');
-- a change request must be approved first, and checks run on the merged state
select gnomon.create_branch('inc2');
select gnomon.use('inc2');
update ia set note = 'inc2' where id = 3;
select gnomon.use('main');
select gnomon.open_change_request('inc2', 'title') as cr \gset
set role gt_merger;
select t.fails($$call gnomon.merge_incremental('inc2')$$, '42501', 'incremental merge refused before approval');
reset role;
select t.ok(not exists (select 1 from gnomon.merge m join gnomon.branch b on b.id = m.source where b.name = 'inc2'), 'nothing recorded when refused');
select t.fails($$call gnomon.merge_incremental('inc2', 'inc')$$, null, 'into the parent only');

-------------------------------------------------------------------------------
-- a merge leaves the session where it was for the rest of its transaction: writing another
-- branch (the source's refresh after a three-way merge, a merge into a branch) must not move
-- gnomon.branch, which with the C module alone routes plain reads of the table
reset role;
create table lk (id int primary key, a int not null, j jsonb not null default '{}');
insert into lk select g, g from generate_series(1, 5) g;
select gnomon.track('lk');
select gnomon.set_merge_strategy('lk', 'j', 'jsonb');
select gnomon.create_branch('lk1');
select gnomon.use('lk1');
update lk set j = j || '{"y": 9}' where id = 3;
select gnomon.use('main');
update lk set a = 38 where id = 3;           -- both sides changed row 3: planned three-way, the source refreshed
insert into lk values (6, 6);                -- main only: a read of the source would miss it
begin;
select gnomon.merge('lk1') as mlk \gset
select t.eq(coalesce(current_setting('gnomon.branch', true), ''), '', 'a three-way merge into main leaves the session on main');
select t.eq((select count(*) from public.lk where id in (3, 6)), 2::bigint, 'reads later in the merge''s transaction read main');
select t.eq((select j ->> 'y' from public.lk where id = 3) || '/' || (select a from public.lk where id = 3), '9/38', 'the merged row');
commit;
select gnomon.create_branch('lkp');
select gnomon.create_branch('lkc', 'lkp');
select gnomon.use('lkc');
update lk set a = 70 where id = 1;
select gnomon.use('main');
begin;
select gnomon.merge('lkc') as mlkc \gset
select t.eq((select status from gnomon.merge where id = :mlkc), 'applied', 'a merge into a branch');
select t.eq(coalesce(current_setting('gnomon.branch', true), ''), '', 'a merge into a branch leaves the session on main');
select t.eq((select a from public.lk where id = 1), 1, 'main still reads its own row after a merge into a branch');
commit;
select gnomon.use('lkp');
select t.eq((select a from lk where id = 1), 70, 'the branch has the merged row');
select gnomon.use('main');

reset role;
drop owned by gt_merger; drop owned by gt_plain;
drop role gt_merger; drop role gt_plain;
