{{ config(materialized='gnomon_history', source_table='public.customers') }}
select 1
