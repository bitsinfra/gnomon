{#
  Read a model's sources as of a moment (a timestamp, tag:<name> or a gnomon coordinate):
    {{ config(pre_hook="{{ gnomon_dbt.gnomon_as_of('tag:month_end') }}") }}
  (a hook is a string dbt renders when the model runs). The session reads every tracked table at that moment until the model
  ends (gnomon.begin: one transaction).
#}
{% macro gnomon_as_of(ref) -%}
  select gnomon.begin('main', {{ dbt.string_literal(ref) }})
{%- endmacro %}

{#
  Read a model's sources on a gnomon branch (a scenario, a pull request's data):
    {{ config(pre_hook="{{ gnomon_dbt.gnomon_on_branch('pr-12') }}") }}
#}
{% macro gnomon_on_branch(branch) -%}
  select gnomon.begin({{ dbt.string_literal(branch) }})
{%- endmacro %}
