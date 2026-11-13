-- Pieces no other test covers: notification targets, gnomon.done() and idle reviews, comments
-- anchored to rows and waiting for a review, auto-rebase per branch, and the deterministic masks a masked export needs.
create table acct (id int primary key, email text, v int);
insert into acct select g, 'u' || g || '@x.io', g from generate_series(1, 10) g;
select gnomon.track('acct');

-- notification targets: a webhook target's events are queued for the job loop
select gnomon.add_notify_target('hook', 'webhook', '{"url": "http://127.0.0.1:9/x"}');
select gnomon.add_notify_target('chan', 'channel', '{"channel": "gt_review"}');
select gnomon.create_branch('w1');
select gnomon.use('w1');
update acct set v = 100 where id = 1;
select gnomon.done('Raised v of 1') as cr \gset
select t.ok(:cr > 0, 'done() opens a change request');
select t.eq((select title from gnomon.change_request where id = :cr), 'Raised v of 1', 'titled by its summary');
select t.eq(gnomon.done('one more thing'), :cr::bigint, 'done() again is the same request');
select t.eq((select body from gnomon.review_comment where cr = :cr), 'one more thing', 'and its summary a comment');
select t.eq((select count(*) from gnomon.notification where target = 'hook' and event = 'change_request'), 1::bigint, 'a webhook target gets the event queued');
select t.ok((select payload ->> 'text' from gnomon.notification where target = 'hook') = format('change request %s on w1: 1 table(s), 1 row(s)', :cr), 'with a line a person reads');
select gnomon.use('main');
select t.fails('select gnomon.done()', null, 'done() is for a branch');

-- comments anchored to a field; resolving one
select gnomon.comment(:cr, 'why 100?', 'acct', '{"id": 1}', 'v') as cm \gset
select t.eq((select col from gnomon.review_comment where id = :cm), 'v', 'a comment on a field');
select t.eq((select tbl from gnomon.review_comment where id = :cm), 'acct'::regclass, 'of a table');
select gnomon.resolve_comment(:cm);
select t.ok((select resolved_by is not null from gnomon.review_comment where id = :cm), 'resolved');
select t.fails('select gnomon.resolve_comment(-1)', '42704', 'an unknown comment');
select t.fails('select gnomon.comment(-1, ''x'')', '42704', 'an unknown change request');
select t.ok(jsonb_array_length(gnomon.change_request_status(:cr) -> 'comments') >= 2, 'the status document carries the comments');

-- waiting: a timeout returns the status; a merged request returns at once
select t.eq((gnomon.wait_for_review(:cr, '0 seconds') ->> 'id')::bigint, :cr::bigint, 'a wait that times out returns the status');
drop role if exists gt_rev;
create role gt_rev;
grant gnomon_merger to gt_rev;
set role gt_rev;
select gnomon.review(:cr, 'approve');
reset role;
select t.eq((gnomon.wait_for_review(:cr, '0 seconds') -> 'reviews' -> 0 ->> 'verdict'), 'approve', 'the status shows the review');
select gnomon.merge('w1');
drop role gt_rev;
select clock_timestamp() as t0 \gset
select gnomon.wait_for_review(:cr, '30 seconds');
select t.ok(clock_timestamp() - :'t0'::timestamptz < interval '5 seconds', 'a merged request ends the wait');

-- idle reviews: an assigned branch with changes, idle long enough, gets a change request
drop role if exists gt_idle;
create role gt_idle login;
select gnomon.create_branch('w2');
select gnomon.assign('gt_idle', 'w2');
select gnomon.use('w2');
update acct set v = 200 where id = 2;
select gnomon.use('main');
update gnomon.branch set last_used = now() - interval '2 hours' where name = 'w2';
select t.eq(gnomon._idle_reviews(), 0, 'off by default');
select gnomon.set('idle_review_after', '1 hour');
select t.eq(gnomon._idle_reviews(), 1, 'an idle assigned branch with changes gets a change request');
select t.eq(gnomon._idle_reviews(), 0, 'once');
select t.eq((select opened_by from gnomon.change_request where branch = (select id from gnomon.branch where name = 'w2')), 'gt_idle', 'in the role''s name');
select t.eq((select count(*) from gnomon.notification where target = 'hook'), 2::bigint, 'and the target hears of it');
select gnomon.unassign('gt_idle');
drop role gt_idle;

-- auto-rebase per branch: an idle branch behind main is rebased when its option allows
select gnomon.create_branch('ar');
select gnomon.set_auto_rebase('ar', 'clean');
select gnomon.set('warn_changes_since_base', '3');
select gnomon.watch();   -- (the first watch only sets its starting point)
update acct set v = v + 1 where id between 5 and 10;
select gnomon.watch();
update gnomon.branch set last_used = now() - interval '1 hour' where name = 'ar';
select t.eq(gnomon.auto_rebase_branches(), 1, 'an idle branch behind main is rebased');
select gnomon.use('ar');
select t.eq((select v from acct where id = 5), 6, 'it reads main''s new rows');
update acct set v = -1 where id = 6;
select gnomon.use('main');
select t.eq(gnomon.auto_rebase_branches(), 0, 'not again: it is no longer behind');
update acct set v = v + 1 where id between 5 and 10;
select gnomon.watch();
update gnomon.branch set last_used = now() - interval '1 hour' where name = 'ar';
select t.eq(gnomon.auto_rebase_branches(), 0, 'clean leaves a branch whose rebase would conflict');
select gnomon.set_auto_rebase('ar', 'always');
select t.eq(gnomon.auto_rebase_branches(), 1, 'always rebases it anyway');
update gnomon.branch set last_used = now() where name = 'ar';
select t.fails($$select gnomon.set_auto_rebase('ar', 'sometimes')$$, null, 'modes are off, clean and always');

-- deterministic masks
select t.eq(gnomon.mask_hash('a', 's'), gnomon.mask_hash('a', 's'), 'mask_hash is deterministic');
select t.ok(gnomon.mask_hash('a', 's') <> gnomon.mask_hash('a', 't'), 'and salted');
select t.ok(gnomon.mask_email('u1@x.io') like '%@example.invalid' and gnomon.mask_email('u1@x.io') = gnomon.mask_email('u1@x.io'), 'an email stays an email');
select t.eq(gnomon.mask_int(42, 'k'), gnomon.mask_int(42, 'k'), 'mask_int too');
select t.ok(gnomon.mask_int(42) <> 42 and gnomon.mask_int(null) is null and gnomon.mask_hash(null) is null, 'and null stays null');
select gnomon.create_mask_profile('dev');
select gnomon.add_mask_rule('dev', 'acct', 'id', 'id + 1000');
select t.ok(exists (select 1 from gnomon.doctor() where check_name like 'mask dev %acct.id' and status = 'warn'), 'doctor warns of a key masked by a non-deterministic expression');

-- the commit log for an ordinary role: its own transactions, and merges of branches it may read;
-- not main's other writers (gnomon.xact is for gnomon's roles)
begin;
select gnomon.note('admin', 'an admin fix');
update acct set v = v + 1 where id = 4;
commit;
drop role if exists gt_plain;
create role gt_plain;
grant select, update on acct to gt_plain;
set role gt_plain;
begin;
select gnomon.note('plain', 'a fix');
update acct set v = v + 1 where id = 3;
commit;
select t.ok(exists (select 1 from gnomon.log() where who = 'gt_plain' and reason = 'a fix'), 'an ordinary role reads its own commits');
select t.ok(not exists (select 1 from gnomon.log() where kind = 'commit' and who <> 'gt_plain'), 'not other writers of main');
select t.ok(not exists (select 1 from gnomon.log() where reason = 'an admin fix'), 'such as the admin''s fix');
select t.ok(exists (select 1 from gnomon.log() where kind = 'merge applied'), 'and merges of branches it may read');
reset role;
select t.ok(exists (select 1 from gnomon.log() where reason = 'an admin fix') and exists (select 1 from gnomon.log() where who = 'gt_plain'), 'a superuser reads every commit');
drop owned by gt_plain;
drop role gt_plain;
