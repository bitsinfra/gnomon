-- The example shop: the tutorial's database (docs/tutorial.md) and the compose file's
-- (docker/compose.yml). Run once, as a superuser, in an empty database:
--   createdb shop && psql -d shop -f examples/shop.sql
-- It installs gnomon, creates and seeds four tables, tracks them, and makes the logins the tutorial
-- and the SDKs use (docs/sdk.md); none of them is a superuser.
\set ON_ERROR_STOP on
set client_min_messages = warning;
create extension if not exists gnomon;

create table customers (
  id    serial primary key,
  email text not null unique,
  name  text not null
);
create table products (
  id    serial primary key,
  sku   text not null unique,
  name  text not null,
  price numeric(10,2) not null check (price >= 0),
  stock int not null default 0
);
create table orders (
  id          serial primary key,
  customer_id int not null references customers(id),
  status      text not null default 'new',
  total       numeric(10,2) not null default 0,
  created_at  timestamptz not null default now()
);
create index on orders (customer_id);
create table order_items (
  order_id   int not null references orders(id),
  product_id int not null references products(id),
  qty        int not null check (qty > 0),
  price      numeric(10,2) not null,
  primary key (order_id, product_id)
);
create index on order_items (product_id);

insert into customers (email, name)
select format('c%s@example.com', g), format('Customer %s', g) from generate_series(1, 50) g;
insert into products (sku, name, price, stock)
select format('SKU-%s', g), format('Product %s', g), (g * 1.5)::numeric(10,2), 100 from generate_series(1, 20) g;
insert into orders (customer_id, status)
select (g % 50) + 1, case when g % 5 = 0 then 'shipped' else 'new' end from generate_series(1, 200) g;
insert into order_items
select o.id, p.id, (o.id % 3) + 1, p.price from orders o join products p on p.id = ((o.id * 7) % 20) + 1;
update orders o set total = (select sum(i.qty * i.price) from order_items i where i.order_id = o.id);

-- history and branches for every table of the schema
select gnomon.track_schema('public');

-- the tutorial's agent, if an earlier run left it (roles outlive a dropped database)
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'gnomon_agent_support') then
    execute 'drop role gnomon_agent_support';
  end if;
exception when others then
  raise notice 'role gnomon_agent_support is left from an earlier run elsewhere: drop it to rerun part 3 of the tutorial';
end $$;

-- logins (example passwords; the dev cluster trusts local sockets anyway)
do $$
declare r text;
begin
  foreach r in array array['shop_app', 'shop_reviewer', 'shop_ops', 'shop_runs'] loop
    if not exists (select 1 from pg_roles where rolname = r) then
      execute format('create role %I login password %L', r, r);
    end if;
  end loop;
end $$;
-- the application: ordinary table grants; with the SDKs it also starts its agents' runs and
-- merges the ones it accepts
grant usage on schema public to shop_app, shop_reviewer;
grant select, insert, update, delete on all tables in schema public to shop_app, shop_reviewer;
grant usage on all sequences in schema public to shop_app, shop_reviewer;
grant gnomon_runner, gnomon_merger to shop_app;
-- a reviewer may merge into main and undo there
grant gnomon_merger to shop_reviewer;
-- operations: agents, quotas, sinks, the daemon's jobs
grant gnomon_admin, gnomon_merger to shop_ops;
grant usage on schema public to shop_ops;
grant select on all tables in schema public to shop_ops;
-- the runs login every SDK run shares: confined, so it reads and writes only the run its
-- transaction is bound to
select gnomon.confine('shop_runs', array[]::text[], false);
select gnomon.set('runs_role', 'shop_runs');
