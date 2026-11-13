-- Upgrade prologue: runs with the previous version's code still in place.
-- Everything gnomon generates from code (per-table triggers, routing views, policies, write
-- functions) and the code itself is taken down; data (catalog rows, versions, branch tables)
-- stays. The epilogue builds it all again from the new code.
do $gnomon_up$
declare t record; f record; dep text; outbox jsonb;
begin
  perform set_config('gnomon._in_ddl', '1', true);
  -- objects outside gnomon that call gnomon functions would be dropped by the cascade below: stop
  select string_agg(distinct d.descr, ', ') into dep from (
    select pg_describe_object(dp.classid, dp.objid, dp.objsubid) as descr, dp.classid, dp.objid
      from pg_depend dp
      join pg_proc p on dp.refclassid = 'pg_proc'::regclass and dp.refobjid = p.oid
      join pg_namespace pn on pn.oid = p.pronamespace and pn.nspname in ('gnomon', '_gnomon')
     where dp.deptype in ('n', 'a')
       and not (dp.classid = 'pg_proc'::regclass and exists (
             select 1 from pg_proc q join pg_namespace qn on qn.oid = q.pronamespace
              where q.oid = dp.objid and qn.nspname in ('gnomon', '_gnomon')))
       and not (dp.classid = 'pg_rewrite'::regclass and exists (
             select 1 from pg_rewrite r join pg_class c on c.oid = r.ev_class join pg_namespace cn on cn.oid = c.relnamespace
              where r.oid = dp.objid and (cn.nspname in ('gnomon', '_gnomon') or cn.nspname like 'gnomon\_r\_%' or cn.nspname like 'gnomon\_q\_%')))
       and not (dp.classid = 'pg_trigger'::regclass and exists (select 1 from pg_trigger tg where tg.oid = dp.objid and tg.tgname like 'gnomon%'))
       and not (dp.classid = 'pg_policy'::regclass and exists (select 1 from pg_policy po where po.oid = dp.objid and po.polname like 'gnomon%'))
       and not (dp.classid = 'pg_event_trigger'::regclass)
       and not (dp.classid = 'pg_cast'::regclass)
       and not (dp.classid in ('pg_attrdef'::regclass, 'pg_constraint'::regclass) and exists (
             select 1 from pg_class c join pg_namespace cn on cn.oid = c.relnamespace
              where c.oid = coalesce((select adrelid from pg_attrdef where oid = dp.objid), (select conrelid from pg_constraint where oid = dp.objid))
                and (cn.nspname in ('gnomon', '_gnomon') or cn.nspname like 'gnomon\_r\_%' or cn.nspname like 'gnomon\_q\_%')))
  ) d;
  if dep is not null then
    raise exception 'gnomon cannot be upgraded while these objects use its functions: %', dep
      using hint = 'Drop them, run ALTER EXTENSION gnomon UPDATE, and create them again.';
  end if;
  -- held outboxes: their trigger's channel is not in the catalog
  select coalesce(jsonb_agg(jsonb_build_object('rel', tg.tgrelid::regclass::text,
                                               'channel', convert_from(substring(tg.tgargs from 1 for position('\x00'::bytea in tg.tgargs) - 1), 'UTF8'))), '[]')
    into outbox from pg_trigger tg where tg.tgname = 'gnomon_outbox';
  perform set_config('gnomon._up_outbox', outbox::text, true);
  drop event trigger if exists gnomon_ddl_start;
  drop event trigger if exists gnomon_ddl_end;
  for t in select id from gnomon.tracked order by id loop
    perform _gnomon.drop_routing(t.id, false);
  end loop;
  -- (members of other extensions living in these schemas, such as gnomon_c, stay)
  for f in select p.oid::regprocedure as fn, p.prokind from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('gnomon', '_gnomon')
              and not exists (select 1 from pg_depend d join pg_extension e on e.oid = d.refobjid
                               where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e' and e.extname <> 'gnomon') loop
    execute format('drop %s if exists %s cascade', case when f.prokind = 'p' then 'procedure' else 'function' end, f.fn);
  end loop;
end $gnomon_up$;
