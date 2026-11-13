-- History checkpoints. A past read with checkpoints on equals the same read with
-- them off and the state saved at that coordinate, on both sides of each checkpoint, for main and
-- for a branch whose base fell behind; the checkpoint arm reads one partition.
create table acct (id int primary key, v int not null, s text);
insert into acct select g, g, 's' || g from generate_series(1, 400) g;
select gnomon.track('acct');
create table t.snap (step int primary key, coord text, state jsonb);
create procedure t.rounds(n int, from_step int) language plpgsql as $$
begin
  for i in from_step..from_step + n - 1 loop
    update acct set v = v + i where id % 7 = i % 7;
    delete from acct where id = 400 - i;
    insert into acct values (1000 + i, i, 'new') on conflict do nothing;
    update acct set id = id + 5000 where id = 100 + i;
    commit;
    insert into t.snap select i, gnomon.coordinate_text(), (select jsonb_agg(to_jsonb(a) order by a.id) from public.acct a);
    commit;
  end loop;
end $$;
call t.rounds(4, 1);
select gnomon.create_branch('old', at => (select coord from t.snap where step = 2));
select gnomon.use('old'); update acct set s = 'branch' where id = 1; select gnomon.use('main');
select gnomon.history_checkpoint('acct') as ck1 \gset
call t.rounds(4, 5);
select gnomon.history_checkpoint('acct', (select coord from t.snap where step = 6)) as ck2 \gset
call t.rounds(4, 9);
select t.eq((select count(*) from gnomon.history_checkpoint where tbl = (select id from gnomon.tracked where relname = 'acct')), 2::bigint, 'two checkpoints');
select t.eq((select rows from gnomon.history_checkpoint where id = :ck1), (select jsonb_array_length(state)::bigint from t.snap where step = 4), 'the first has the rows of its moment');

create function t.read_at(c text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform gnomon.use('main', c);
  select jsonb_agg(to_jsonb(a) order by a.id) into r from acct a;
  perform gnomon.use('main');
  return r;
end $$;
do $$
declare s record; off jsonb; onn jsonb;
begin
  for s in select * from t.snap order by step loop
    perform gnomon.set('checkpoints', 'off');
    off := t.read_at(s.coord);
    perform gnomon.set('checkpoints', 'on');
    onn := t.read_at(s.coord);
    perform t.eq(off, s.state, 'as-of read at step ' || s.step || ' without checkpoints');
    perform t.eq(onn, s.state, 'as-of read at step ' || s.step || ' with checkpoints');
  end loop;
end $$;
-- which checkpoint a read near one picks
select gnomon.set('checkpoints', 'on');
select gnomon.use('main', (select coord from t.snap where step = 3));
select t.eq(gnomon._ctx_ck((select id from gnomon.tracked where relname = 'acct')), :ck1, 'a read before the first checkpoint uses it');
select gnomon.use('main', (select coord from t.snap where step = 6));
select t.eq(gnomon._ctx_ck((select id from gnomon.tracked where relname = 'acct')), :ck2, 'one at the second uses that');
-- the checkpoint arm reads one partition
create function t.ck_partitions_read() returns int language plpgsql as $$
declare p jsonb; n int := 0; r record;
begin
  execute 'explain (analyze, format json) select count(*) from acct' into p;
  for r in select x from jsonb_path_query(p, 'strict $.**') x where x ->> 'Relation Name' like 'acct__ck\_%' and (x ->> 'Actual Loops')::numeric > 0 loop
    n := n + 1;
  end loop;
  return n;
end $$;
select t.eq(t.ck_partitions_read(), 1, 'one checkpoint partition is read');
select gnomon.use('main');
select t.eq(t.ck_partitions_read(), 0, 'none on main now');
-- a branch whose base fell behind reads through the checkpoint too
select gnomon.set('checkpoints', 'off');
select gnomon.use('old');
create temp table b_off as select * from acct;
select gnomon.use('main');
select gnomon.set('checkpoints', 'on');
select gnomon.use('old');
select t.eq((select count(*) from (select * from acct except select * from b_off) x), 0::bigint, 'branch read equal with checkpoints');
select t.eq((select count(*) from acct) , (select count(*) from b_off), 'same rows');
select t.eq((select s from acct where id = 1), 'branch', 'the branch''s own write');
select gnomon.use('main');
-- joins on a past read still reach the key index through the checkpoint arm
select gnomon.use('main', (select coord from t.snap where step = 5));
select t.ok((select count(*) from acct a join generate_series(1, 5) g on a.id = g) = 5, 'a join through the checkpoint');
select gnomon.use('main');
-- retention by policy
select gnomon.set_checkpoint_policy('acct', '0 seconds', 1);
select t.eq(gnomon.run_checkpoint_policies(), 1, 'the policy makes one');
select t.eq((select count(*) from gnomon.history_checkpoint where tbl = (select id from gnomon.tracked where relname = 'acct')), 1::bigint, 'and keeps one');
select gnomon.drop_history_checkpoint('acct', (select max(id) from gnomon.history_checkpoint));
select gnomon.set('checkpoints', 'off');
-- DDL keeps them readable
select gnomon.history_checkpoint('acct') as ck3 \gset
alter table acct add column w int default 3;
select gnomon.set('checkpoints', 'on');
select gnomon.use('main', (select gnomon.coord_text(coord) from gnomon.history_checkpoint where id = :ck3));
select t.eq((select count(*) from acct where w = 3), (select count(*) from acct), 'a column added after a checkpoint reads its default');
select gnomon.use('main');
select gnomon.untrack('acct');
select t.ok(to_regclass('_gnomon.acct__ck') is null, 'untrack drops the checkpoints');

-- TRUNCATE on main: a checkpoint and a marker; the past keeps its rows
create table logx (id int primary key, msg text);
insert into logx select g, 'm' || g from generate_series(1, 50) g;
select gnomon.track('logx');
update logx set msg = 'changed' where id <= 5;
select gnomon.coordinate_text() as before_tr \gset
select gnomon.create_branch('pre-truncate');
select t.fails($$truncate logx$$, '0A000', 'a plain TRUNCATE is still refused');
select gnomon.truncate('logx');
select t.eq((select count(*) from logx), 0::bigint, 'main is empty');
insert into logx values (1, 'after');
select gnomon.use('main', :'before_tr');
select t.eq((select count(*) from logx), 50::bigint, 'the past keeps every row');
select t.eq((select count(*) from logx where msg = 'changed'), 5::bigint, 'as they were');
select gnomon.use('pre-truncate');
select t.eq((select count(*) from logx), 50::bigint, 'a branch forked before keeps its rows');
select gnomon.use('main');
select t.eq((select count(*) from gnomon.changes(:'before_tr') where op = 'truncate'), 1::bigint, 'the feed reports one truncate');
select t.eq((select string_agg(op, ',' order by vkey) from gnomon.history('logx', '7')), 'truncate', 'history shows it');
select t.eq((select string_agg(op, ',' order by vkey) from gnomon.history('logx', '1')), 'baseline,update,truncate,insert', 'and what came before and after');
select t.eq((select count(*) from gnomon.diff(:'before_tr', 'main') where kind = 'delete'), 49::bigint, 'a diff across it sees the rows it removed');
select gnomon.seal_ledger();
select t.ok((select bool_and(ok) from gnomon.verify_ledger()), 'the ledger seals and verifies across it');
