-- DDL on main reaches every branch: a rename, a drop and a type change of a tracked
-- table's columns, with rows on a branch and history behind them. Branch storage holds user
-- columns by name and follows renames by attribute number; a dropped column's storage stops
-- being required; a type change converts history and branch rows (with a plain cast: the event
-- trigger cannot see a USING expression).
create table c (id int primary key, name text not null, v int, w int not null default 0);
insert into c values (1, 'a', 1, 5), (2, 'b', 2, 6);
select gnomon.track('c');
select gnomon.create_branch('b');
select gnomon.coordinate_text() as c0 \gset
select gnomon.use('b');
update c set v = 10 where id = 1;
select gnomon.use('main');
alter table c rename column name to full_name;
alter table c drop column w;
alter table c alter column v type text;
select gnomon.use('b');
select t.eq((select full_name || '/' || v from c where id = 1), 'a/10', 'a branch row keeps its values under the new name and type');
update c set v = '20' where id = 2;
insert into c values (3, 'c', 'x');
select t.eq((select string_agg(id || full_name || v, ',' order by id) from c), '1a10,2b20,3cx', 'the branch writes the new shape');
select gnomon.use('main', :'c0');
select t.eq((select string_agg(id || full_name || v, ',' order by id) from c), '1a1,2b2', 'history reads in the new shape');
select gnomon.use('main');
select gnomon.merge('b') as mb \gset
select t.eq((select status from gnomon.merge where id = :mb), 'applied', 'and merges');
select t.eq((select string_agg(id || full_name || v, ',' order by id) from c), '1a10,2b20,3cx', 'main has the branch''s rows');
-- main's rows convert with the statement's USING; history holds 'x', which no cast makes an int
select t.fails($$alter table c alter column v type int using (case when v ~ '^[0-9]+$' then v::int end)$$, '22P02', 'a type history cannot hold is refused');
do $$ begin
  alter table c alter column v type int using (case when v ~ '^[0-9]+$' then v::int end);
exception when invalid_text_representation then
  perform t.ok(sqlerrm like 'gnomon cannot convert the history of a column to integer%', 'naming why');
end $$;
