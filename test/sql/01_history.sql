-- History on main. Tracking, versions, coordinates, exact replay, ticks, tags,
-- statement mode, wide keys, large values, lazy baselines, key changes, TRUNCATE refusal.

create table acc (id int primary key, owner text not null, balance int not null default 0, note text, doc jsonb);
insert into acc select g, 'o' || g, g * 10, null, jsonb_build_object('g', g) from generate_series(1, 50) g;
select gnomon.track('acc');

-- coordinates: text round trip
-- (one coordinate: two calls may differ, since the WAL insert position moves with other sessions)
select gnomon.coordinate_text() as c_rt \gset
select t.eq(gnomon.coord_text(gnomon.coord(:'c_rt')), :'c_rt', 'coordinate text round trip');
select t.fails($$select gnomon.coord('nonsense')$$, null, 'bad coordinate text is rejected');

-- a workload with a commit per step, recording what each step's reader saw
create table t.snap (step int, coord text, rows jsonb);
create procedure t.workload(n int, tbl text) language plpgsql as $$
declare i int; k int;
begin
  for i in 1..n loop
    k := 1 + (i * 7919) % 60;
    case i % 5
      when 0 then execute format('delete from %s where id = $1', tbl) using k;
      when 1 then execute format('insert into %s(id, owner, balance) values ($1, $2, $3) on conflict (id) do update set balance = %s.balance + 1', tbl, tbl)
                  using k, 'n' || k, k;
      when 2 then execute format('update %s set note = $1 where id = $2', tbl) using 'step ' || i, k;
      when 3 then execute format('update %s set balance = balance - 1, doc = coalesce(doc, ''{}'') || jsonb_build_object(''i'', $1) where id %% 3 = $2', tbl) using i, i % 3;
      else execute format('update %s set owner = owner || ''.'' where id = $1', tbl) using k;
    end case;
    commit;
    execute format('insert into t.snap select $1, gnomon.coordinate_text(), (select coalesce(jsonb_agg(to_jsonb(a) order by a.id), ''[]'') from %s a)', tbl) using i;
    commit;
  end loop;
end $$;
call t.workload(120, 'acc');

-- exact replay: reading as of every returned coordinate gives the rows that read saw
do $$
declare s record; got jsonb;
begin
  for s in select * from t.snap order by step loop
    perform gnomon.use('main', s.coord);
    select coalesce(jsonb_agg(to_jsonb(a) order by a.id), '[]') into got from gnomon_r_public.acc a;
    perform t.eq(got, s.rows, format('replay at step %s', s.step));
    -- point reads through the same views
    perform t.eq((select to_jsonb(a) from gnomon_r_public.acc a where a.id = 7),
                 (select x from jsonb_array_elements(s.rows) x where (x->>'id')::int = 7), format('point read at step %s', s.step));
  end loop;
  perform gnomon.use('main');
end $$;

-- versions: deltas carry only changed columns; keyframes when the cumulative delta passes half the row
select t.ok((select count(*) from _gnomon.acc__v where gn_flags & 2 <> 0 and gn_flags & 8 = 0 and gn_mask is not null) > 0, 'deltas exist');
select t.ok((select count(*) from _gnomon.acc__v where gn_flags & 32 <> 0) > 0, 'lazy baselines were written');
select t.ok((select count(*) from _gnomon.acc__v where gn_flags & 32 <> 0 and gn_key >> 48 <> 1) = 0, 'baselines in epoch 1');
-- every version key is >= its xid (the stamp), and keys never decrease along a row (claim 1)
select t.ok(not exists (select 1 from _gnomon.acc__v where gn_xoff < 0 and gn_flags & 32 = 0), 'key >= xid');
select t.ok(not exists (
  select 1 from (select id, gn_key, lag(gn_key) over (partition by id order by gn_key, gn_lsn) as prev from _gnomon.acc__v) s
   where s.gn_key < s.prev), 'keys never decrease per row');

-- the change feed is exact: union of batches = all committed versions, no gaps, no duplicates
do $$
declare c0 text := (select coord from t.snap where step = 10); c1 text := (select coord from t.snap where step = 60);
        c2 text := (select coord from t.snap where step = 120); a bigint; b bigint; whole bigint;
begin
  select count(*) into a from gnomon.changes(c0, c1);
  select count(*) into b from gnomon.changes(c1, c2);
  select count(*) into whole from gnomon.changes(c0, c2);
  perform t.eq(a + b, whole, 'feed batches add up');
  perform t.ok(a > 0 and b > 0, 'feed batches are non-empty');
  perform t.eq((select count(*) from (select vkey, vlsn from gnomon.changes(c0, c1) intersect select vkey, vlsn from gnomon.changes(c1, c2)) x), 0::bigint, 'no duplicates across batches');
  -- without row images: the same change set, in the same order
  perform t.eq((select string_agg(vkey || '/' || vlsn || '/' || key::text || '/' || op, ',' order by vkey, vlsn, key::text) from gnomon.changes(c0, c2, null, false)),
               (select string_agg(vkey || '/' || vlsn || '/' || key::text || '/' || op, ',' order by vkey, vlsn, key::text) from gnomon.changes(c0, c2)),
               'the key-only feed is the same change set');
  perform t.ok(not exists (select 1 from gnomon.changes(c0, c2, null, false) where new is not null or old is not null), 'and carries no images');
end $$;

-- feed consumers
select gnomon.feed_create('c1', (select coord from t.snap where step = 1));
select t.ok((select count(*) from gnomon.feed_poll('c1', 25)) = 25, 'feed poll returns a full batch');
select t.ok((select count(*) from gnomon.feed_poll('c1', 100000)) > 0, 'feed poll returns the rest');
select t.eq((select count(*) from gnomon.feed_poll('c1', 100)), 0::bigint, 'feed poll is empty when caught up');
update acc set note = 'after' where id = 2;
select t.eq((select count(*) from gnomon.feed_poll('c1', 100)), 1::bigint, 'feed poll sees a new change once');

-- diff between two coordinates on main
select t.ok((select count(*) from gnomon.diff((select coord from t.snap where step = 5), (select coord from t.snap where step = 6))) > 0, 'diff between coordinates');
select t.eq((select count(*) from gnomon.diff((select coord from t.snap where step = 5), (select coord from t.snap where step = 5))), 0::bigint, 'diff of a coordinate with itself');

-- statement mode (bulk) produces the same history
create table bulk (like acc including all);
insert into bulk select * from acc;
select gnomon.track('bulk', write_mode => 'statement');
truncate t.snap;
call t.workload(60, 'bulk');
do $$
declare s record; got jsonb;
begin
  for s in select * from t.snap order by step loop
    perform gnomon.use('main', s.coord);
    select coalesce(jsonb_agg(to_jsonb(a) order by a.id), '[]') into got from gnomon_r_public.bulk a;
    perform t.eq(got, s.rows, format('statement-mode replay at step %s', s.step));
  end loop;
  perform gnomon.use('main');
end $$;
update bulk set balance = balance + 1;   -- one statement, every row
select t.eq((select count(*) from gnomon.changes((select coord from t.snap where step = 60)) where tbl = 'bulk'::regclass), (select count(*) from bulk), 'bulk update versions every row once');

-- key change = delete + insert
select gnomon.coordinate_text() as ck \gset
update acc set id = 1000 where id = 4;
select t.eq((select op from gnomon.changes(:'ck') where key = '{"id": 4}'), 'delete', 'key change records a delete');
select t.eq((select op from gnomon.changes(:'ck') where key = '{"id": 1000}'), 'insert', 'key change records an insert');

-- TRUNCATE is refused on tracked tables
select t.fails('truncate acc', '0A000', 'truncate refused');

-- wide keys use an internal id map
create table wide (a text, b text, c int, v int, primary key (a, b, c));
insert into wide values ('x', 'y', 1, 1), ('x', 'y', 2, 2);
select gnomon.track('wide');
select t.ok((select wide_key from gnomon.tracked where rel = 'wide'::regclass), 'three-column key is wide');
select gnomon.coordinate_text() as cw \gset
update wide set v = 10 where c = 1;
delete from wide where c = 2;
insert into wide values ('p', 'q', 3, 3);
select t.eq((select count(*) from _gnomon.wide__id), 3::bigint, 'id map has every key');
select gnomon.use('main', :'cw');
select t.eq(t.rows('select * from wide'), '[{"a": "x", "b": "y", "c": 1, "v": 1}, {"a": "x", "b": "y", "c": 2, "v": 2}]'::jsonb, 'wide-key as-of read');
select gnomon.use('main');

-- large values are stored once in the blob store
create table docs (id int primary key, body text, meta jsonb);
select gnomon.track('docs');
insert into docs values (1, repeat('lorem ipsum ', 1000), '{"a": 1}'), (2, repeat('lorem ipsum ', 1000), '{"a": 2}');
select gnomon.coordinate_text() as cd \gset
update docs set meta = '{"a": 3}' where id = 1;
update docs set body = body || '!' where id = 2;
select t.eq((select count(*) from _gnomon.blob), 2::bigint, 'identical large values share one blob');
select gnomon.use('main', :'cd');
select t.eq((select length(body) from docs where id = 2), 12000, 'large value rebuilt from the blob store');
select gnomon.use('main');

-- ticks and timestamps; tags
select gnomon.heartbeat();
select pg_sleep(0.01);
update acc set note = 'tick test' where id = 2;
select gnomon._do_tick(true);
select t.ok(exists (select 1 from gnomon.tick), 'ticks recorded');
insert into gnomon.tag(name, coord) values ('before-tag-change', gnomon.coordinate());
update acc set note = 'after tag' where id = 2;
select gnomon.use('main', 'tag:before-tag-change');
select t.eq((select note from acc where id = 2), 'tick test', 'as-of a tag');
select gnomon.use('main', (select (at + interval '1 microsecond')::text from gnomon.tick order by id desc limit 1));
select t.eq((select note from acc where id = 2), 'tick test', 'as-of a timestamp resolves to the latest tick');
select gnomon.use('main');
select t.fails($$select gnomon.resolve_coord('2001-01-01')$$, null, 'timestamps before the first tick are rejected');

-- writes are refused while as_of is set
select gnomon.use('main', gnomon.coordinate_text());
select t.fails($$update acc set note = 'x' where id = 2$$, '25006', 'as-of is read-only');
select gnomon.use('main');

-- commit log: attribution only when set
begin;
select gnomon.note('alice', 'fix typo');
update acc set note = 'attributed' where id = 2;
commit;
select t.eq((select actor from gnomon.xact order by at desc limit 1), 'alice', 'commit log actor');
select t.ok((select count(*) from gnomon.history('acc', '{"id": 2}')) > 1, 'row history');
select t.eq((select actor from gnomon.blame('acc', '{"id": 2}') where col = 'note'), 'alice', 'blame finds who last changed a field');
select t.ok((select at from gnomon.blame('acc', '{"id": 2}') where col = 'note') = (select at from gnomon.xact where actor = 'alice'),
            'blame''s time comes from the commit log when there is one');
-- the commit log is per epoch: a row an older cluster left for the xid a new transaction gets
-- (xids restart after a restore) is not that transaction's
insert into gnomon.xact(epoch, xid, actor) values (gnomon.current_epoch() - 1, (pg_current_xact_id()::text::int8 + 1)::text::xid8, 'from another cluster');
begin;
select gnomon.note('bob');
update acc set note = 'by bob' where id = 3;
commit;
select t.eq((select h.actor from gnomon.history('acc', '{"id": 3}') h order by h.vkey desc limit 1), 'bob', 'a commit-log row of another epoch is never attached');

-- untracked tables have no overhead and get pass-through routing views
create table plain (id int primary key);
select t.ok(not exists (select 1 from pg_trigger where tgrelid = 'plain'::regclass and not tgisinternal), 'untracked tables get no triggers');
select t.ok(to_regclass('gnomon_r_public.plain') is not null, 'pass-through view created by the DDL event trigger');

-- DDL on a tracked table re-syncs storage and views
alter table acc add column extra int default 7;
update acc set extra = 8 where id = 2;
select t.eq((select extra from gnomon_r_public.acc where id = 2), 8, 'new column visible through routing view after DDL');
select gnomon.coordinate_text() as cx \gset
alter table acc rename column note to remark;
update acc set remark = 'renamed' where id = 2;
select gnomon.use('main', :'cx');
select t.eq((select remark from acc where id = 2), 'attributed', 'renamed column keeps its history');
select gnomon.use('main');
select t.ok((select count(*) from gnomon.doctor() where status = 'error') = 0, 'doctor reports no errors');

-- the feed's row images (rebuilt inline) are the per-version images, new and old, on plain,
-- wide-key and large-value tables
do $$
declare t gnomon.tracked; bad bigint; n bigint;
begin
  for t in select * from gnomon.tracked where relname in ('acc', 'wide', 'docs') loop
    execute format($q$
      with ch as (select * from gnomon.changes(gnomon.coord_text(%3$L::gnomon.coord), null, array[%1$L::regclass]))
      select count(*), count(*) filter (where
               ch.new is distinct from (case when ch.op = 'delete' then null else %2$s(%4$s, ch.vkey, ch.vlsn) end)
               or ch.old is distinct from (select %2$s(%4$s, p.gn_key, p.gn_lsn) from %5$s p
                                            where %6$s and (p.gn_key, p.gn_lsn) < (ch.vkey, ch.vlsn)
                                            order by p.gn_key desc, p.gn_lsn desc limit 1))
        from ch$q$,
      t.rel, _gnomon.obj(t, 'vrow'), t.track_coord,
      case when t.wide_key then format('(select jsonb_build_object(''gn_rid'', i.gn_rid) from %s i where %s)', _gnomon.obj(t, 'id'),
                                        (select string_agg(format('i.%1$I = (ch.key ->> %1$L)::%2$s', k, format_type(a.atttypid, a.atttypmod)), ' and ')
                                           from unnest(t.key_cols) k join pg_attribute a on a.attrelid = t.rel and a.attname = k))
           else 'ch.key' end,
      _gnomon.obj(t, 'v'),
      case when t.wide_key then format('p.gn_rid = (select i.gn_rid from %s i where %s)', _gnomon.obj(t, 'id'),
                                        (select string_agg(format('i.%1$I = (ch.key ->> %1$L)::%2$s', k, format_type(a.atttypid, a.atttypmod)), ' and ')
                                           from unnest(t.key_cols) k join pg_attribute a on a.attrelid = t.rel and a.attname = k))
           else (select string_agg(format('p.%1$I = (ch.key ->> %1$L)::%2$s', k, format_type(a.atttypid, a.atttypmod)), ' and ')
                   from unnest(t.key_cols) k join pg_attribute a on a.attrelid = t.rel and a.attname = k) end)
      into n, bad;
    perform t.ok(n > 0, 'feed has changes for ' || t.relname);
    perform t.eq(bad, 0::bigint, 'feed images equal the per-version images for ' || t.relname);
  end loop;
end $$;
