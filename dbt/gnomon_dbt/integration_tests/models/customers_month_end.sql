-- the table as it was at the tag (names without a schema, so the session's moment applies)
{{ config(materialized='table', pre_hook="{{ gnomon_dbt.gnomon_as_of('tag:month_end') }}") }}
select id, name, tier from customers
