-- History and blame on branches, the commit log as a function, tick lookup by key.
create table acct (id int primary key, owner text not null, bal int not null default 0);
insert into acct select g, 'o' || g, 100 from generate_series(1, 5) g;
select gnomon.track('acct');
select gnomon.tick();
update acct set bal = 110 where id = 1;          -- main, before the fork
select gnomon.tick();
select gnomon.create_branch('feat');
update acct set owner = 'main-later' where id = 1;   -- main, after the fork: not in feat's lineage
select gnomon.use('feat');
begin;
select gnomon.note('alice', 'raise the balance');
update acct set bal = 120 where id = 1;
commit;
select gnomon.use('main');

-- main's history is unchanged; a bare key value works for a one-column key
select t.eq((select count(*) from gnomon.history('acct', '1')), 3::bigint, 'main: baseline, update, update');
select t.eq((select string_agg(op, ',' order by vkey) from gnomon.history('acct', '{"id": 1}')), 'baseline,update,update', 'main history');
select t.fails($$select * from gnomon.history('acct', '[1]')$$, '22023', 'an array is not a key');

-- the branch: main's versions up to the fork, then the branch's own
select t.eq((select string_agg(on_branch || ':' || op || ':' || (row_image ->> 'bal'), ',')
               from gnomon.history('acct', '1', 'feat')),
            'main:baseline:100,main:update:110,feat:update:120', 'branch history is the lineage at the fork');
select t.eq((select actor from gnomon.history('acct', '1', 'feat') where on_branch = 'feat'), 'alice', 'branch versions carry the actor');
select t.eq((select reason from gnomon.history('acct', '1', 'feat') where on_branch = 'feat'), 'raise the balance', 'and the reason');
select t.ok(not exists (select 1 from gnomon.history('acct', '1', 'feat') where row_image ->> 'owner' = 'main-later'),
            'main''s write after the fork is not in the branch''s history');

-- blame on the branch: bal from the branch, owner from main's baseline
select t.eq((select on_branch from gnomon.blame('acct', '1', 'feat') where col = 'bal'), 'feat', 'bal was last changed on the branch');
select t.eq((select actor from gnomon.blame('acct', '1', 'feat') where col = 'bal'), 'alice', 'by alice');
select t.eq((select on_branch from gnomon.blame('acct', '1', 'feat') where col = 'owner'), 'main', 'owner comes from main');
select t.eq((select value from gnomon.blame('acct', '1', 'feat') where col = 'owner'), '"o1"'::jsonb, 'as it was at the fork');
select t.eq((select value from gnomon.blame('acct', '1') where col = 'owner'), '"main-later"'::jsonb, 'main''s blame sees main''s write');

-- a nested branch reads its parent's versions up to its own fork
select gnomon.create_branch('sub', 'feat');
select gnomon.use('feat');
update acct set bal = 130 where id = 1;   -- after sub forked: not in sub's lineage
select gnomon.use('sub');
update acct set owner = 'sub' where id = 1;
delete from acct where id = 2;
select gnomon.use('main');
select t.eq((select string_agg(on_branch || ':' || op, ',') from gnomon.history('acct', '1', 'sub')),
            'main:baseline,main:update,feat:update,sub:update', 'nested lineage');
select t.eq((select row_image ->> 'bal' from gnomon.history('acct', '1', 'sub') where on_branch = 'sub'), '120', 'sub copied up feat''s row at its fork');
select t.eq((select string_agg(on_branch || ':' || op, ',') from gnomon.history('acct', '2', 'sub')),
            'main:baseline,sub:delete', 'a delete on the branch, after the row as tracked (main never wrote it: the baseline is main''s row)');
select t.eq((select row_image from gnomon.history('acct', '2', 'sub') where op = 'delete'), null::jsonb, 'a delete has no image');

-- a rebase moves the cutoff for rows the branch never wrote; written rows keep theirs
update acct set owner = 'after-rebase' where id = 3;
select gnomon.rebase('feat');
select t.eq((select string_agg(on_branch || ':' || op, ',') from gnomon.history('acct', '3', 'feat')),
            'main:baseline,main:update', 'an unwritten row shows main up to the new cutoff');
select t.eq((select count(*) from gnomon.history('acct', '1', 'feat') where on_branch = 'main'), 2::bigint,
            'a row written before the rebase keeps the lineage of its first write');
select t.eq((select row_image ->> 'owner' from gnomon.history('acct', '1', 'feat') where on_branch = 'feat' order by vkey desc limit 1),
            'main-later', 'and the rebase''s merged version carries main''s change');

-- the commit log lists a merge once, with its actor
select gnomon.create_branch('m1');
select gnomon.use('m1');
update acct set bal = 1 where id = 4;
select gnomon.use('main');
begin;
select gnomon.note('bob', 'ship it');
select gnomon.merge('m1') as mid \gset
commit;
select t.eq((select count(*) from gnomon.log() where detail ->> 'merge' = :'mid'), 1::bigint, 'a merge is listed once');
select t.eq((select actor from gnomon.log() where detail ->> 'merge' = :'mid'), 'bob', 'with the actor of its transaction');
select t.eq((select count(*) from gnomon.log('feat') where kind = 'commit'), 1::bigint, 'the log of one branch: its own attributed commits');
select t.ok((select bool_and(on_branch like '%m1%') from gnomon.log('m1')), 'the log of a merged branch shows its merge');

-- tick lookup by key equals the scan it replaces
select t.eq((select count(*) from _gnomon.acct__v v
              where gnomon._tick_of(v.gn_key, v.gn_xoff) is distinct from
                    (select k.at from gnomon.tick k where gnomon._vis(v.gn_key, v.gn_xoff, k.coord) order by k.id limit 1)), 0::bigint,
            '_tick_of finds the first tick that saw each version');
select t.ok(exists (select 1 from gnomon.history('acct', '1') where at_tick is not null), 'versions before a tick have one');
select t.ok(exists (select 1 from gnomon.history('acct', '4') where at_tick is null), 'a version after the last tick has none');
