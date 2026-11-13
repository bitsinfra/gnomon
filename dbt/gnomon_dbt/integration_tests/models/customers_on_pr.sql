-- the table as a branch has it
{{ config(materialized='table', pre_hook="{{ gnomon_dbt.gnomon_on_branch('pr-1') }}") }}
select id, name, tier from customers
