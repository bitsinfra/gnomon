-- Shared-memory watermarks and the C read context.
create table wm (id int primary key, v int not null);
insert into wm select g, g from generate_series(1, 100) g;
select gnomon.track('wm');                       -- BRIN key index: no right edge to probe in SQL
select gnomon.use_c_trigger('wm');
select id as tid from gnomon.tracked where rel = 'wm'::regclass \gset
create function burn() returns void language plpgsql as $$ begin perform pg_current_xact_id(); end $$;
-- the watermark starts above every key already written
select t.ok(not _gnomon.c_unchanged_since(:tid, gnomon._kxmin(gnomon.coordinate())), 'a new watermark is not below a current coordinate');
select burn(); select burn(); select burn();
-- a transaction elsewhere in the cluster holds a coordinate's xmin back: the heartbeat worker's
-- tick, which this file's DDL wakes, can be in flight from before the watermark started
do $$ begin
  for i in 1..300 loop
    exit when not exists (select from pg_snapshot_xip(pg_current_snapshot()));
    perform pg_sleep(0.01);
  end loop;
end $$;
select gnomon.coordinate_text() as c1 \gset
select t.ok(_gnomon.c_unchanged_since(:tid, gnomon._kxmin(gnomon.coord(:'c1'))), 'unchanged since a coordinate taken after the start');
update wm set v = -1 where id = 1;
select t.ok(not _gnomon.c_unchanged_since(:tid, gnomon._kxmin(gnomon.coord(:'c1'))), 'a C-trigger write moves the watermark');
select gnomon.use('main', :'c1');
select t.eq((select v from wm where id = 1), 1, 'the past read rebuilds the changed row');
select gnomon.use('main');
select burn(); select burn();
select gnomon.coordinate_text() as c2 \gset
select t.ok(_gnomon.c_unchanged_since(:tid, gnomon._kxmin(gnomon.coord(:'c2'))), 'unchanged again after the write');
select gnomon.use('main', :'c2');
select t.eq((select v from wm where id = 1), -1, 'a past read on an unchanged table reads the current row');
select t.eq((select count(*) from wm), 100::bigint, 'all rows');
select gnomon.use('main');
-- the PL/pgSQL trigger does not move the watermark, so it is not used while that trigger is on
select gnomon.use_c_trigger('wm', false);
update wm set v = -2 where id = 2;
select t.ok(not _gnomon.c_unchanged_since(:tid, gnomon._kxmin(gnomon.coord(:'c2'))), 'not used with the PL/pgSQL trigger');
select gnomon.use('main', :'c2');
select t.eq((select v from wm where id = 2), 2, 'past read correct under the PL/pgSQL trigger');
select gnomon.use('main');
-- back on the C trigger: a new trigger restarts the watermark above the PL/pgSQL writes
select gnomon.use_c_trigger('wm');
select t.ok(not _gnomon.c_unchanged_since(:tid, gnomon._kxmin(gnomon.coord(:'c2'))), 'a replaced trigger restarts the watermark');
select gnomon.use('main', :'c2');
select t.eq((select v from wm where id = 2), 2, 'and past reads stay correct');
select gnomon.use('main');
-- the C read context: the same answers as the SQL core
select gnomon.create_branch('wmb');
select gnomon.use('wmb');
update wm set v = 77 where id = 3;
select t.eq((select v from wm where id = 3), 77, 'branch read through the C context');
set gnomon.c_substitute = off;
select t.eq((select v from wm where id = 3), 77, 'the same read through the SQL context');
reset gnomon.c_substitute;
select gnomon.use('main');
select t.eq((select v from wm where id = 3), 3, 'main unaffected');
