-- The security review, executable: what an ordinary role cannot do (docs/security.md).
drop role if exists gt_owner; drop role if exists gt_rando; drop role if exists gt_conf;
create role gt_owner login; create role gt_rando login; create role gt_conf login;
create table s (id int primary key, secret text);
insert into s values (1, 'top'), (2, 'secret');
create table other (id int primary key, v int);
insert into other values (1, 1);
select gnomon.track('s'); select gnomon.track('other');
grant select, insert, update, delete on s to gt_owner, gt_rando, gt_conf;
select gnomon.confine('gt_conf', array[]::text[]);
update s set secret = 'changed' where id = 1;
select gnomon.seal_ledger();

set role gt_owner;
select gnomon.create_branch('owned');
reset role;

set role gt_rando;
-- internal and operations functions
select t.fails($$select gnomon._purge_branch_rows(1)$$, '42501', 'purge a branch');
select t.fails($$select gnomon._log_xact(0, 1)$$, '42501', 'forge a merge link in the commit log');
select t.fails($$select gnomon.heartbeat()$$, '42501', 'heartbeat needs gnomon_admin');
select t.fails($$select gnomon.drop_history_before('s', now())$$, '42501', 'drop history');
select t.fails($$select gnomon.apply_retention('s')$$, '42501', 'apply retention');
select t.fails($$select gnomon.seal_ledger()$$, '42501', 'seal the ledger');
select t.fails($$select gnomon.restore_done('s', 0)$$, '42501', 'mark an archive restored');
select t.fails($$select gnomon.archive_partition('s', 1000000, 'file:///x', 1, 'x')$$, '42501', 'archive a partition');
select t.fails($$select gnomon.erase('s', '{"id": 1}', array['secret'], 'x')$$, '42501', 'erase');
select t.fails($$select gnomon.add_check('x', 'select 1')$$, '42501', 'add a check (it runs inside merges)');
-- branches of other roles
select t.fails($$select gnomon.drop_branch('owned')$$, '42501', 'drop someone else''s branch');
select t.fails($$select gnomon.close_branch('owned')$$, '42501', 'close someone else''s branch');
-- main is changed only through merges by gnomon_merger
select gnomon.create_branch('mine');
select t.fails($$select gnomon.merge('mine')$$, '42501', 'merge into main');
select t.fails(format('select gnomon.undo(%L)', (select xid::text from gnomon.history('s', '{"id": 1}') order by vkey desc limit 1)), '42501', 'undo on main');
-- history of a table the role cannot read
select t.fails($$select * from gnomon.history('other', '{"id": 1}')$$, '42501', 'history of an unreadable table');
select t.eq((select count(*) from gnomon.changes((select gnomon.coord_text(track_coord) from gnomon.tracked where relname = 'other'))
              where tbl = 'other'::regclass), 0::bigint, 'the feed skips unreadable tables');
select t.eq(_gnomon.other__vrow('{"id": 1}', 9223372036854775807, 'FFFFFFFF/FFFFFFFF'), null::jsonb, 'version images of unreadable tables');
-- storage is not reachable directly
select t.fails($$select * from _gnomon.s__v$$, '42501', 'read version storage');
select t.fails($$insert into _gnomon.s__bk values (1, 1, 0, 0)$$, '42501', 'write branch storage');
select t.fails($$select _gnomon.s__bwi('UPDATE', null, null, null, null)$$, '42501', 'call the internal branch write');
-- its own branch: fine
select gnomon.use('mine');
update s set secret = 'mine' where id = 2;
select gnomon.use('main');
select gnomon.drop_branch('mine');
reset role;

set role gt_conf;
select t.fails($$select gnomon.rebase('owned')$$, '42501', 'confined role rebases a branch it may not write');
select t.fails($$select gnomon.undo_xids(array['1'::xid8], 'owned')$$, '42501', 'confined role undoes on a branch it may not write');
reset role;

-- tracking (roles): a gnomon_admin member tracks and manages the tables it owns, and
-- nobody else's; an ordinary role tracks nothing
drop role if exists gt_tadmin;
create role gt_tadmin login;
grant gnomon_admin to gt_tadmin;
create table admins_own (id int primary key, v int);
alter table admins_own owner to gt_tadmin;
set role gt_tadmin;
select t.ok(gnomon.track('admins_own') > 0, 'a gnomon_admin member tracks a table it owns');
select gnomon.set_retention('admins_own', '{"keep_all": "90 days"}');
select gnomon.protect('admins_own');
select gnomon.protect('admins_own', false);
select t.fails($$select gnomon.track('other')$$, null, 'other is tracked already');
select t.fails($$select gnomon.set_retention('s', '{"keep_all": "1 day"}')$$, '42501', 'but not a table it does not own');
select t.fails($$select gnomon.untrack('s')$$, '42501', 'nor untrack one');
reset role;
create table rando_own (id int primary key);
alter table rando_own owner to gt_rando;
set role gt_rando;
select t.fails($$select gnomon.track('rando_own')$$, '42501', 'an ordinary role tracks nothing, even its own table');
select t.fails($$select gnomon.sync()$$, '42501', 'nor re-syncs every table');
select t.fails($$select gnomon.set_merge_strategy('s', 'secret', 'ours')$$, '42501', 'nor sets a merge strategy');
reset role;
select gnomon.untrack('admins_own');

-- tags: an ordinary role tags a coordinate and drops its own tags, not others'
set role gt_owner;
select t.ok(gnomon.create_tag('owner-tag') is not null, 'an ordinary role creates a tag');
reset role;
set role gt_rando;
select t.fails($$select gnomon.drop_tag('owner-tag')$$, '42501', 'another role cannot drop it');
select t.fails($$select gnomon.tick()$$, '42501', 'ticking is for gnomon_admin');
reset role;
set role gt_owner;
select t.ok(gnomon.drop_tag('owner-tag'), 'its creator drops it');
reset role;

-- feed consumers: an ordinary role creates and polls its own; nobody else moves it
set role gt_owner;
select gnomon.feed_create('owner-feed', 'now');
update s set secret = 'feed me' where id = 2;
select t.eq((select count(*) from gnomon.feed_poll('owner-feed', 100) where tbl = 's'::regclass), 1::bigint, 'an ordinary role polls its consumer');
reset role;
set role gt_rando;
select t.fails($$select * from gnomon.feed_poll('owner-feed', 100)$$, '42501', 'another role cannot advance it');
select t.fails($$select gnomon.feed_drop('owner-feed')$$, '42501', 'nor drop it');
select t.fails($$select gnomon.feed_create('owner-feed', 'now')$$, '42501', 'nor reset it');
reset role;
set role gt_owner;
select t.ok(gnomon.feed_drop('owner-feed'), 'its owner drops it');
reset role;

select t.ok((select bool_and(ok) from gnomon.verify_ledger()), 'ledger intact after the attempts');
select gnomon.unconfine('gt_conf');
drop owned by gt_owner; drop owned by gt_rando; drop owned by gt_conf; drop owned by gt_tadmin;
drop role gt_owner; drop role gt_rando; drop role gt_conf; drop role gt_tadmin;
