# Examples

- [`shop.sql`](shop.sql): the example database. Four tracked tables with rows, and four logins
  (`shop_app`, `shop_reviewer`, `shop_ops`, and `shop_runs` for the SDKs' runs), none a superuser.
  `createdb shop && psql -d shop -f examples/shop.sql`. The compose file (`docker compose -f
  docker/compose.yml up`) seeds it too.
- [`tests/`](tests): tests on branches with the pytest plugin, including a snapshot of a branch's
  diff (`tests/__gnomon_snapshots__`). `GNOMON_TEST_DSN="dbname=shop user=shop_app" pytest examples/tests`
  (installing the package registers the plugin).
- [`tutorial.sh`](tutorial.sh): the [tutorial](../docs/tutorial.md) end to end with checks
  (tests, a reviewed data change, an agent on a role). It needs a freshly seeded database:
  `PGHOST=... GNOMON=path/to/gnomon PYTHON=python3 examples/tutorial.sh shop`.
