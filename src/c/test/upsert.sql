-- With the C module: INSERT ... ON CONFLICT on a branch with SET expressions over
-- the existing and the excluded row, DO UPDATE ... WHERE, a partial unique index's arbiter and an
-- expression arbiter. Each statement runs on the branch and, the same, on an untracked copy
-- (PostgreSQL's own upsert); the two must end equal.
create table acct (id int primary key, owner text not null, email text, bal int not null default 0, active bool not null default true);
create unique index acct_owner_active on acct (owner) where active;
create unique index acct_email_lower on acct (lower(email));
insert into acct values (1, 'ann', 'Ann@x.io', 10, true), (2, 'bob', 'bob@x.io', 20, true), (3, 'cy', 'cy@x.io', 30, false);
create table ref (like acct including all);
insert into ref select * from acct;
select gnomon.track('acct');
select gnomon.create_branch('u');
create function t.run(sql text) returns void language plpgsql as $$
begin
  perform set_config('gnomon.branch', 'u', true);
  execute replace(sql, 'TBL', 'acct');
  perform set_config('gnomon.branch', '', true);
  execute replace(sql, 'TBL', 'ref');
end $$;
create function t.same(msg text) returns void language plpgsql as $$
declare b jsonb; r jsonb;
begin
  perform set_config('gnomon.branch', 'u', true);
  select jsonb_agg(to_jsonb(x) order by x.id) into b from acct x;
  perform set_config('gnomon.branch', '', true);
  select jsonb_agg(to_jsonb(x) order by x.id) into r from ref x;
  perform t.eq(b, r, msg);
end $$;

select t.run($$insert into TBL values (1, 'ann', 'a@x.io', 5) on conflict (id) do update set bal = TBL.bal + excluded.bal, email = coalesce(excluded.email, TBL.email)$$);
select t.same('SET expressions over the existing and the excluded row');
select t.run($$insert into TBL values (2, 'bob', null, 1) on conflict (id) do update set bal = excluded.bal where TBL.bal < excluded.bal$$);
select t.same('DO UPDATE ... WHERE that says no');
select t.run($$insert into TBL values (2, 'bob', null, 99) on conflict (id) do update set bal = excluded.bal where TBL.bal < excluded.bal$$);
select t.same('DO UPDATE ... WHERE that says yes');
select t.run($$insert into TBL (id, owner, email, bal) values (10, 'ann', 'ann2@x.io', 1) on conflict (owner) where active do update set bal = TBL.bal + 100$$);
select t.same('a partial unique index as the arbiter (a conflict with an active row)');
select t.run($$insert into TBL (id, owner, email, bal) values (11, 'cy', 'cy2@x.io', 1) on conflict (owner) where active do nothing$$);
select t.same('no conflict with a row outside the index''s predicate');
select t.run($$insert into TBL (id, owner, email, bal) values (12, 'zed', 'BOB@X.IO', 7) on conflict ((lower(email))) do update set owner = excluded.owner || '!', email = upper(excluded.email)$$);
select t.same('an expression arbiter');
select t.run($$insert into TBL (id, owner, email, bal) values (13, 'new', 'new@x.io', 1) on conflict (id) do update set bal = 0$$);
select t.same('a row with no conflict is inserted');
-- prepared, so the spec is set on every execution
set gnomon.branch = 'u';
prepare up2(int, int) as insert into acct values ($1, 'p' || $1, null, $2) on conflict (id) do update set bal = acct.bal * 2 + excluded.bal where acct.active;
execute up2(1, 1);
execute up2(1, 1);
reset gnomon.branch;
prepare upr(int, int) as insert into ref values ($1, 'p' || $1, null, $2) on conflict (id) do update set bal = ref.bal * 2 + excluded.bal where ref.active;
execute upr(1, 1);
execute upr(1, 1);
select t.same('a prepared upsert with expressions, twice');
select t.eq(coalesce(current_setting('gnomon._upsert', true), '') || coalesce(current_setting('gnomon._upsert_excl', true), ''), '', 'the spec is cleared after the statement');
set gnomon.branch = 'u';
select t.fails($$insert into acct values (1, 'x', null, 1) on conflict (id) do update set bal = (select 1)$$, '0A000', 'a subquery in SET is refused by name');
reset gnomon.branch;
-- main never saw any of it
select t.eq((select bal from acct where id = 1), 10, 'main is unchanged');
