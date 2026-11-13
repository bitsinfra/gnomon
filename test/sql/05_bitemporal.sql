-- Valid time. Change points, as-of on two axes, corrections, scheduled changes.

create table price (sku text primary key, amount numeric not null, currency text not null default 'USD');
insert into price values ('A', 10), ('B', 20), ('C', 30);
select gnomon.track('price', mode => 'bitemporal');

-- a normal write is valid from now
update price set amount = 11 where sku = 'A';
select gnomon.coordinate_text() as k1 \gset
select now() as v1 \gset
select pg_sleep(0.02);

-- a write dated in the past (valid_from) is a backdated change point
begin;
set local gnomon.valid_from = '2026-01-01';
update price set amount = 9 where sku = 'B';
commit;
select t.eq((select amount from price where sku = 'B'), 9::numeric, 'backdated change applies to main now');

-- valid-time reads
select gnomon.use('main');
set gnomon.valid_at = '2025-06-01';
select t.eq((select amount from gnomon_r_public.price where sku = 'B'), 20::numeric, 'before the backdated point: the baseline');
set gnomon.valid_at = '2026-06-01';
select t.eq((select amount from gnomon_r_public.price where sku = 'B'), 9::numeric, 'after the backdated point');
reset gnomon.valid_at;

-- a scheduled change: stored now, exact at once for time-aware reads, main catches up at its time
begin;
select (now() + interval '2 seconds')::text as due \gset
set local gnomon.valid_from = :'due';
update price set amount = 99 where sku = 'C';
commit;
select t.eq((select amount from price where sku = 'C'), 30::numeric, 'scheduled change not yet on main');
select set_config('gnomon.valid_at', (now() + interval '1 hour')::text, false);
select t.eq((select amount from gnomon_r_public.price where sku = 'C'), 99::numeric, 'scheduled change visible to valid_at >= its time');
reset gnomon.valid_at;
select pg_sleep(2.1);
select gnomon.heartbeat(false, false);
select t.eq((select amount from price where sku = 'C'), 99::numeric, 'the ticker applied the scheduled change');

-- a scheduled change that came due before the ticker ran: the next write to the row applies on
-- top of it, so it is not lost (main catches up at its time or on the next write)
insert into price values ('D', 40);
begin;
select (now() + interval '1 second')::text as due2 \gset
set local gnomon.valid_from = :'due2';
update price set amount = 44, currency = 'EUR' where sku = 'D';
commit;
select pg_sleep(1.1);
update price set currency = 'GBP' where sku = 'D';   -- before any heartbeat
select now() as after_gbp \gset
select t.eq((select (amount, currency) from price where sku = 'D'), row(44::numeric, 'GBP'::text), 'the next write catches the row up, its own change on top');
set gnomon.valid_at = 'infinity';
select t.eq((select (amount, currency) from gnomon_r_public.price where sku = 'D'), row(44::numeric, 'GBP'::text), 'and valid-time reads from now on agree');
reset gnomon.valid_at;
select gnomon.heartbeat(false, false);
select t.eq((select (amount, currency) from price where sku = 'D'), row(44::numeric, 'GBP'::text), 'the ticker has nothing left to undo');

-- a correction that covers now changes main now, in its own transaction
begin;
select gnomon.correct('price', '{"sku": "D"}', :'after_gbp', null, '{"amount": 45}');
select t.eq((select amount from price where sku = 'D'), 45::numeric, 'a correction covering now updates main');
commit;
select t.eq((select amount from price where sku = 'D'), 45::numeric, 'and it stays');

-- a correction for [a, b): a point at a, one at b restoring, retractions in between
update price set amount = 12 where sku = 'A';
select gnomon.coordinate_text() as kc \gset
select gnomon.correct('price', '{"sku": "A"}', '2025-01-01', '2025-12-31', '{"amount": 7}');
set gnomon.valid_at = '2025-06-01';
select t.eq((select amount from gnomon_r_public.price where sku = 'A'), 7::numeric, 'corrected interval');
set gnomon.valid_at = '2026-03-01';
select t.eq((select amount from gnomon_r_public.price where sku = 'A'), 10::numeric, 'state restored at the end of the interval');
reset gnomon.valid_at;
select t.eq((select amount from price where sku = 'A'), 12::numeric, 'a correction in the past leaves main now alone');

-- a correction never changes any as-of-known read before it (9, bitemporal properties)
select gnomon.use('main', :'kc');
set gnomon.valid_at = '2025-06-01';
select t.eq((select amount from gnomon_r_public.price where sku = 'A'), 10::numeric, 'known before the correction: the old belief');
reset gnomon.valid_at;
select gnomon.use('main');

-- deletes are change points too
begin;
set local gnomon.valid_from = '2027-01-01';
delete from price where sku = 'B';
commit;
select t.ok(exists (select 1 from price where sku = 'B'), 'a future delete is scheduled');
set gnomon.valid_at = '2027-06-01';
select t.ok(not exists (select 1 from gnomon_r_public.price where sku = 'B'), 'future delete visible to future reads');
reset gnomon.valid_at;

-- known-time tables ignore valid_at
create table plainv (id int primary key, v int);
insert into plainv values (1, 1);
select gnomon.track('plainv');
set gnomon.valid_at = '2000-01-01';
select t.eq((select v from gnomon_r_public.plainv where id = 1), 1, 'known-time table ignores valid_at');
reset gnomon.valid_at;

-- branches of a bitemporal table read and write in known time
select gnomon.create_branch('bt');
select gnomon.use('bt');
update price set amount = 1 where sku = 'A';
select t.eq((select amount from price where sku = 'A'), 1::numeric, 'branch write on a bitemporal table');
select gnomon.use('main');
select t.eq((select amount from price where sku = 'A'), 12::numeric, 'main unaffected');

-- key changes: the old key's timeline ends and the new one's starts at the change
create table rate (code text primary key, v int not null);
insert into rate values ('x', 1), ('y', 2);
select gnomon.track('rate', mode => 'bitemporal');
select now() as before_kc \gset
select pg_sleep(0.01);
update rate set code = 'x2' where code = 'x';
select t.eq((select string_agg(code, ',' order by code) from rate), 'x2,y', 'the key changed on main');
set gnomon.valid_at = :'before_kc';
select t.eq((select string_agg(code || ':' || v, ',' order by code) from gnomon_r_public.rate), 'x:1,y:2', 'before the change: the old key');
reset gnomon.valid_at;
select t.eq((select string_agg(code || ':' || v, ',' order by code) from gnomon_r_public.rate), 'x2:1,y:2', 'after it: the new key');
select t.fails($$update rate set code = 'y' where code = 'x2'$$, '23505', 'a key change onto an existing key');
-- a future-dated key change schedules both halves
select (now() + interval '1 second')::text as kc_at \gset
begin;
select set_config('gnomon.valid_from', :'kc_at', true);
update rate set code = 'y2' where code = 'y';
commit;
select t.eq((select string_agg(code, ',' order by code) from rate), 'x2,y', 'not yet on main');
select set_config('gnomon.valid_at', (:'kc_at'::timestamptz + interval '1 hour')::text, false);
select t.eq((select string_agg(code || ':' || v, ',' order by code) from gnomon_r_public.rate), 'x2:1,y2:2', 'visible to reads after its time');
reset gnomon.valid_at;
select pg_sleep(1.2);
select gnomon.apply_scheduled();
select t.eq((select string_agg(code, ',' order by code) from rate), 'x2,y2', 'applied together when due');
