{#
  gnomon_history: a model kept in dbt's snapshot shape (dbt_scd_id, dbt_updated_at,
  dbt_valid_from, dbt_valid_to) from gnomon's change feed. Unlike a dbt snapshot it records
  every version, not the state at each run, and a hard delete closes the row. The first run
  loads the table's whole history since it was tracked; later runs apply what changed since,
  through a feed consumer per model. Models written against dbt snapshots read it unchanged.

    {{ config(materialized='gnomon_history', source_table='public.customers') }}
    select 1  -- (the body is not used: the history comes from the source table)

  The work is gnomon.dbt_snapshot(source_table, target), tested in the extension's suite.
#}
{% materialization gnomon_history, adapter='postgres' %}
  {%- set source_table = config.require('source_table') -%}
  {%- set consumer = config.get('consumer', none) -%}
  {%- set target_relation = this.incorporate(type='table') -%}
  {{ run_hooks(pre_hooks) }}
  {% call statement('main', fetch_result=True) -%}
    select gnomon.dbt_snapshot({{ dbt.string_literal(source_table) }}::regclass, {{ dbt.string_literal(target_relation | string) }}
                               {%- if consumer %}, {{ dbt.string_literal(consumer) }}{% endif %})::text as result
  {%- endcall %}
  {{ run_hooks(post_hooks) }}
  {% do adapter.commit() %}
  {{ return({'relations': [target_relation]}) }}
{% endmaterialization %}
