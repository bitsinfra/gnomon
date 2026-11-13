-- History management and operations: ledger, retention and thinning, dropping
-- partitions, erasure, epochs, tables that already use RLS, doctor.

create table ev (id int primary key, who text, what text, n int);
insert into ev select g, 'u' || g, 'init', 0 from generate_series(1, 20) g;
-- (small partitions, but never so small that a long-lived cluster's xids saturate the partition number)
select gnomon.track('ev', part_span => greatest(50, pg_current_xact_id()::text::int8 / 500000 + 1));

-------------------------------------------------------------------------------
-- tamper-evident ledger
update ev set n = n + 1 where id <= 10;
select t.ok(gnomon.seal_ledger() is not null, 'first block sealed');
update ev set what = 'second' where id between 5 and 15;
delete from ev where id = 20;
select t.ok(gnomon.seal_ledger() is not null, 'second block sealed');
select t.ok((select bool_and(ok) from gnomon.verify_ledger()), 'ledger verifies');
select t.eq((select count(*) from gnomon.ledger_digest()), 2::bigint, 'digest lists blocks');
-- tampering with a sealed version is detected
update _gnomon.ev__v set gn_c2 = 999 where id = 3 and gn_c2 = 1;
select t.ok(not (select bool_and(ok) from gnomon.verify_ledger()), 'tampered version detected');
update _gnomon.ev__v set gn_c2 = 1 where id = 3 and gn_c2 = 999;
select t.ok((select bool_and(ok) from gnomon.verify_ledger()), 'ledger verifies again after repair');

-------------------------------------------------------------------------------
-- erasure rewrites history, records hashes, and keeps the ledger valid
select gnomon.coordinate_text() as before_erase \gset
select gnomon.erase('ev', '{"id": 7}', array['who'], 'GDPR request 42');
select t.eq((select who from ev where id = 7), null::text, 'erased in the current table');
select gnomon.use('main', :'before_erase');
select t.eq((select who from ev where id = 7), null::text, 'erased in history');
select gnomon.use('main');
select t.ok(not exists (select 1 from gnomon.changes((select gnomon.coord_text(track_coord) from gnomon.tracked where rel = 'ev'::regclass))
                        where key = '{"id": 7}' and new ->> 'who' is not null), 'no version still holds the erased value');
select t.ok((select bool_and(ok) from gnomon.verify_ledger()), 'ledger still verifies after erasure');
select t.ok(exists (select 1 from gnomon.erasure where reason = 'GDPR request 42'), 'erasure marker recorded');
-- an erased row's other values are still checked: tampering with them is found
select t.ok(exists (select 1 from _gnomon.ev__v where id = 7 and gn_c1 is not null), 'the erased row has other history');
update _gnomon.ev__v set gn_c1 = 'forged' where id = 7 and gn_c1 = 'second';
select t.ok(not (select bool_and(ok) from gnomon.verify_ledger()), 'tampering with an erased row''s other columns is detected');
update _gnomon.ev__v set gn_c1 = 'second' where id = 7 and gn_c1 = 'forged';
select t.ok((select bool_and(ok) from gnomon.verify_ledger()), 'and verifies once repaired');

-- ordinary DDL and session settings do not make sealed history look tampered with
create table ld (id int primary key, amount numeric, at timestamptz, note text);
insert into ld values (1, 1.50, '2026-01-01 10:00+00', 'a'), (2, 2.25, '2026-02-01 10:00+00', repeat('x', 3000));
select gnomon.track('ld');
update ld set amount = amount * 2, note = note || '!';
delete from ld where id = 2;
select gnomon.seal_ledger();
set timezone = 'Asia/Tokyo';
select t.ok((select bool_and(ok) from gnomon.verify_ledger()), 'verifies under another time zone');
reset timezone;
alter table ld rename column note to memo;
select t.ok((select bool_and(ok) from gnomon.verify_ledger()), 'verifies after a column rename');
alter table ld add column flag bool not null default true;
select t.ok((select bool_and(ok) from gnomon.verify_ledger()), 'verifies after adding a column with a default');
alter table ld drop column at;
select t.ok((select bool_and(ok) from gnomon.verify_ledger()), 'verifies after dropping a column');
alter table ld rename to ledgered;
select t.ok((select bool_and(ok) from gnomon.verify_ledger()), 'verifies after renaming the table');
update _gnomon.ld__v set gn_c0 = 99 where id = 1 and gn_c0 = 3.00;
select t.ok(not (select bool_and(ok) from gnomon.verify_ledger()), 'and still finds tampering after the DDL');
update _gnomon.ld__v set gn_c0 = 3.00 where id = 1 and gn_c0 = 99;
select t.ok((select bool_and(ok) from gnomon.verify_ledger()), 'repaired');

-------------------------------------------------------------------------------
-- retention: keep what is visible at retained coordinates, materialize kept deltas
create table r (id int primary key, v int);
insert into r select g, 0 from generate_series(1, 5) g;
select gnomon.track('r', part_span => greatest(8, pg_current_xact_id()::text::int8 / 500000 + 1));   -- small partitions: the old ones are rewritten, the current one thinned in place
-- each bump also burns half a partition span of xids, so the versions spread over partitions
create procedure t.bump(n int) language plpgsql as $$
begin
  for i in 1..n loop
    update r set v = v + 1; commit; perform gnomon._do_tick(true); commit;
    for j in 1..(select part_span / 2 from gnomon.tracked where rel = 'r'::regclass) loop perform pg_current_xact_id(); commit; end loop;
  end loop;
end $$;
call t.bump(5);
select gnomon.create_branch('old-fork');            -- forked before the horizon below
select gnomon.coordinate_text() as mid_c \gset
call t.bump(3);
select gnomon.feed_create('late', gnomon.coordinate_text());   -- a consumer behind the horizon
call t.bump(2);
-- a tick that sees every bump: a transaction running elsewhere in the cluster (the C module's
-- heartbeat worker, another test) holds a coordinate's xmin back, and retention rightly keeps
-- every version at or above it, so wait (up to 5 s) until nothing else is running
create procedure t.quiesce() language plpgsql as $$
begin
  for i in 1..100 loop
    exit when not exists (select 1 from pg_snapshot_xip(pg_current_snapshot()));
    perform pg_sleep(0.05);
    commit;
  end loop;
  perform gnomon._do_tick(true);
  commit;
end $$;
call t.quiesce();
-- pretend the history is old: move the ticks back in time
update gnomon.tick set at = at - interval '40 days';
select gnomon._do_tick(true);
select gnomon.coordinate_text() as recent \gset
update r set v = 100 where id = 1;
insert into gnomon.tag(name, coord) values ('keep-me', (select coord from gnomon.tick order by id offset 3 limit 1));
select count(*) as vbefore from _gnomon.r__v \gset
select gnomon.set_retention('r', '{"keep_all": "30 days"}');
select gnomon.seal_ledger();   -- (the heartbeat seals each tick; unsealed history is kept)
select gnomon.apply_retention('r') as ret \gset
select count(*) as vafter from _gnomon.r__v \gset
select t.ok(:vafter < :vbefore, 'retention removed versions');
select t.ok((:'ret'::jsonb -> 'public.r' ->> 'partitions_rewritten')::int >= 1, 'thinned partitions are rewritten and swapped in: ' || :'ret');
select t.ok((select bool_and(exists (select 1 from pg_index x where x.indrelid = i.inhrelid))
               from pg_inherits i where i.inhparent = '_gnomon.r__v'::regclass), 'rewritten partitions have their indexes');
select gnomon.use('main', 'tag:keep-me');
select t.eq((select count(*) from r), 5::bigint, 'a tagged coordinate still reads exactly');
select gnomon.use('main', :'recent');
select t.eq((select v from r where id = 1), 10, 'reads after the horizon are exact');
select gnomon.use('main');
select t.eq((select v from r where id = 1), 100, 'current state intact');
select t.ok((select bool_and(ok) from gnomon.verify_ledger()), 'ledger verifies after thinning');
-- what still needs history keeps it: a branch's fork point, a consumer's changes
select t.ok(exists (select 1 from gnomon.history_pins() where kind = 'branch' and what = 'old-fork'), 'the branch pins its cutoff');
select gnomon.use('old-fork');
select t.eq((select v from r where id = 1), 5, 'a branch forked before the horizon still reads its fork point');
select gnomon.use('main');
select t.eq((select count(*) from gnomon.feed_poll('late', 1000) where tbl = 'r'::regclass), 11::bigint,
            'a consumer behind the horizon still gets every change since its position');
-- other coordinates below the horizon were thinned: reads there fail rather than guess
select gnomon.use('main', :'mid_c');
select t.fails('select * from r', '22023', 'a coordinate retention did not keep fails clearly');
select gnomon.use('main');

-------------------------------------------------------------------------------
-- dropping whole partitions, and reads past the horizon fail clearly
select gnomon.heartbeat();
select gnomon.coordinate_text() as old_c \gset
create procedure t.burn(cnt int) language plpgsql as $$
begin for i in 1..cnt loop update ev set n = n + 1 where id = 1; commit; end loop; end $$;
call t.burn(120);   -- burn xids past the partition span
select gnomon.heartbeat();
select pg_sleep(0.01);
select now() as cut \gset
update ev set n = 0 where id = 2;
select gnomon.heartbeat();
select gnomon.seal_ledger();
select t.fails(format('select gnomon.drop_history_before(%L, %L)', 'ev', :'cut'), '55000', 'history a branch still reads is not dropped');
select gnomon.drop_branch('old-fork');
select t.fails(format('select gnomon.drop_history_before(%L, %L)', 'ev', :'cut'), '55000', 'nor history a feed consumer has not read');
select gnomon.feed_drop('late');
select t.ok(gnomon.drop_history_before('ev', :'cut') >= 1, 'old partitions dropped');
select (retention ->> 'horizon_key')::int8 as hk1 from gnomon.tracked where rel = 'ev'::regclass \gset
select gnomon.drop_history_before('ev', now() - interval '10 years');
select t.eq((select (retention ->> 'horizon_key')::int8 from gnomon.tracked where rel = 'ev'::regclass), :hk1::int8, 'an earlier drop never lowers the horizon');
select gnomon.use('main', :'old_c');
select t.fails('select * from ev', '22023', 'reading before the horizon fails with a clear error');
select gnomon.use('main');
select t.ok((select count(*) from ev) = 19, 'current reads unaffected');

-------------------------------------------------------------------------------
-- epochs: a new system identifier (dump/restore, pg_upgrade) starts a new epoch
create table ep (id int primary key, v int);
insert into ep values (1, 1);
select gnomon.track('ep');
update ep set v = 2;
select gnomon.coordinate_text() as e1 \gset
update gnomon.epoch set sysid = sysid + 1;          -- as if this database was restored elsewhere
select set_config('gnomon._epoch', '', false);
update ep set v = 3;
select t.eq((select max(gn_key >> 48) from _gnomon.ep__v)::int, 2, 'new writes stamp the new epoch');
select gnomon.use('main', :'e1');
select t.eq((select v from ep where id = 1), 2, 'old-epoch coordinates still read their epoch exactly');
select gnomon.use('main', gnomon.coordinate_text());
select t.eq((select v from ep where id = 1), 3, 'new-epoch coordinates see older epochs as committed');
select gnomon.use('main');

-------------------------------------------------------------------------------
-- tables that already use RLS: the user's policies apply on branches too
drop role if exists gt_alice; drop role if exists gt_bob;
create role gt_alice login; create role gt_bob login;
create table note (id int primary key, owner name not null, body text);
alter table note enable row level security;
create policy own on note using (owner = current_user) with check (owner = current_user);
grant select, insert, update, delete on note to gt_alice, gt_bob;
insert into note values (1, 'gt_alice', 'a1'), (2, 'gt_bob', 'b1'), (3, 'gt_alice', 'a2');
select gnomon.track('note');
select t.ok((select user_rls from gnomon.tracked where rel = 'note'::regclass), 'existing RLS detected');
select t.ok(not exists (select 1 from pg_policy where polrelid = 'note'::regclass and polname = 'gnomon_all'), 'no permissive true policy added');
select gnomon.create_branch('rls');
set role gt_alice;
select t.eq((select count(*) from note), 2::bigint, 'main: user policy applies');
select gnomon.use('rls');
select t.eq((select count(*) from note), 2::bigint, 'branch: user policy applies to arm 1');
update note set body = 'a1 edited' where id = 1;
select t.eq((select count(*) from note), 2::bigint, 'branch: user policy applies to branch heads');
select gnomon.use('main');
reset role;
set role gt_bob;
select gnomon.use('rls');
select t.eq((select count(*) from note), 1::bigint, 'another role sees only its rows on the branch');
select t.ok(not exists (select 1 from note where body = 'a1 edited'), 'branch rows filtered by the user policy');
-- the user's write policies hold on a branch too: what main would refuse, the branch refuses
select t.fails($$insert into note values (10, 'gt_alice', 'forged')$$, '42501', 'branch insert checked against the user policy');
insert into note values (11, 'gt_bob', 'bob on a branch');
update note set body = 'not mine' where id = 1;
select gnomon.use('main');
reset role;
select gnomon.use('rls');
select t.eq((select body from note where id = 1), 'a1 edited', 'branch update of a row the policy hides is skipped');
select t.ok(exists (select 1 from note where id = 11), 'branch insert the policy allows');
select gnomon.use('main');

-- RLS enabled with no policies (deny-all): tracking must not open it
create table vault (id int primary key, secret text);
insert into vault values (1, 's1');
alter table vault enable row level security;
grant select, insert, update, delete on vault to gt_alice;
select gnomon.track('vault');
select t.ok((select user_rls from gnomon.tracked where rel = 'vault'::regclass), 'deny-all RLS detected');
select t.ok(not exists (select 1 from pg_policy where polrelid = 'vault'::regclass and polname = 'gnomon_all'), 'deny-all table not opened');
select gnomon.create_branch('vb');
set role gt_alice;
select t.eq((select count(*) from vault), 0::bigint, 'deny-all on main after tracking');
select gnomon.use('vb');
select t.eq((select count(*) from vault), 0::bigint, 'deny-all on a branch');
select t.fails($$insert into vault values (2, 'x')$$, '42501', 'deny-all refuses branch inserts');
select gnomon.use('main');
reset role;

-- policies added after tracking take over from gnomon's permissive policy
create table memo (id int primary key, owner name not null, body text);
insert into memo values (1, 'gt_alice', 'a'), (2, 'gt_bob', 'b');
grant select, insert, update, delete on memo to gt_alice, gt_bob;
select gnomon.track('memo');
select t.ok(not (select user_rls from gnomon.tracked where rel = 'memo'::regclass), 'no user RLS at first');
set role gt_alice;
select t.eq((select count(*) from memo), 2::bigint, 'everything visible before any policy');
reset role;
alter table memo enable row level security;
select t.ok((select user_rls from gnomon.tracked where rel = 'memo'::regclass), 'enabling RLS after tracking is the user''s RLS');
set role gt_alice;
select t.eq((select count(*) from memo), 0::bigint, 'RLS enabled without policies denies, as PostgreSQL does');
reset role;
create policy own on memo using (owner = current_user);
select t.ok(not exists (select 1 from pg_policy where polrelid = 'memo'::regclass and polname = 'gnomon_all'), 'no permissive policy beside the user''s');
select gnomon.create_branch('mb');
set role gt_alice;
select t.eq((select count(*) from memo), 1::bigint, 'a policy created after tracking applies on main');
select gnomon.use('mb');
select t.eq((select count(*) from memo), 1::bigint, 'a policy created after tracking applies on a branch');
select gnomon.use('main');
reset role;
-- turning the user's RLS off again: gnomon keeps RLS on for its own policies, reopened to all
drop policy own on memo;
alter table memo disable row level security;
select t.ok(not (select user_rls from gnomon.tracked where rel = 'memo'::regclass), 'disabling RLS ends the user''s RLS');
select t.ok((select relrowsecurity from pg_class where oid = 'memo'::regclass), 'gnomon re-enables RLS for its arm policies');
set role gt_alice;
select t.eq((select count(*) from memo), 2::bigint, 'everything visible again');
reset role;
-- untracking leaves the user's RLS as the user had it
select gnomon.untrack('vault');
select t.ok((select relrowsecurity from pg_class where oid = 'vault'::regclass), 'untrack keeps the user''s RLS enabled');
select gnomon.untrack('memo');
select t.ok(not (select relrowsecurity from pg_class where oid = 'memo'::regclass), 'untrack disables the RLS gnomon enabled');
select t.ok(not exists (select 1 from pg_policy where polrelid = 'memo'::regclass), 'untrack leaves no gnomon policies');
select t.ok(not exists (select 1 from pg_trigger where tgrelid = 'memo'::regclass and not tgisinternal), 'untrack leaves no triggers');
select t.ok(to_regclass('_gnomon.memo__v') is null and not exists (select 1 from pg_proc where proname like 'memo\_\_%'),
            'untrack drops the storage and generated functions');
select t.ok(not exists (select 1 from gnomon.tracked where rel = 'memo'::regclass)
            and (select c.relkind from pg_class c where c.oid = to_regclass('gnomon_r_public.memo')) = 'v',
            'an untracked table gets a pass-through view');
insert into memo values (3, 'x', 'plain again');   -- an ordinary table once more

-------------------------------------------------------------------------------
select t.ok((select count(*) from gnomon.doctor() where status = 'error') = 0, 'doctor reports no errors');
alter table ev disable trigger gnomon_v;
select t.ok((select tgenabled = 'A' from pg_trigger where tgrelid = 'ev'::regclass and tgname = 'gnomon_v'), 'DDL re-sync re-enables a disabled versioning trigger');
-- writes with triggers disabled are caught by doctor
-- (an ordinary ALTER TABLE re-syncs the table and re-enables the trigger, so bypass the hook)
set gnomon._in_ddl = '1';
alter table ev disable trigger gnomon_v;
update ev set what = 'sneaky' where id = 2;   -- a row whose history was not dropped above
alter table ev enable always trigger gnomon_v;
reset gnomon._in_ddl;
select t.ok(exists (select 1 from gnomon.doctor(100) where check_name = 'consistency public.ev' and status = 'error'), 'doctor catches unversioned writes');

select gnomon.sync('ev');   -- (the sneaky write's row is consistent again only in this test's eyes)

-- session_replication_role = replica does not bypass versioning (the trigger is ENABLE ALWAYS)
create table rr (id int primary key, v int);
insert into rr values (1, 1);
select gnomon.track('rr');
set session_replication_role = replica;
update rr set v = 2;
reset session_replication_role;
select t.eq((select count(*) from gnomon.history('rr', '{"id": 1}') where op = 'update'), 1::bigint, 'writes under session_replication_role = replica are versioned');

-- erasure reaches branch heads, branch history and the blob store too
create table er (id int primary key, secret text, big text);
insert into er values (1, 'top secret', repeat('s', 5000));
select gnomon.track('er');
update er set big = repeat('s', 5001) where id = 1;   -- versions on main, large values as blobs
select gnomon.create_branch('erb');
select gnomon.use('erb');
update er set secret = 'branch secret', big = repeat('b', 5000) where id = 1;
select gnomon.use('main');
select count(*) as blobs_before from _gnomon.blob \gset
select gnomon.erase('er', '{"id": 1}', array['secret', 'big'], 'test');
select t.ok(not exists (select 1 from _gnomon.er__b where secret is not null or big is not null), 'erasure reaches branch heads');
select t.ok(not exists (select 1 from _gnomon.er__bv where secret is not null or big is not null), 'erasure reaches branch history');
select t.ok((select count(*) from _gnomon.blob) < :blobs_before and not exists (select 1 from _gnomon.blob where v like 'sssss%'),
            'erasure removes the blob values no version references any more');

-- without event triggers (some providers), DDL is caught by the fingerprint: branch writes to the
-- changed table are refused until gnomon.sync()
create table fp (id int primary key, v int);
insert into fp values (1, 1);
select gnomon.track('fp');
select gnomon.create_branch('fpb');
insert into gnomon.setting(name, value) values ('event_triggers', 'off') on conflict (name) do update set value = excluded.value;
alter event trigger gnomon_ddl_start disable;
alter event trigger gnomon_ddl_end disable;
alter table fp add column w int;
select gnomon.use('fpb');
select t.fails($$update fp set v = 2 where id = 1$$, '55000', 'a changed table refuses branch writes until synced');
select gnomon.use('main');
select gnomon.sync('fp');
select gnomon.use('fpb');
update fp set v = 2, w = 5 where id = 1;
select t.eq((select (v, w) from fp where id = 1), row(2, 5), 'after gnomon.sync() the branch writes again, new column included');
select gnomon.use('main');
alter event trigger gnomon_ddl_start enable always;
alter event trigger gnomon_ddl_end enable always;
delete from gnomon.setting where name = 'event_triggers';

-- doctor states plainly that branch-per-request apps need the C module
select t.ok(current_setting('gnomon.c_module', true) = 'on'
            or exists (select 1 from gnomon.doctor() where detail like '%branch-per-request apps with concurrent writers need the C module%'),
            'doctor warns about the SQL-only DML gaps');

drop owned by gt_alice; drop owned by gt_bob; drop role gt_alice; drop role gt_bob;
