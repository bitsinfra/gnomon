#!/usr/bin/env bash
# The gnomon_dbt package through dbt itself (dbt/gnomon_dbt/integration_tests): the
# gnomon_history materialization's first and later runs equal the change feed, a model with the
# gnomon_as_of pre-hook equals an as-of read at the tag, and one with gnomon_on_branch equals the
# branch's rows. DBT names the dbt executable (default: build/venv-dbt/bin/dbt); skipped without it.
source "$(dirname "$0")/_lib.sh"
[ -n "${GNOMON_SKIP_EXTERNAL:-}" ] && { echo "skip: GNOMON_SKIP_EXTERNAL"; exit 0; }
DBT=${DBT:-$ROOT/build/venv-dbt/bin/dbt}
[ -x "$DBT" ] || command -v "$DBT" >/dev/null || { echo "skip: no dbt (python -m venv build/venv-dbt && build/venv-dbt/bin/pip install dbt-postgres)"; exit 0; }
P=$ROOT/dbt/gnomon_dbt/integration_tests
export GNOMON_DBT_DB=$DB DBT_PROFILES_DIR=$P
q() { psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
q >/dev/null <<'SQL'
create table customers (id int primary key, name text not null, tier text);
insert into customers select g, 'c' || g, 'basic' from generate_series(1, 20) g;
select gnomon.track('customers');
update customers set tier = 'gold' where id <= 5;
delete from customers where id = 20;
select gnomon._do_tick(true);
insert into gnomon.tag(name, coord) select 'month_end', gnomon.coordinate();
update customers set tier = 'platinum' where id = 1;
insert into customers values (21, 'late', 'basic');
select gnomon.create_branch('pr-1');
select gnomon.use('pr-1');
update customers set tier = 'trial' where id between 10 and 12;
select gnomon.use('main');
SQL
run() { (cd "$P" && "$DBT" --no-use-colors "$@") >>"$ROOT/build/test-out/dbt.out" 2>&1 || { tail -40 "$ROOT/build/test-out/dbt.out"; fail "dbt $*"; }; }
: >"$ROOT/build/test-out/dbt.out"
run deps
run run
# the history: one open row per current row, and every version since tracking
[ "$(q -c "select count(*) from dbt_it.customers_history where dbt_valid_to is null")" = "$(q -c "select count(*) from customers")" ] || fail "gnomon_history: open rows"
[ "$(q -c "select count(*) from dbt_it.customers_history where id = 20 and dbt_valid_to is not null")" -ge 1 ] || fail "gnomon_history: a hard delete closes the row"
[ "$(q -c "select tier from dbt_it.customers_history where id = 1 and dbt_valid_to is null")" = platinum ] || fail "gnomon_history: the current version"
want=$(q -c "select gnomon.use('main', 'tag:month_end')" -c "select string_agg(id || ':' || tier, ',' order by id) from customers" | tail -1)
[ "$(q -c "select string_agg(id || ':' || tier, ',' order by id) from dbt_it.customers_month_end")" = "$want" ] || fail "gnomon_as_of: the model equals the as-of read"
want=$(q -c "select gnomon.use('pr-1')" -c "select string_agg(id || ':' || tier, ',' order by id) from customers" | tail -1)
[ "$(q -c "select string_agg(id || ':' || tier, ',' order by id) from dbt_it.customers_on_pr")" = "$want" ] || fail "gnomon_on_branch: the model equals the branch"
[ "$(q -c "select count(*) from customers where tier = 'trial'")" = 0 ] || fail "main is untouched"
# a later run applies only what changed
before=$(q -c "select count(*) from dbt_it.customers_history")
q -c "update customers set tier = 'silver' where id = 2" -c "delete from customers where id = 3" >/dev/null
run run --select customers_history
[ "$(q -c "select count(*) from dbt_it.customers_history")" = $((before + 1)) ] || fail "the second run adds one version"
[ "$(q -c "select tier from dbt_it.customers_history where id = 2 and dbt_valid_to is null")" = silver ] || fail "and closes the old one"
[ "$(q -c "select count(*) from dbt_it.customers_history where id = 3 and dbt_valid_to is null")" = 0 ] || fail "a delete since the last run closes the row"
run run --select customers_history
[ "$(q -c "select count(*) from dbt_it.customers_history")" = $((before + 1)) ] || fail "a run with nothing new changes nothing"
echo "dbt $("$DBT" --version 2>/dev/null | sed -n 's/.*installed: //p' | head -1): ok"
