# gnomon_dbt

dbt macros for a PostgreSQL database with the gnomon extension.

## Install

```yaml
# packages.yml
packages:
  - git: "https://github.com/bitsinfra/gnomon.git"
    revision: v1.0.2
    subdirectory: dbt/gnomon_dbt
```

Then `dbt deps`. dbt 1.5 or later, with the Postgres adapter.

## Macros

- **`gnomon_history`**, a materialization: a model kept in dbt's snapshot shape (`dbt_scd_id`,
  `dbt_updated_at`, `dbt_valid_from`, `dbt_valid_to`) from gnomon's change feed. It records every
  version (a dbt snapshot records the state at each run) and sees hard deletes. The first run
  loads the history since the table was tracked; later runs apply the changes since, through a
  feed consumer per model.

  ```sql
  -- models/customers_history.sql
  {{ config(materialized='gnomon_history', source_table='public.customers') }}
  select 1
  ```

- **`gnomon_as_of(ref)`** and **`gnomon_on_branch(branch)`**: pre-hooks that read a model's
  sources at a past moment (a timestamp, `tag:<name>` or a coordinate) or on a branch, for the
  model's transaction. A hook is a string dbt renders when the model runs, and a package's macros
  go by the package's name:

  ```sql
  {{ config(materialized='table', pre_hook="{{ gnomon_dbt.gnomon_as_of('tag:month_end') }}") }}
  select id, name, tier from customers
  ```

  Name the sources without a schema (`customers`, not `{{ source(...) }}`'s `"public"."customers"`)
  unless the server loads gnomon's C module: without it, only unqualified names follow the
  session's moment or branch.

The work happens in SQL, in `gnomon.dbt_snapshot(source, target)`: `test/sql/21_dbt.sql` checks
that the rows valid at every tick equal the as-of read there. `test/shell/dbt.sh` runs the
package through dbt itself (`integration_tests/`): a `gnomon_history` model's first run, a later
run and a run with nothing new, and models with each pre-hook, compared with gnomon's own reads.
