-- pg_dump support: catalog rows and sequences travel with dumps. Objects gnomon
-- generates per table (storage, routing views, triggers, policies) are ordinary objects and are
-- dumped as such. A restore into another cluster starts a new epoch on its first write.
do $$
declare t text;
begin
  -- only inside CREATE EXTENSION (the plain-SQL install form has no extension to attach to)
  if not exists (select 1 from pg_extension where extname = 'gnomon') then return; end if;
  foreach t in array array[
    'gnomon.setting', 'gnomon.epoch', 'gnomon.tick', 'gnomon.tag', 'gnomon.tracked', 'gnomon.branch_base', 'gnomon.xact',
    'gnomon.merge', 'gnomon.conflict', 'gnomon.change_request', 'gnomon.review', 'gnomon.check', 'gnomon.check_run',
    'gnomon.acl', 'gnomon.confined', 'gnomon.mask_profile', 'gnomon.mask_rule', 'gnomon.warning', 'gnomon.ledger_block',
    'gnomon.archive', 'gnomon.erasure', 'gnomon.consumer',
    '_gnomon.blob', '_gnomon.cleared', '_gnomon.ledger_leaf', '_gnomon.history_removed', '_gnomon.read_set',
    'gnomon.agent', 'gnomon.quota', 'gnomon.assignment', 'gnomon.run', 'gnomon.review_comment', 'gnomon.merge_policy',
    'gnomon.agent_call', 'gnomon.scheduled_merge', 'gnomon.notify_target', 'gnomon.notification', 'gnomon.sink', 'gnomon.sink_dead',
    'gnomon.thaw_request', 'gnomon.scenario', 'gnomon.scenario_step', 'gnomon.metric', 'gnomon.metric_run', 'gnomon.link',
    'gnomon.attempt', 'gnomon.action_table', 'gnomon.history_checkpoint', 'gnomon.schema_version', 'gnomon.schema_change',
    '_gnomon.branch_column', 'gnomon.subject', '_gnomon.subject_key', 'gnomon.subject_erased', 'gnomon.ledger_verification', 'gnomon.graph_view'] loop
    perform pg_catalog.pg_extension_config_dump(t::regclass, '');
  end loop;
  perform pg_catalog.pg_extension_config_dump('gnomon.branch'::regclass, 'where id <> 0');
  -- the engines the install script ships are made again by CREATE EXTENSION; added ones travel
  perform pg_catalog.pg_extension_config_dump('gnomon.archive_engine'::regclass, $f$where name not in ('pg_lake', 'duckdb_fdw', 'file_fdw')$f$);
  -- the extension's own sequences (per-table ones, made by gnomon.track, are dumped as objects)
  for t in select c.oid::regclass::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where c.relkind = 'S' and n.nspname in ('gnomon', '_gnomon')
              and exists (select 1 from pg_depend d where d.classid = 'pg_class'::regclass and d.objid = c.oid
                             and d.refclassid = 'pg_extension'::regclass and d.deptype = 'e') loop
    perform pg_catalog.pg_extension_config_dump(t::regclass, '');
  end loop;
end $$;
