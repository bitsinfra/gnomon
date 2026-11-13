-- Upgrade epilogue (extension form): the per-table objects are rebuilt by gnomon's
-- ddl_command_end trigger once ALTER EXTENSION is done (_gnomon.upgrade_regenerate): objects made
-- inside an extension script would become members of the extension and drop out of pg_dump. The
-- update refuses to finish without that trigger, so it never leaves tables unversioned.
do $gnomon_up$
begin
  perform set_config('gnomon._in_ddl', '', true);
  if not exists (select 1 from pg_event_trigger where evtname = 'gnomon_ddl_end' and evtenabled <> 'D') then
    raise exception 'upgrading gnomon needs its event triggers, which could not be created'
      using hint = 'Run ALTER EXTENSION gnomon UPDATE as a superuser.';
  end if;
  perform set_config('gnomon._up_regen', '1', true);
end $gnomon_up$;
