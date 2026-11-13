-- Change requests and checks, masked branches, held outbox, protected tables.

drop role if exists gt_author; drop role if exists gt_reviewer; drop role if exists gt_masked;
create role gt_author login; create role gt_reviewer login; create role gt_masked login;
grant gnomon_merger to gt_reviewer;

create table account (id int primary key, email text not null, ssn text, balance int not null default 0);
create table outbox (id bigserial primary key, topic text not null, payload jsonb not null);
insert into account select g, 'user' || g || '@x.io', '123-45-' || lpad(g::text, 4, '0'), 100 from generate_series(1, 10) g;
select gnomon.track('account'); select gnomon.track('outbox');
grant select, insert, update, delete on account, outbox to gt_author, gt_reviewer;
grant usage on all sequences in schema public to gt_author, gt_reviewer;

-------------------------------------------------------------------------------
-- change requests: approvals, and checks inside the merge transaction
select gnomon.add_check('no_negative_balance', 'select * from account where balance < 0');
select gnomon.add_check('has_accounts', 'select count(*) > 0 from account', 'true');

set role gt_author;
select gnomon.create_branch('pay');
select gnomon.use('pay');
update account set balance = balance - 30 where id = 1;
select gnomon.use('main');
select gnomon.open_change_request('pay', 'Charge account 1') as cr \gset
select t.fails(format('select gnomon.review(%s, ''approve'')', :cr), '42501', 'authors cannot approve their own change request');
reset role;

-- branch checks on request
select t.ok((select bool_and(passed) from gnomon.run_checks('pay', :cr)), 'checks pass on the branch');

set role gt_reviewer;
select t.fails($$select gnomon.merge('pay')$$, '42501', 'an unapproved change request blocks the merge');
select gnomon.review(:cr, 'approve', 'looks fine');
select t.eq((select status from gnomon.change_request where id = :cr), 'approved', 'change request approved');
select gnomon.merge('pay') as m \gset
reset role;
select t.eq((select balance from account where id = 1), 70, 'approved merge applied');
select t.eq((select status from gnomon.change_request where id = :cr), 'merged', 'change request marked merged');
select t.ok(exists (select 1 from gnomon.check_run where merge_id = :m and phase = 'merge' and passed), 'checks ran inside the merge');

-- a failing check rolls the merge back
select gnomon.create_branch('overdraw');
select gnomon.use('overdraw');
update account set balance = -5 where id = 2;
select gnomon.use('main');
select t.fails($$select gnomon.merge('overdraw')$$, '23514', 'failing check aborts the merge');
select t.eq((select balance from account where id = 2), 100, 'nothing applied after a failed check');
-- an incremental merge commits its batches, so a failing check leaves it applied in part:
-- marked failed, then resumable once fixed, or revertible
select gnomon.create_branch('overdraw2');
select gnomon.use('overdraw2');
update account set balance = -7 where id = 3;
update account set balance = 55 where id = 4;
select gnomon.use('main');
\set ON_ERROR_STOP off
call gnomon.merge_incremental('overdraw2', batch => 1);
\set ON_ERROR_STOP on
select max(id) as mo from gnomon.merge \gset
select t.eq((select status from gnomon.merge where id = :mo), 'failed', 'incremental merge with a failing check is marked failed');
select t.ok((select stats ->> 'checks' from gnomon.merge where id = :mo) like '%no_negative_balance%', 'the failure is recorded');
select t.eq((select balance from account where id = 3), -7, 'its batches stay applied');
select gnomon.undo_merge(:mo);
select t.eq((select string_agg(balance::text, ',' order by id) from account where id in (3, 4)), '100,100', 'a failed incremental merge can be undone');
select gnomon.drop_check('no_negative_balance');

-- a reject blocks until the reviewer approves again
select gnomon.create_branch('cr2');
select gnomon.open_change_request('cr2', 'second', approvals => 1) as cr2 \gset
set role gt_reviewer;
select gnomon.review(:cr2, 'reject', 'no');
select t.eq(gnomon._cr_approved(:cr2), false, 'rejected change request is not approved');
select gnomon.review(:cr2, 'approve');
select t.eq(gnomon._cr_approved(:cr2), true, 'latest verdict per reviewer counts');
reset role;

-- approvals go stale: a write to the branch after the approval dismisses it
set role gt_author;
select gnomon.create_branch('later');
select gnomon.use('later');
update account set balance = 101 where id = 5;
select gnomon.use('main');
select gnomon.open_change_request('later', 'small fix') as cr3 \gset
reset role;
set role gt_reviewer;
select gnomon.review(:cr3, 'approve');
reset role;
select t.ok(gnomon._cr_approved(:cr3), 'approved as written');
set role gt_author;
select gnomon.use('later');
update account set balance = 9999 where id = 6;   -- written after the approval
select gnomon.use('main');
reset role;
select t.ok(not gnomon._cr_approved(:cr3), 'a write after the approval makes it stale');
select t.ok(gnomon.review_stale((select max(id) from gnomon.review where cr = :cr3)), 'the review is reported stale');
set role gt_reviewer;
select t.fails($$select gnomon.merge('later')$$, '42501', 'a stale approval does not let the branch merge');
reset role;
select gnomon.set('stale_approvals', 'keep');
select t.ok(gnomon._cr_approved(:cr3), 'stale_approvals = keep restores the old rule');
select gnomon.set('stale_approvals', 'dismiss');
set role gt_reviewer;
select gnomon.review(:cr3, 'approve', 'saw the second change');
select t.ok(gnomon._cr_approved(:cr3), 'a fresh approval counts');
select gnomon.merge('later');
reset role;
select t.eq((select balance from account where id = 6), 9999, 'merged after the new approval');
-- a rebase after the approval is a change too
set role gt_author;
select gnomon.create_branch('rb');
select gnomon.use('rb');
update account set balance = 7 where id = 7;
select gnomon.use('main');
select gnomon.open_change_request('rb', 'rebase me') as cr4 \gset
reset role;
set role gt_reviewer;
select gnomon.review(:cr4, 'approve');
reset role;
update account set balance = 8 where id = 8;
select gnomon.rebase('rb');
select t.ok(not gnomon._cr_approved(:cr4), 'a rebase after the approval makes it stale');

-------------------------------------------------------------------------------
-- masked branches: masking expressions in the select list, real values restored on write
select gnomon.create_mask_profile('support');
select gnomon.add_mask_rule('support', 'account', 'ssn', '''***-**-'' || right(ssn, 4)');
select gnomon.add_mask_rule('support', 'account', 'email', 'regexp_replace(email, ''^[^@]+'', ''***'')');
select gnomon.create_branch('support-1');
select gnomon.confine('gt_masked', array['support-1'], false, 'support');
set role gt_masked;
select t.fails('select * from public.account', '42501', 'masked role cannot read the base table');
select gnomon.use('support-1');
select t.eq((select ssn from account where id = 3), '***-**-0003', 'masked column');
select t.eq((select email from account where id = 3), '***@x.io', 'second masked column');
update account set balance = 555 where id = 3;   -- the masked values come back unchanged
select t.eq((select balance from account where id = 3), 555, 'masked role writes its branch');
select gnomon.use('main');
reset role;
select gnomon.use('support-1');
select t.eq((select (ssn, email) from account where id = 3), row('123-45-0003'::text, 'user3@x.io'::text), 'real values kept for unchanged masked columns');
select gnomon.use('main');
select t.eq((select balance from account where id = 3), 100, 'masked branch write stayed on the branch');
-- a closed branch refuses masked writes too
select gnomon.close_branch('support-1');
set role gt_masked;
select gnomon.use('support-1');
select t.fails($$update account set balance = 1 where id = 3$$, '25006', 'a closed branch refuses masked writes');
reset role;
select gnomon.use('main');
select gnomon.reopen_branch('support-1');

-------------------------------------------------------------------------------
-- held outbox: rows written on a branch are delivered only when merged
select gnomon.outbox('outbox');
listen gnomon_outbox;
select gnomon.create_branch('notify');
select gnomon.use('notify');
insert into outbox(topic, payload) values ('welcome', '{"to": "a@x.io"}');
select gnomon.use('main');
select t.eq((select count(*) from gnomon.outbox_poll('mailer', 'outbox')), 0::bigint, 'branch outbox rows are held');
select gnomon.merge('notify');
select t.eq((select count(*) from gnomon.outbox_poll('mailer', 'outbox')), 1::bigint, 'outbox row delivered after merge');
select t.eq((select count(*) from gnomon.outbox_poll('mailer', 'outbox')), 0::bigint, 'delivered once');

reset role;
select gnomon.unconfine('gt_masked');
drop owned by gt_author; drop owned by gt_reviewer; drop owned by gt_masked;
drop role gt_author; drop role gt_reviewer; drop role gt_masked;
