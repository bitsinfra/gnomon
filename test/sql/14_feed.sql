-- The feed with row images, none/new/both, and the set-based rebuild equal to the
-- probes row for row: across partitions, deletes, key changes, re-inserts, a column added after
-- tracking, values in the blob store and wide keys.
create table ev (id int primary key, a int, b text, c jsonb);
insert into ev select g, g, 'b' || g, jsonb_build_object('g', g) from generate_series(1, 40) g;
select gnomon.track('ev', part_span => greatest(50, pg_current_xact_id()::text::int8 / 500000 + 1));   -- small partitions, and large enough that a long-lived cluster's xids stay under the 999999 cap
create table wide (k1 text, k2 int, v int, primary key (k1, k2));
insert into wide select 'k' || g, g, g from generate_series(1, 10) g;
select gnomon.track('wide');   -- (a text and an int: a wide key, an internal id)
select gnomon.coordinate_text() as c0 \gset
create procedure t.feed_writes() language plpgsql as $$
begin
  for i in 1..30 loop
    update ev set a = a + 1 where id = 1 + (i * 7) % 40;
    update ev set b = repeat('x', 3000) || i where id = 1 + (i * 11) % 40;   -- the blob store
    if i % 7 = 0 then delete from ev where id = i; end if;
    if i % 9 = 0 then insert into ev values (i, -i, 'again', null) on conflict do nothing; end if;
    if i % 10 = 0 then update ev set id = id + 1000 where id = 40 - i; end if;
    update wide set v = v + i where k2 = 1 + i % 10;
    commit;
    -- spread the xids over partitions: a share of the span, so this holds whatever the span is
    for j in 1..(select part_span / 4 from gnomon.tracked where rel = 'ev'::regclass) loop perform pg_current_xact_id(); commit; end loop;
  end loop;
end $$;
call t.feed_writes();
alter table ev add column d int default 7;
update ev set d = 8, a = 0 where id between 2 and 6;
delete from wide where k2 = 3;
select gnomon.set('feed_setbased_min', '0');
create temp table probe as select * from gnomon.changes(:'c0', null, null, 'both');
create temp table probe_new as select * from gnomon.changes(:'c0', null, null, 'new');
select gnomon.set('feed_setbased_min', '1');
create temp table setb as select * from gnomon.changes(:'c0', null, null, 'both');
create temp table setb_new as select * from gnomon.changes(:'c0', null, null, 'new');
-- with the C module and feed_c = on, large windows go to its arm: equal to the SQL
-- set-based arm (without the module the setting changes nothing)
select gnomon.set('feed_c', 'on');
create temp table setc as select * from gnomon.changes(:'c0', null, null, 'both');
create temp table setc_new as select * from gnomon.changes(:'c0', null, null, 'new');
select gnomon.set('feed_c', 'off');
select t.eq((select count(*) from (select * from setc except all select * from setb) x)
          + (select count(*) from (select * from setb except all select * from setc) x), 0::bigint, 'the C arm equals the SQL set-based arm');
select t.eq((select count(*) from (select * from setc_new except all select * from setb_new) x)
          + (select count(*) from (select * from setb_new except all select * from setc_new) x), 0::bigint, 'with the new image only too');
select t.ok((select count(*) from probe) > 90, 'a window of a hundred changes');
select t.ok((select count(distinct gn_part) from _gnomon.ev__v) > 3, 'several partitions');
select t.eq((select count(*) from (select * from probe except all select * from setb) x), 0::bigint, 'set-based equals the probes (both images)');
select t.eq((select count(*) from (select * from setb except all select * from probe) x), 0::bigint, 'and nothing more');
select t.eq((select count(*) from (select * from probe_new except all select * from setb_new) x), 0::bigint, 'new image only, equal too');
select t.ok(not exists (select 1 from setb_new where old is not null), 'new only carries no old image');
select t.eq((select count(*) from probe_new where new is distinct from (select p.new from probe p where p.vkey = probe_new.vkey and p.vlsn = probe_new.vlsn and p.key = probe_new.key)), 0::bigint,
            'new images are the same in both modes');
select t.eq((select count(*) from gnomon.changes(:'c0', null, null, false) where new is not null), 0::bigint, 'images => false still means none');
select t.fails($$select * from gnomon.changes('now', null, null, 'some')$$, '22023', 'an unknown mode');
select t.ok(exists (select 1 from setb where tbl = 'wide'::regclass and op = 'delete' and old ->> 'v' is not null), 'wide keys: a delete carries its old image');
select t.ok(exists (select 1 from setb where length(new ->> 'b') > 3000), 'blob values are rebuilt');
select t.ok(exists (select 1 from setb where (new ->> 'd')::int = 8), 'a column added after tracking');
