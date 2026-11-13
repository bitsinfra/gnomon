-- Schema changes on a branch.
--
-- A schema version is a shape of the tracked tables: main's, plus an ordered list of changes made
-- on a branch (gnomon.ddl). Its objects live in routing schemas gnomon_r_<schema>__v<n> holding a
-- view for every relation of the schema, as mask profiles do; a branch points at a version, its
-- children inherit it, and its first DDL forks one. Main is not touched until the merge.
--
-- DDL is understood without parsing SQL: the statement runs against empty clones of the tables in
-- a shadow schema, and the catalogs before and after tell an added column from a new table, a
-- new index, a constraint, a rename, a drop or a type change.
--
-- An added column's values live in a side
-- table (_gnomon.branch_column, versioned with stamps like branch history) read through the
-- version's view, instead of a physical gn_x column on the branch tables, so no generated object
-- of plain branches changes. A new table is created for real, empty, in a hidden schema
-- gnomon_sv<n>_<schema> and tracked there. The merge replays the DDL on main, copies the values
-- into the now-real columns as branch writes, and merges the data as always.

insert into gnomon.setting_default values
  ('ddl_lock_timeout', '5s', 'lock_timeout for DDL a merge replays on main.'),
  ('ddl_concurrent_rows', '1000000', 'An index a merge replays on a table of at least this many rows (pg_class.reltuples) is left for CREATE INDEX CONCURRENTLY after the merge: the merge''s stats list it under indexes_to_build and gnomon merge builds it; off: always in the merge.');

create function _gnomon.version_schema(nsp name, v int) returns text language sql immutable as $$
  select format('gnomon_r_%s__v%s', nsp, v)
$$;
create function _gnomon.hidden_schema(nsp name, v int) returns text language sql immutable as $$
  select format('gnomon_sv%s_%s', v, nsp)
$$;

-- A version and its ancestors, oldest first.
create function _gnomon.version_lineage(v int) returns int[] language sql stable as $$
  with recursive l as (select id, parent, 0 as d from gnomon.schema_version where id = v
                       union all select s.id, s.parent, l.d + 1 from gnomon.schema_version s join l on s.id = l.parent)
  select coalesce(array_agg(id order by d desc), '{}') from l
$$;

-- The routing path of a branch on a version: the version's schemas first, the new tables' routing
-- schemas, then the plain routing path.
create function _gnomon.version_path(v int, p text) returns text language plpgsql stable as $$
declare out text[] := '{}'; e text; s text; x int;
begin
  if v is null then return p; end if;
  foreach e in array string_to_array(p, ', ') loop
    s := btrim(e, '"');
    if s like 'gnomon\_r\_%' and s not like '%\_\_s' and s not like '%\_\_m%' then
      if exists (select 1 from pg_namespace where nspname = _gnomon.version_schema(substr(s, 10)::name, v)) then
        out := out || quote_ident(_gnomon.version_schema(substr(s, 10)::name, v));
      end if;
      foreach x in array _gnomon.version_lineage(v) loop
        if exists (select 1 from pg_namespace where nspname = 'gnomon_r_' || _gnomon.hidden_schema(substr(s, 10)::name, x)) then
          out := out || quote_ident('gnomon_r_' || _gnomon.hidden_schema(substr(s, 10)::name, x));
        end if;
      end loop;
    end if;
    out := out || e;
  end loop;
  return array_to_string(out, ', ');
end $$;

-- The key of a row as JSON, in key-column order (the side table's key).
create function _gnomon.keyjson_sql(t gnomon.tracked, alias text) returns text language sql immutable as $$
  select _gnomon.key_sql(t, alias)
$$;

-- Set a branch-only column's value for a key on the session's branch (the version view's trigger).
create function _gnomon.set_branch_column(p_change bigint, p_key jsonb, p_value jsonb) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare c _gnomon.ctx := gnomon._ctx(); st gnomon.stamp; t gnomon.tracked;
begin
  if c.branch = 0 then raise exception 'branch-only columns are written on their branch' using errcode = '25006', hint = '[gnomon:schema_version_main]'; end if;
  select x.* into t from gnomon.tracked x join gnomon.schema_change sc on sc.id = p_change where format('%I.%I', x.nsp, x.relname) = sc.tbl;
  perform gnomon._write_check(c, t.id, 'UPDATE', _gnomon.who(), format('%I.%I', 'gnomon_r_' || t.nsp, t.relname)::regclass);
  st := gnomon._stamp();
  insert into _gnomon.branch_column as bc (change, branch, key, value, gn_key, gn_xoff) values (p_change, c.branch, p_key, p_value, st.key, st.xoff)
    on conflict (change, key, branch, gn_key) do update set value = excluded.value;
end $$;

-- The value of a branch-only column for a key, at the session's lineage (each level at its cutoff).
create function _gnomon.branch_column_value(change bigint, key jsonb) returns jsonb
language sql stable security definer set search_path = pg_catalog, pg_temp as $$
  select bc.value from _gnomon.branch_column bc
   where bc.change = $1 and bc.key = $2 and bc.branch = any(gnomon._ctx_lb())
     and gnomon._vis(bc.gn_key, bc.gn_xoff, (gnomon._ctx_lc())[array_position(gnomon._ctx_lb(), bc.branch)])
   order by array_position(gnomon._ctx_lb(), bc.branch), bc.gn_key desc limit 1
$$;

create function _gnomon.col_type(tbl text, col text) returns text language sql stable as $$
  select format_type(a.atttypid, a.atttypmod) from pg_attribute a
   where a.attrelid = to_regclass(tbl) and a.attname = col and a.attnum > 0 and not a.attisdropped
$$;

-- The column of a shape by its current name: its index, or -1.
create function _gnomon.shape_col(cols jsonb, name text) returns int language sql immutable as $$
  select coalesce((select (o - 1)::int from jsonb_array_elements(cols) with ordinality e(x, o) where x ->> 'name' = name limit 1), -1)
$$;

-- The shape of a table under a version: its columns as the version's view shows them, in
-- order, and the constraints the version adds. Main's columns come from the table; the version's
-- changes apply in order. Each column: name, base (main's column it reads, or null), type,
-- base_type, side (the change whose values the side table holds, or null), def (the insert
-- default), fill (what rows read before any value is written: an added column's default), nn
-- (NOT NULL the branch added), gen, key, up and down (a retyped column's expressions), uname
-- (the name up and down refer to).
create function _gnomon.version_shape(v int, tid int) returns jsonb language plpgsql stable
set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked := _gnomon.trow(tid); vtbl text; cols jsonb; checks jsonb := '[]'; uniques jsonb := '[]'; fks jsonb := '[]';
        dropped bool := false; changed bool := false; c gnomon.schema_change; i int; lin int[] := _gnomon.version_lineage(v); mt text;
        refby jsonb;
begin
  vtbl := format('%I.%I', t.nsp, t.relname);
  -- (an identity column has no default of its own: the version's view draws from its sequence,
  -- as the routing view does)
  select coalesce(jsonb_agg(jsonb_build_object('name', a.attname, 'base', a.attname, 'type', format_type(a.atttypid, a.atttypmod),
            'base_type', format_type(a.atttypid, a.atttypmod), 'side', null,
            'def', case when a.attidentity in ('a', 'd') then format('nextval(%L::regclass)', pg_get_serial_sequence(vtbl, a.attname))
                        else pg_get_expr(d.adbin, d.adrelid) end, 'fill', null,
            'nn', false, 'gen', a.attgenerated <> '', 'key', a.attname = any(t.key_cols), 'up', null, 'down', null, 'uname', null)
            order by a.attnum), '[]')
    into cols
    from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
   where a.attrelid = t.rel and a.attnum > 0 and not a.attisdropped;
  for c in select sc.* from gnomon.schema_change sc
            where sc.version = any(lin) and sc.tbl = vtbl and not coalesce((sc.detail ->> 'own_table')::bool, false)
            order by array_position(lin, sc.version), sc.seq loop
    if c.op = 'add_check' then
      checks := checks || c.detail; changed := true; continue;
    elsif c.op = 'add_unique' then
      uniques := uniques || c.detail; changed := true; continue;
    elsif c.op = 'add_fk' then
      fks := fks || c.detail; changed := true; continue;
    elsif c.op = 'drop_constraint' then
      checks := coalesce((select jsonb_agg(x) from jsonb_array_elements(checks) x where x ->> 'name' <> c.detail ->> 'name'), '[]');
      uniques := coalesce((select jsonb_agg(x) from jsonb_array_elements(uniques) x where x ->> 'name' <> c.detail ->> 'name'), '[]');
      fks := coalesce((select jsonb_agg(x) from jsonb_array_elements(fks) x where x ->> 'name' <> c.detail ->> 'name'), '[]');
      continue;
    elsif c.op = 'drop_table' then
      dropped := true; changed := true; continue;
    elsif c.op not in ('add_column', 'rename_column', 'drop_column', 'alter_type', 'set_not_null', 'drop_not_null', 'set_default', 'drop_default') then
      continue;
    end if;
    i := _gnomon.shape_col(cols, c.detail ->> 'column');
    if c.op = 'add_column' then
      mt := _gnomon.col_type(vtbl, c.detail ->> 'column');
      if i >= 0 then
        -- main has it now: with the same type the branch's values read over it; another type is main's
        if mt is not distinct from c.detail ->> 'type' then
          cols := jsonb_set(cols, array[i::text, 'side'], to_jsonb(c.id)); changed := true;
        end if;
      else
        cols := cols || jsonb_build_object('name', c.detail ->> 'column', 'base', null, 'type', c.detail ->> 'type', 'base_type', null,
                   'side', c.id, 'def', c.detail -> 'default', 'fill', c.detail -> 'default',
                   'nn', coalesce((c.detail ->> 'not_null')::bool, false), 'gen', false, 'key', false, 'up', null, 'down', null, 'uname', null);
        changed := true;
      end if;
      continue;
    end if;
    continue when i < 0;   -- a column main no longer has (the merge reports it)
    changed := true;
    if c.op = 'rename_column' then
      cols := jsonb_set(cols, array[i::text, 'name'], to_jsonb(c.detail ->> 'to'));
    elsif c.op = 'drop_column' then
      cols := cols - i;
    elsif c.op = 'alter_type' then
      if (cols -> i ->> 'base') is not null and (cols -> i ->> 'side') is null then
        cols := jsonb_set(cols, array[i::text, 'side'], to_jsonb(c.id));
        cols := jsonb_set(cols, array[i::text, 'uname'], to_jsonb(c.detail ->> 'column'));
        cols := jsonb_set(cols, array[i::text, 'up'],
                  to_jsonb(coalesce(c.detail ->> 'up', format('%I::%s', c.detail ->> 'column', c.detail ->> 'to'))));
        cols := jsonb_set(cols, array[i::text, 'down'],
                  to_jsonb(coalesce(c.detail ->> 'down', format('%I::%s', c.detail ->> 'column', cols -> i ->> 'base_type'))));
      end if;
      cols := jsonb_set(cols, array[i::text, 'type'], to_jsonb(c.detail ->> 'to'));
      if cols -> i ->> 'def' is not null then
        cols := jsonb_set(cols, array[i::text, 'def'], to_jsonb(format('(%s)::%s', cols -> i ->> 'def', c.detail ->> 'to')));
      end if;
    elsif c.op = 'set_not_null' then
      cols := jsonb_set(cols, array[i::text, 'nn'], 'true');
    elsif c.op = 'drop_not_null' then
      cols := jsonb_set(cols, array[i::text, 'nn'], 'false');
    elsif c.op = 'set_default' then
      cols := jsonb_set(cols, array[i::text, 'def'], c.detail -> 'default');
    elsif c.op = 'drop_default' then
      cols := jsonb_set(cols, array[i::text, 'def'], 'null');
    end if;
  end loop;
  -- foreign keys the version added on main's tables that reference this one: its deletes and key
  -- changes are checked against the referencing rows (refby)
  select coalesce(jsonb_agg(sc.detail || jsonb_build_object('from', x.relname) order by sc.id), '[]') into refby
    from gnomon.schema_change sc join gnomon.tracked x on x.rel = to_regclass(sc.tbl)
   where sc.version = any(lin) and sc.op = 'add_fk' and not coalesce((sc.detail ->> 'own_table')::bool, false)
     and sc.detail ->> 'ref' = t.relname and x.nsp = t.nsp
     and not exists (select 1 from gnomon.schema_change z where z.version = any(lin) and z.op = 'drop_constraint' and z.tbl = sc.tbl
                        and z.detail ->> 'name' = sc.detail ->> 'name'
                        and (array_position(lin, z.version), z.seq) > (array_position(lin, sc.version), sc.seq));
  if jsonb_array_length(refby) > 0 then changed := true; end if;
  return jsonb_build_object('cols', cols, 'checks', checks, 'uniques', uniques, 'fks', fks, 'refby', refby, 'dropped', dropped, 'changed', changed);
end $$;

-- A relation the version dropped: its view in the version schema says so (reads and writes).
create function _gnomon.dropped_on_branch(rel text) returns bool language plpgsql stable as $$
begin
  raise exception 'relation "%" does not exist on this branch (its schema version dropped it)', rel
    using errcode = '42P01', hint = 'The table is dropped on main when the branch is merged. [gnomon:dropped_on_branch]';
end $$;
create function _gnomon.dropped_on_branch_trg() returns trigger language plpgsql as $$
begin
  perform _gnomon.dropped_on_branch(tg_table_name::text);
  return null;
end $$;

-- The view a branch reads another table through, for a foreign key the version adds.
create function _gnomon.version_rel(v int, nsp name, rel text) returns text language sql stable as $$
  select case when exists (select 1 from gnomon.tracked x where x.nsp = $2 and x.relname = $3)
              then format('%I.%I', _gnomon.version_schema($2, $1), $3)
              else (select format('%I.%I', 'gnomon_r_' || _gnomon.hidden_schema($2, z.version), $3) from gnomon.schema_change z
                     where z.op = 'create_table' and z.detail ->> 'table' = $3 and z.version = any(_gnomon.version_lineage($1)) limit 1) end
$$;

-- The checks of a version's constraints in its view's trigger, over NEW (OLD for the row an
-- update replaces).
create function _gnomon.shape_checks(v int, nsp name, vs text, rel text, shape jsonb, keycols name[]) returns text
language plpgsql stable as $$
declare out text := ''; x jsonb; cl text; nl text; kl text;
begin
  kl := (select string_agg(format('gn_o.%I', k), ', ') from unnest(keycols) k);
  for x in select e from jsonb_array_elements(shape -> 'cols') e where (e ->> 'nn')::bool loop
    out := out || format(E'  IF NEW.%1$I IS NULL THEN RAISE EXCEPTION ''null value in column "%1$s" of relation "%2$s" violates not-null constraint'' USING ERRCODE = ''23502''; END IF;\n',
                         x ->> 'name', rel);
  end loop;
  for x in select e from jsonb_array_elements(shape -> 'checks') e loop
    out := out || format(E'  IF NOT coalesce((SELECT (%1$s) FROM (SELECT NEW.*) gn_x), true) THEN RAISE EXCEPTION ''new row for relation "%2$s" violates check constraint "%3$s"'' USING ERRCODE = ''23514''; END IF;\n',
                         x ->> 'expr', rel, x ->> 'name');
  end loop;
  for x in select e from jsonb_array_elements(shape -> 'uniques') e loop
    cl := (select string_agg(format('gn_o.%I', c), ', ') from jsonb_array_elements_text(x -> 'columns') c);
    nl := (select string_agg(format('NEW.%I', c), ', ') from jsonb_array_elements_text(x -> 'columns') c);
    out := out || format(E'  IF %1$s THEN\n    PERFORM pg_advisory_xact_lock(hashtext(%2$L), hashtext(ROW(%3$s)::text));\n'
                         || E'    IF EXISTS (SELECT 1 FROM %4$s gn_o WHERE ROW(%5$s) = ROW(%3$s) AND ROW(%6$s) IS DISTINCT FROM ROW(%7$s)) THEN\n'
                         || E'      RAISE EXCEPTION ''duplicate key value violates unique constraint "%8$s"'' USING ERRCODE = ''23505'';\n    END IF;\n  END IF;\n',
                         (select string_agg(format('NEW.%I IS NOT NULL', c), ' AND ') from jsonb_array_elements_text(x -> 'columns') c),
                         'gnomon_unique:' || rel || '.' || (x ->> 'name'), nl, format('%I.%I', vs, rel), cl, kl,
                         (select string_agg(format('OLD.%I', k), ', ') from unnest(keycols) k), x ->> 'name');
  end loop;
  for x in select e from jsonb_array_elements(shape -> 'fks') e loop
    -- (a shared lock on the referenced value: a concurrent delete of it on the branch waits)
    out := out || format(E'  IF %1$s THEN\n    PERFORM pg_advisory_xact_lock_shared(hashtext(%7$L), hashtext(ROW(%4$s)::text));\n'
                         || E'    IF NOT EXISTS (SELECT 1 FROM %2$s gn_p WHERE ROW(%3$s) = ROW(%4$s)) THEN\n'
                         || E'      RAISE EXCEPTION ''insert or update on table "%5$s" violates foreign key constraint "%6$s"'' USING ERRCODE = ''23503'';\n    END IF;\n  END IF;\n',
                         (select string_agg(format('NEW.%I IS NOT NULL', c), ' AND ') from jsonb_array_elements_text(x -> 'columns') c),
                         _gnomon.version_rel(v, nsp, x ->> 'ref'),
                         (select string_agg(format('gn_p.%I', c), ', ') from jsonb_array_elements_text(x -> 'ref_columns') c),
                         (select string_agg(format('NEW.%I', c), ', ') from jsonb_array_elements_text(x -> 'columns') c),
                         rel, x ->> 'name', 'gnomon_fk:' || nsp || '.' || (x ->> 'ref'));
  end loop;
  return out;
end $$;

-- The referenced side of a version's foreign keys, for a row going away (op = 'delete': OLD only)
-- or changing (op = 'update': OLD and NEW): refused while a row of the referencing table, as the
-- branch sees it, still points at the old value.
create function _gnomon.shape_refchecks(v int, nsp name, rel text, shape jsonb, op text) returns text language plpgsql stable
set search_path = pg_catalog, pg_temp as $$
declare out text := ''; x jsonb; oldv text; newv text;
begin
  for x in select e from jsonb_array_elements(coalesce(shape -> 'refby', '[]')) e loop
    oldv := (select string_agg(format('OLD.%I', c), ', ') from jsonb_array_elements_text(x -> 'ref_columns') c);
    newv := (select string_agg(format('NEW.%I', c), ', ') from jsonb_array_elements_text(x -> 'ref_columns') c);
    out := out || format(E'    IF %1$s THEN\n      PERFORM pg_advisory_xact_lock(hashtext(%2$L), hashtext(ROW(%3$s)::text));\n'
                         || E'      IF EXISTS (SELECT 1 FROM %4$s gn_c WHERE ROW(%5$s) = ROW(%3$s)) THEN\n'
                         || E'        RAISE EXCEPTION ''update or delete on table "%6$s" violates foreign key constraint "%7$s" on table "%8$s"'' USING ERRCODE = ''23503'';\n      END IF;\n    END IF;\n',
                         case when op = 'delete' then 'true' else format('ROW(%s) IS DISTINCT FROM ROW(%s)', oldv, newv) end,
                         'gnomon_fk:' || nsp || '.' || rel, oldv,
                         _gnomon.version_rel(v, nsp, x ->> 'from'),
                         (select string_agg(format('gn_c.%I', c), ', ') from jsonb_array_elements_text(x -> 'columns') c),
                         rel, x ->> 'name', x ->> 'from');
  end loop;
  return out;
end $$;

-- (Re)build a version's routing schemas: a view for every relation of each tracked schema, by
-- the shape of each table under the version.
create function _gnomon.gen_version(v int) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $g$
declare n name; vs text; r record; t gnomon.tracked; shape jsonb; x jsonb; sel text; joins text; keyj text; g record; rv text;
        cols text; nvals text; ovals text; fromr text; side_ins text; side_upd text; checks text; trg text; ex text;
        prev text := coalesce(current_setting('gnomon._in_ddl', true), ''); cmm text := current_setting('client_min_messages');
begin
  perform set_config('gnomon._in_ddl', '1', true);
  perform set_config('client_min_messages', 'warning', true);
  for n in select distinct x2.nsp from gnomon.tracked x2 where x2.nsp not like 'gnomon\_sv%' loop
    vs := _gnomon.version_schema(n, v);
    execute format('drop schema if exists %I cascade', vs);
    execute format('create schema %I', vs);
    execute format('alter schema %I owner to gnomon_reader', vs);
    execute format('grant usage on schema %I to public', vs);
    -- every relation first as a pass-through (a version's constraints may name another table's view)
    for r in select c2.relname from pg_class c2 join pg_namespace ns on ns.oid = c2.relnamespace
              where ns.nspname = 'gnomon_r_' || n and c2.relkind = 'v' order by c2.relname loop
      execute format('create view %I.%I as select * from %I.%I', vs, r.relname, 'gnomon_r_' || n, r.relname);
    end loop;
    for r in select c2.relname from pg_class c2 join pg_namespace ns on ns.oid = c2.relnamespace
              where ns.nspname = 'gnomon_r_' || n and c2.relkind = 'v' order by c2.relname loop
      select * into t from gnomon.tracked x2 where x2.nsp = n and x2.relname = r.relname;
      rv := format('%I.%I', 'gnomon_r_' || n, r.relname);
      shape := case when t.id is null then null else _gnomon.version_shape(v, t.id) end;
      if shape is not null and (shape ->> 'dropped')::bool then
        execute format('drop view %I.%I', vs, r.relname);
        execute format('create view %I.%I as select * from %s where _gnomon.dropped_on_branch(%L)', vs, r.relname, rv, r.relname);
        execute format('create trigger gnomon_iot instead of insert or update or delete on %I.%I for each row execute function _gnomon.dropped_on_branch_trg()', vs, r.relname);
      elsif shape is not null and (shape ->> 'changed')::bool then
        execute format('drop view %I.%I', vs, r.relname);
        keyj := _gnomon.key_sql(t, 'gn_r');
        sel := ''; joins := '';
        for x in select e from jsonb_array_elements(shape -> 'cols') e loop
          if x ->> 'side' is null then
            ex := format('gn_r.%I', x ->> 'base');
          elsif x ->> 'base' is null then
            ex := format('(case when gn_v%1$s.value is null then (%2$s)::%3$s else (gn_v%1$s.value #>> ''{}'')::%3$s end)',
                         x ->> 'side', coalesce(x ->> 'fill', 'null'), x ->> 'type');
          elsif x ->> 'up' is not null then
            ex := format('(case when gn_v%1$s.value is null then (select (%2$s)::%3$s from (select gn_r.%4$I as %5$I) gn_u) else (gn_v%1$s.value #>> ''{}'')::%3$s end)',
                         x ->> 'side', x ->> 'up', x ->> 'type', x ->> 'base', x ->> 'uname');
          else
            ex := format('(case when gn_v%1$s.value is null then gn_r.%2$I else (gn_v%1$s.value #>> ''{}'')::%3$s end)',
                         x ->> 'side', x ->> 'base', x ->> 'type');
          end if;
          sel := sel || case when sel = '' then '' else ', ' end || ex || ' as ' || quote_ident(x ->> 'name');
          if x ->> 'side' is not null then
            joins := joins || format(' left join lateral (select _gnomon.branch_column_value(%s, %s) as value) gn_v%s on true', x ->> 'side', keyj, x ->> 'side');
          end if;
        end loop;
        execute format('create view %I.%I as select %s from %s gn_r%s', vs, r.relname, sel, rv, joins);
        -- writes: main's columns (under their names on main, a retyped one through its down
        -- expression) through the routing view; the version's values to the side table
        select string_agg(quote_ident(e ->> 'base'), ', ' order by o),
               string_agg(case when e ->> 'up' is not null
                               then format('(select (%s)::%s from (select NEW.%I as %I) gn_d)', e ->> 'down', e ->> 'base_type', e ->> 'name', e ->> 'uname')
                               else format('NEW.%I', e ->> 'name') end, ', ' order by o),
               string_agg(case when e ->> 'up' is not null
                               then format('(select (%s)::%s from (select OLD.%I as %I) gn_d)', e ->> 'down', e ->> 'base_type', e ->> 'name', e ->> 'uname')
                               else format('OLD.%I', e ->> 'name') end, ', ' order by o)
          into cols, nvals, ovals
          from jsonb_array_elements(shape -> 'cols') with ordinality c(e, o)
         where e ->> 'base' is not null and not (e ->> 'gen')::bool;
        fromr := coalesce((select string_agg(format(E'    NEW.%I := r.%I;\n', e ->> 'name', e ->> 'base'), '' order by o)
                             from jsonb_array_elements(shape -> 'cols') with ordinality c(e, o)
                            where e ->> 'base' is not null and e ->> 'up' is null), '');
        side_ins := coalesce((select string_agg(format(E'    PERFORM _gnomon.set_branch_column(%s, %s, coalesce(to_jsonb(NEW.%I), ''null''));\n',
                                                       e ->> 'side', _gnomon.key_sql(t, 'NEW'), e ->> 'name'), '' order by o)
                                from jsonb_array_elements(shape -> 'cols') with ordinality c(e, o) where e ->> 'side' is not null), '');
        side_upd := coalesce((select string_agg(format(E'    IF NEW.%1$I IS DISTINCT FROM OLD.%1$I OR (%3$s) IS DISTINCT FROM (%4$s) THEN PERFORM _gnomon.set_branch_column(%2$s, %3$s, coalesce(to_jsonb(NEW.%1$I), ''null'')); END IF;\n',
                                                       e ->> 'name', e ->> 'side', _gnomon.key_sql(t, 'NEW'), _gnomon.key_sql(t, 'OLD')), '' order by o)
                                from jsonb_array_elements(shape -> 'cols') with ordinality c(e, o) where e ->> 'side' is not null), '');
        checks := _gnomon.shape_checks(v, n, vs, r.relname, shape, t.key_cols);
        trg := format($t$
create or replace function %1$s() returns trigger language plpgsql as $f$
declare r %2$s%%ROWTYPE;
begin
  IF TG_OP = 'DELETE' THEN
%11$s    DELETE FROM %2$s AS gn_t WHERE %3$s;
    RETURN OLD;
  END IF;
%4$s
  IF TG_OP = 'INSERT' THEN
    INSERT INTO %2$s AS gn_t (%5$s) VALUES (%6$s) RETURNING * INTO r;
%7$s%8$s
  ELSE
%12$s    IF ROW(%9$s) IS DISTINCT FROM ROW(%6$s) THEN
      UPDATE %2$s AS gn_t SET (%5$s) = ROW(%6$s) WHERE %3$s RETURNING * INTO r;
%7$s
    END IF;
%10$s
  END IF;
  RETURN NEW;
end $f$;$t$,
          format('%I.%I', vs, 'gn_w_' || r.relname), rv,
          (select string_agg(format('gn_t.%1$I = OLD.%1$I', k), ' AND ') from unnest(t.key_cols) k),
          checks, cols, nvals, fromr, side_ins, ovals, side_upd,
          _gnomon.shape_refchecks(v, n, r.relname, shape, 'delete'), _gnomon.shape_refchecks(v, n, r.relname, shape, 'update'));
        execute trg;
        execute format('create trigger gnomon_iot instead of insert or update or delete on %I.%I for each row execute function %I.%I()',
                       vs, r.relname, vs, 'gn_w_' || r.relname);
        execute format('alter function %I.%I() owner to gnomon_reader', vs, 'gn_w_' || r.relname);
        for x in select e from jsonb_array_elements(shape -> 'cols') e where e ->> 'def' is not null and not (e ->> 'gen')::bool loop
          begin
            execute format('alter view %I.%I alter column %I set default %s', vs, r.relname, x ->> 'name', x ->> 'def');
          exception when others then
            null;   -- a default that does not fit the column's new type: none on the branch
          end;
        end loop;
      end if;
      execute format('alter view %I.%I owner to gnomon_reader', vs, r.relname);
      -- the routing view's grants
      for g in select distinct a.grantee, a.privilege_type from information_schema.role_table_grants a
                where a.table_schema = 'gnomon_r_' || n and a.table_name = r.relname
                  and a.privilege_type in ('SELECT', 'INSERT', 'UPDATE', 'DELETE') and a.grantee <> 'gnomon_reader' loop
        execute format('grant %s on %I.%I to %s', g.privilege_type, vs, r.relname, case when g.grantee = 'PUBLIC' then 'public' else quote_ident(g.grantee) end);
      end loop;
    end loop;
  end loop;
  perform set_config('gnomon._in_ddl', prev, true);
  perform set_config('client_min_messages', cmm, true);
end $g$;

-- The tables of a shadow schema as (table, attribute) rows.
create function _gnomon.shadow_catalog(sh name) returns table(relname name, attnum int2, attname name, typ text, notnull bool, def text, dropped bool)
language sql stable as $$
  select c.relname, a.attnum, a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull,
         pg_get_expr(d.adbin, d.adrelid), a.attisdropped
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attnum > 0
    left join pg_attrdef d on d.adrelid = c.oid and d.adnum = a.attnum
   where n.nspname = sh and c.relkind in ('r', 'p')
$$;

-- The constraints of a shadow's tables (not NOT NULL: the catalog of columns holds that).
create function _gnomon.shadow_constraints(sh name) returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('table', c.relname, 'name', x.conname, 'type', x.contype::text, 'def', pg_get_constraintdef(x.oid),
           'expr', case when x.contype = 'c' then pg_get_expr(x.conbin, x.conrelid) end,
           'columns', (select jsonb_agg(a.attname order by k.o) from unnest(x.conkey) with ordinality k(n, o) join pg_attribute a on a.attrelid = x.conrelid and a.attnum = k.n),
           'ref', rc.relname, 'ref_nsp', rn.nspname,
           'ref_columns', (select jsonb_agg(a.attname order by k.o) from unnest(x.confkey) with ordinality k(n, o) join pg_attribute a on a.attrelid = x.confrelid and a.attnum = k.n))
           order by c.relname, x.conname), '[]')
    from pg_constraint x join pg_class c on c.oid = x.conrelid join pg_namespace n on n.oid = c.relnamespace
    left join pg_class rc on rc.oid = x.confrelid left join pg_namespace rn on rn.oid = rc.relnamespace
   where n.nspname = sh and x.contype in ('c', 'u', 'f', 'x', 'p')
$$;

-- The comments on a shadow's tables and columns.
create function _gnomon.shadow_comments(sh name) returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('table', c.relname, 'column', a.attname, 'text', d.description)), '[]')
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    join pg_description d on d.objoid = c.oid and d.classoid = 'pg_class'::regclass
    left join pg_attribute a on a.attrelid = c.oid and a.attnum = d.objsubid and d.objsubid > 0
   where n.nspname = sh and c.relkind in ('r', 'p')
$$;

-- A fingerprint of the real tables of the tracked schemas: DDL that escapes the shadow changes it.
create function _gnomon.real_fingerprint() returns text language sql stable as $$
  with rels as (select c.oid, c.relname, n.nspname from pg_class c join pg_namespace n on n.oid = c.relnamespace
                 where (n.nspname in (select nsp from gnomon.tracked) or n.nspname like 'gnomon\_r\_%') and c.relkind in ('r', 'p', 'v'))
  select md5(coalesce((select string_agg(format('%s.%s:%s:%s:%s:%s', r.nspname, r.relname, a.attnum, a.attname, a.atttypid, a.attnotnull), ',' order by r.nspname, r.relname, a.attnum)
                         from rels r join pg_attribute a on a.attrelid = r.oid and a.attnum > 0), '')
         || coalesce((select string_agg(i.indexrelid::text, ',' order by i.indexrelid) from pg_index i where i.indrelid in (select oid from rels)), '')
         || coalesce((select string_agg(x.oid::text, ',' order by x.oid) from pg_constraint x where x.conrelid in (select oid from rels)), '')
         || coalesce((select string_agg(x.oid::text, ',' order by x.oid) from pg_trigger x where x.tgrelid in (select oid from rels) and not x.tgisinternal), '')
         || coalesce((select string_agg(x.oid::text || coalesce(d.description, ''), ',' order by x.oid) from rels x left join pg_description d on d.objoid = x.oid), ''))
$$;

-- The shadow of a version: an empty clone of each tracked table of the schema with the version's
-- changes applied, rebuilt from the record (the changes' catalog form, never their SQL).
create function _gnomon.build_shadow(sh text, v int, nsp name) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; c gnomon.schema_change; tb text;
begin
  execute format('create schema %I', sh);
  for t in select * from gnomon.tracked x where x.nsp = build_shadow.nsp order by x.id loop
    execute format('create table %I.%I (like %s including all)', sh, t.relname, t.rel);
  end loop;
  for c in select sc.* from gnomon.schema_change sc where sc.version = any(_gnomon.version_lineage(v))
            order by array_position(_gnomon.version_lineage(v), sc.version), sc.seq loop
    tb := format('%I.%I', sh, split_part(c.tbl, '.', 2));
    if c.op = 'create_table' then
      execute format('create table %I.%I (like %I.%I including all)', sh, c.detail ->> 'table', _gnomon.hidden_schema(nsp, c.version), c.detail ->> 'table');
      continue;
    end if;
    continue when coalesce((c.detail ->> 'own_table')::bool, false) or to_regclass(tb) is null;
    if c.op = 'add_column' then
      if not exists (select 1 from pg_attribute a where a.attrelid = tb::regclass and a.attname = c.detail ->> 'column' and not a.attisdropped) then
        execute format('alter table %s add column %I %s%s%s', tb, c.detail ->> 'column', c.detail ->> 'type',
                       case when c.detail ->> 'default' is not null then ' default ' || (c.detail ->> 'default') else '' end,
                       case when coalesce((c.detail ->> 'not_null')::bool, false) then ' not null' else '' end);
      end if;
    elsif c.op = 'rename_column' then
      execute format('alter table %s rename column %I to %I', tb, c.detail ->> 'column', c.detail ->> 'to');
    elsif c.op = 'drop_column' then
      execute format('alter table %s drop column %I', tb, c.detail ->> 'column');
    elsif c.op = 'alter_type' then
      execute format('alter table %s alter column %I type %s using null::%s', tb, c.detail ->> 'column', c.detail ->> 'to', c.detail ->> 'to');
    elsif c.op = 'set_not_null' then
      execute format('alter table %s alter column %I set not null', tb, c.detail ->> 'column');
    elsif c.op = 'drop_not_null' then
      execute format('alter table %s alter column %I drop not null', tb, c.detail ->> 'column');
    elsif c.op = 'set_default' then
      execute format('alter table %s alter column %I set default %s', tb, c.detail ->> 'column', c.detail ->> 'default');
    elsif c.op = 'drop_default' then
      execute format('alter table %s alter column %I drop default', tb, c.detail ->> 'column');
    elsif c.op in ('add_check', 'add_unique') then
      execute format('alter table %s add constraint %I %s', tb, c.detail ->> 'name', c.detail ->> 'def');
    elsif c.op = 'add_fk' then
      execute format('alter table %s add constraint %I foreign key (%s) references %I.%I (%s)', tb, c.detail ->> 'name',
                     (select string_agg(quote_ident(x), ', ') from jsonb_array_elements_text(c.detail -> 'columns') x), sh, c.detail ->> 'ref',
                     (select string_agg(quote_ident(x), ', ') from jsonb_array_elements_text(c.detail -> 'ref_columns') x));
    elsif c.op = 'drop_constraint' then
      execute format('alter table %s drop constraint if exists %I', tb, c.detail ->> 'name');
    elsif c.op = 'drop_table' then
      execute format('drop table %s', tb);
    elsif c.op = 'create_index' then
      execute regexp_replace(c.detail ->> 'definition', ' ON (ONLY )?', ' ON \1' || quote_ident(sh) || '.');
    end if;
  end loop;
end $$;
revoke all on function _gnomon.build_shadow(text, int, name) from public;

-- gnomon.ddl, step 1: the checks, the branch's own version (forked on its first DDL), and a
-- shadow owned by the caller, so the statement runs with the caller's own privileges.
create function _gnomon.ddl_prepare(up text default null, down text default null) returns text
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch := gnomon._branch_row(gnomon.current_branch()); v int; snsp name; sh text := 'gnomon_shadow_' || pg_backend_pid();
        who text := _gnomon.who(); prev text := coalesce(current_setting('gnomon._in_ddl', true), ''); t record;
begin
  if b.id = 0 then raise exception 'gnomon.ddl prepares branch changes only' using errcode = '0A000', hint = '[gnomon:ddl_main]'; end if;
  if coalesce(current_setting('gnomon.as_of', true), '') <> '' then
    raise exception 'schema changes are refused while gnomon.as_of is set' using errcode = '25006', hint = '[gnomon:writes_refused_while_as_of]';
  end if;
  if not gnomon._may_write(b) or exists (select 1 from gnomon.confined x where x.role = who) then
    raise exception 'role % may not change the schema of branch "%"', who, b.name using errcode = '42501', hint = '[gnomon:schema_not_allowed]';
  end if;
  if b.status <> 'open' then raise exception 'branch "%" is %', b.name, b.status using errcode = '25006', hint = '[gnomon:branch_closed]'; end if;
  if b.kind = 'scratch' then raise exception 'schema changes are for logged branches' using errcode = '0A000', hint = '[gnomon:schema_scratch]'; end if;
  if (select count(distinct x.nsp) from gnomon.tracked x where x.nsp not like 'gnomon\_sv%') <> 1 then
    raise exception 'schema changes on a branch need the tracked tables in one schema' using errcode = '0A000', hint = '[gnomon:schema_one_schema]';
  end if;
  snsp := (select x.nsp from gnomon.tracked x where x.nsp not like 'gnomon\_sv%' limit 1);
  v := b.schema_version;
  if v is null or (select sv.created_on_branch from gnomon.schema_version sv where sv.id = v) is distinct from b.id then
    insert into gnomon.schema_version(parent, created_on_branch) values (v, b.id) returning id into v;
    update gnomon.branch set schema_version = v where id = b.id;
    perform _gnomon.gen_version(v);
  end if;
  perform set_config('gnomon._in_ddl', '1', true);
  if exists (select 1 from pg_namespace where nspname = sh) then execute format('drop schema %I cascade', sh); end if;
  perform _gnomon.build_shadow(sh, v, snsp);
  execute format('alter schema %I owner to %I', sh, who);
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = sh and c.relkind in ('r', 'p') loop
    execute format('alter table %I.%I owner to %I', sh, t.relname, who);
  end loop;
  perform set_config('gnomon._in_ddl', prev, true);
  delete from _gnomon.ddl_pending where pid = pg_backend_pid();
  insert into _gnomon.ddl_pending(pid, version, branch, shadow, nsp, who, before, idx, comments, fp, cons, up, down)
  values (pg_backend_pid(), v, b.id, sh, snsp, who,
          (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from _gnomon.shadow_catalog(sh::name) x),
          array(select pg_get_indexdef(i.indexrelid) from pg_index i join pg_class cl on cl.oid = i.indrelid join pg_namespace ns on ns.oid = cl.relnamespace where ns.nspname = sh),
          _gnomon.shadow_comments(sh::name), _gnomon.real_fingerprint(), _gnomon.shadow_constraints(sh::name), ddl_prepare.up, ddl_prepare.down);
  return sh;
end $$;

-- An index whose expression or predicate calls a function outside pg_catalog is refused: the
-- merge builds it on main as the merging role.
create function _gnomon.index_safe(idx oid) returns bool language sql stable as $$
  select not exists (select 1 from pg_depend d join pg_proc p on d.refclassid = 'pg_proc'::regclass and p.oid = d.refobjid
                      where d.classid = 'pg_class'::regclass and d.objid = idx and p.pronamespace <> 'pg_catalog'::regnamespace)
$$;

-- An expression a version evaluates in its views and the merge runs on main (a retyped column's
-- up and down): only pg_catalog functions and operators. Checked by making a view of it.
create function _gnomon.expr_safe(sh text, expr text, col text, typ text) returns bool language plpgsql volatile as $$
declare ok bool;
begin
  execute format('create view %I.gn_expr_check as select (%s) as x from (select null::%s as %I) gn_e', sh, expr, typ, col);
  select not exists (select 1 from pg_depend d join pg_rewrite w on w.oid = d.objid and d.classid = 'pg_rewrite'::regclass
                      join pg_proc p on d.refclassid = 'pg_proc'::regclass and p.oid = d.refobjid
                     where w.ev_class = format('%I.gn_expr_check', sh)::regclass and p.pronamespace <> 'pg_catalog'::regnamespace)
     and not exists (select 1 from pg_depend d join pg_rewrite w on w.oid = d.objid and d.classid = 'pg_rewrite'::regclass
                      join pg_operator o on d.refclassid = 'pg_operator'::regclass and o.oid = d.refobjid
                     where w.ev_class = format('%I.gn_expr_check', sh)::regclass and o.oprnamespace <> 'pg_catalog'::regnamespace)
    into ok;
  execute format('drop view %I.gn_expr_check', sh);
  return ok;
exception when others then
  raise exception 'the expression % does not work for a % column %: %', expr, typ, col, sqlerrm using errcode = '42804', hint = '[gnomon:bad_expression]';
end $$;

-- What an object of the shadow (a check constraint, a column default, a domain's check) depends on
-- outside pg_catalog: functions and operators. gnomon evaluates these with its own rights (checking
-- the branch's rows when a constraint is added, the merge's VALIDATE and inserts on main), so an
-- expression recorded from a branch may use only pg_catalog's; a function of the caller's would
-- otherwise run as gnomon.
create function _gnomon.unsafe_deps(cls regclass, obj oid) returns text language sql stable as $$
  select string_agg(distinct x, ', ') from (
    select p.oid::regprocedure::text as x from pg_depend d join pg_proc p on d.refclassid = 'pg_proc'::regclass and p.oid = d.refobjid
     where d.classid = cls and d.objid = obj and p.pronamespace <> 'pg_catalog'::regnamespace
    union all
    select o.oid::regoperator::text from pg_depend d join pg_operator o on d.refclassid = 'pg_operator'::regclass and o.oid = d.refobjid
     where d.classid = cls and d.objid = obj and o.oprnamespace <> 'pg_catalog'::regnamespace) s
$$;

create function _gnomon.require_safe(cls regclass, obj oid, what text) returns void language plpgsql stable as $$
declare u text := _gnomon.unsafe_deps(cls, obj);
begin
  if u is not null then
    raise exception '% on a branch may use pg_catalog functions and operators only, not %', what, u
      using errcode = '42501', hint = 'gnomon evaluates it with its own rights (checking the branch''s rows, the merge on main). [gnomon:unsafe_expression]';
  end if;
end $$;

-- The check constraints (col null: a new table), defaults and domain checks of a shadow table's
-- columns, as require_safe.
create function _gnomon.require_safe_rel(rel regclass, col text) returns void language plpgsql stable as $$
declare o oid; ty oid; tt record; o2 oid;
begin
  if col is null then
    for o in select x.oid from pg_constraint x where x.conrelid = rel and x.contype = 'c' loop
      perform _gnomon.require_safe('pg_constraint'::regclass, o, 'a check constraint');
    end loop;
  end if;
  for o, ty in select d.oid, a.atttypid from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
                where a.attrelid = rel and a.attnum > 0 and not a.attisdropped and (col is null or a.attname = col) loop
    if o is not null then perform _gnomon.require_safe('pg_attrdef'::regclass, o, 'a column default'); end if;
    -- a domain's checks run whenever a value is cast to it
    loop
      select t.typtype, t.typbasetype, t.typelem, t.typcategory into tt from pg_type t where t.oid = ty;
      exit when not found;
      if tt.typtype = 'd' then
        for o2 in select x.oid from pg_constraint x where x.contypid = ty loop
          perform _gnomon.require_safe('pg_constraint'::regclass, o2, 'a domain''s check');
        end loop;
        ty := tt.typbasetype;
      elsif tt.typcategory = 'A' and tt.typelem <> 0 then
        ty := tt.typelem;
      else
        exit;
      end if;
    end loop;
  end loop;
end $$;

-- Real DDL on a table the version created (its hidden table): it is a real table, so changes to it
-- are made for real, with its generated objects rebuilt.
create function _gnomon.own_ddl(tid int, sql text) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
begin
  perform set_config('gnomon._in_ddl', '1', true);
  perform _gnomon.drop_routing(tid, true);
  execute sql;
  perform _gnomon.generate(tid);
  perform set_config('gnomon._in_ddl', '1', true);
end $$;
revoke all on function _gnomon.own_ddl(int, text) from public;
revoke all on function _gnomon.require_safe(regclass, oid, text) from public;
revoke all on function _gnomon.require_safe_rel(regclass, text) from public;

-- What the branch reads of a table now (its version's view, or the routing view), for the checks
-- that existing rows meet a constraint the version adds.
create function _gnomon.branch_rel(v int, nsp name, rel text) returns text language sql stable as $$
  select case when to_regclass(format('%I.%I', _gnomon.version_schema($2, $1), $3)) is not null
              then format('%I.%I', _gnomon.version_schema($2, $1), $3) else format('%I.%I', 'gnomon_r_' || $2, $3) end
$$;

-- gnomon.ddl, step 3: what the statement did to the shadow, as operations; the new tables
-- created for real in the hidden schema; the version's views regenerated.
create function _gnomon.ddl_record(statement text) returns jsonb
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare p _gnomon.ddl_pending; b gnomon.branch; v int; snsp name; sh text; after jsonb; c gnomon.schema_change; ops jsonb := '[]'; r record; seq int; hid text;
        prev text := coalesce(current_setting('gnomon._in_ddl', true), ''); old jsonb; tid int; con record; tgt text; def text; first_seq int;
        cmm text := current_setting('client_min_messages'); own gnomon.schema_change; ownrel text; acons jsonb; brel text; nm text; bt gnomon.tracked;
        hit bool; x jsonb; ttbl text; related int[]; rt int;
begin
  select * into p from _gnomon.ddl_pending where pid = pg_backend_pid();
  if p.pid is null or p.who <> _gnomon.who() then
    raise exception 'no gnomon.ddl in progress in this session' using errcode = '55000', hint = '[gnomon:ddl_not_prepared]';
  end if;
  delete from _gnomon.ddl_pending where pid = pg_backend_pid();
  perform set_config('gnomon._ddl_internal', '1', true);
  v := p.version; snsp := p.nsp; sh := p.shadow;
  select * into b from gnomon.branch where id = p.branch;
  if _gnomon.real_fingerprint() <> p.fp then
    raise exception 'the statement changed real tables, not the branch: name tables without a schema in gnomon.ddl'
      using errcode = '42501', hint = '[gnomon:ddl_outside_branch]';
  end if;
  perform set_config('gnomon._in_ddl', '1', true);
  select coalesce(jsonb_agg(to_jsonb(x2)), '[]') into after from _gnomon.shadow_catalog(sh::name) x2;
  acons := _gnomon.shadow_constraints(sh::name);
  seq := coalesce((select max(sc.seq) from gnomon.schema_change sc where sc.version = v), 0);
  first_seq := seq + 1;

  -- dropped tables: a table the version created goes for real; main's is dropped at the merge
  for r in select distinct x2.value ->> 'relname' as rel from jsonb_array_elements(p.before) x2
            where not exists (select 1 from jsonb_array_elements(after) a where a.value ->> 'relname' = x2.value ->> 'relname') loop
    select z.* into own from gnomon.schema_change z where z.op = 'create_table' and z.detail ->> 'table' = r.rel
       and z.version = any(_gnomon.version_lineage(v)) limit 1;
    if own.id is not null then
      if own.version <> v then
        raise exception 'table % was created by the version this branch stands on: drop it there', r.rel using errcode = '0A000', hint = '[gnomon:drop_table_parent_version]';
      end if;
      select x2.* into bt from gnomon.tracked x2 where x2.nsp = _gnomon.hidden_schema(snsp, own.version) and x2.relname = r.rel;
      related := array(select distinct o.id from gnomon.tracked o join pg_constraint k on k.contype = 'f'
                          and ((k.conrelid = o.rel and k.confrelid = bt.rel) or (k.confrelid = o.rel and k.conrelid = bt.rel))
                        where o.rel <> bt.rel);
      perform gnomon.untrack(bt.rel);
      perform set_config('gnomon._in_ddl', '1', true);
      execute format('drop table %s cascade', bt.rel);
      foreach rt in array related loop
        perform _gnomon.drop_routing(rt, true);
        perform _gnomon.generate(rt);
      end loop;
      perform set_config('gnomon._in_ddl', '1', true);
      delete from gnomon.schema_change z where z.version = v and z.tbl = format('%I.%I', snsp, r.rel);
      own := null;
    else
      select x2.* into bt from gnomon.tracked x2 where x2.nsp = snsp and x2.relname = r.rel;
      if exists (select 1 from pg_constraint k join gnomon.tracked o on o.rel = k.conrelid
                  where k.contype = 'f' and k.confrelid = bt.rel and k.conrelid <> bt.rel
                    and exists (select 1 from jsonb_array_elements(after) y where y.value ->> 'relname' = o.relname)) then
        raise exception 'table % is referenced by another table''s foreign key: drop that first', r.rel using errcode = '2BP01', hint = '[gnomon:drop_table_referenced]';
      end if;
      seq := seq + 1;
      insert into gnomon.schema_change(version, seq, sql, op, tbl, detail)
      values (v, seq, statement, 'drop_table', format('%I.%I', snsp, r.rel), jsonb_build_object('table', r.rel));
    end if;
    ops := ops || jsonb_build_object('op', 'drop_table', 'table', r.rel);
  end loop;

  -- new tables: created for real, empty, in the version's hidden schema, owned by the caller, tracked
  for r in select distinct a.value ->> 'relname' as rel from jsonb_array_elements(after) a
            where not exists (select 1 from jsonb_array_elements(p.before) x2 where x2.value ->> 'relname' = a.value ->> 'relname') loop
    if not exists (select 1 from pg_index i where i.indrelid = format('%I.%I', sh, r.rel)::regclass and i.indisprimary) then
      raise exception 'a table created on a branch needs a primary key (tracking does): %', r.rel using errcode = '0A000', hint = '[gnomon:create_table_key]';
    end if;
    if to_regclass(format('%I.%I', snsp, r.rel)) is not null
       and not exists (select 1 from gnomon.schema_change z where z.version = any(_gnomon.version_lineage(v)) and z.op = 'drop_table' and z.detail ->> 'table' = r.rel) then
      raise exception 'relation %.% exists on main', snsp, r.rel using errcode = '42P07', hint = '[gnomon:create_table_exists]';
    end if;
    perform _gnomon.require_safe_rel(format('%I.%I', sh, r.rel)::regclass, null);
    hid := _gnomon.hidden_schema(snsp, v);
    if not exists (select 1 from pg_namespace where nspname = hid) then
      execute format('create schema %I', hid);
      execute format('grant usage on schema %I to public', hid);
    end if;
    execute format('create table %I.%I (like %I.%I including all)', hid, r.rel, sh, r.rel);
    -- a serial column's default still names the shadow's sequence, which goes when the shadow is
    -- dropped (and the default with it): the table gets sequences of its own, owned by its columns,
    -- so they move to main with it at the merge (identity columns got theirs from LIKE)
    for con in select a.attname, s.relname as seqname, format_type(ps.seqtypid, null) as typ, ps.seqstart, ps.seqincrement,
                      ps.seqmin, ps.seqmax, ps.seqcache, ps.seqcycle
                 from pg_attrdef d
                 join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
                 join pg_depend dp on dp.classid = 'pg_attrdef'::regclass and dp.objid = d.oid and dp.refclassid = 'pg_class'::regclass
                 join pg_class s on s.oid = dp.refobjid and s.relkind = 'S'
                 join pg_namespace sn on sn.oid = s.relnamespace and sn.nspname = sh
                 join pg_sequence ps on ps.seqrelid = s.oid
                where d.adrelid = format('%I.%I', hid, r.rel)::regclass loop
      execute format('create sequence %I.%I as %s increment %s minvalue %s maxvalue %s start %s cache %s %s owned by %I.%I.%I',
                     hid, con.seqname, con.typ, con.seqincrement, con.seqmin, con.seqmax, con.seqstart, con.seqcache,
                     case when con.seqcycle then 'cycle' else 'no cycle' end, hid, r.rel, con.attname);
      execute format('alter table %I.%I alter column %I set default nextval(%L::regclass)', hid, r.rel, con.attname,
                     format('%I.%I', hid, con.seqname));
    end loop;
    -- foreign keys, to main's tables or to the version's own
    for con in select x2.conname, pg_get_constraintdef(x2.oid) as def, cr.relname as ref, cn.nspname as refnsp
                 from pg_constraint x2 join pg_class cr on cr.oid = x2.confrelid join pg_namespace cn on cn.oid = cr.relnamespace
                where x2.conrelid = format('%I.%I', sh, r.rel)::regclass and x2.contype = 'f' loop
      tgt := _gnomon.own_ref(v, snsp, sh, con.refnsp, con.ref);
      def := regexp_replace(con.def, 'REFERENCES \S+\(', 'REFERENCES ' || tgt || '(');
      execute format('alter table %I.%I add constraint %I %s', hid, r.rel, con.conname, def);
    end loop;
    execute format('alter table %I.%I owner to %I', hid, r.rel, p.who);
    seq := seq + 1;
    insert into gnomon.schema_change(version, seq, sql, op, tbl, detail)
    values (v, seq, statement, 'create_table', format('%I.%I', snsp, r.rel), jsonb_build_object('table', r.rel));
    perform set_config('gnomon._in_ddl', prev, true);
    perform gnomon.track(format('%I.%I', hid, r.rel)::regclass);
    perform set_config('gnomon._in_ddl', '1', true);
    ops := ops || jsonb_build_object('op', 'create_table', 'table', r.rel);
  end loop;

  -- columns of tables that were there, by attribute number
  for r in select a.value as col from jsonb_array_elements(after) a
            where exists (select 1 from jsonb_array_elements(p.before) x2 where x2.value ->> 'relname' = a.value ->> 'relname')
              and not exists (select 1 from gnomon.schema_change z where z.version = v and z.seq >= first_seq and z.op = 'create_table' and z.detail ->> 'table' = a.value ->> 'relname')
            order by a.value ->> 'relname', (a.value ->> 'attnum')::int loop
    old := (select x2.value from jsonb_array_elements(p.before) x2
             where x2.value ->> 'relname' = r.col ->> 'relname' and x2.value ->> 'attnum' = r.col ->> 'attnum');
    ttbl := format('%I.%I', snsp, r.col ->> 'relname');
    if not coalesce((r.col ->> 'dropped')::bool, false)
       and (old is null or (old ->> 'def') is distinct from (r.col ->> 'def') or (old ->> 'typ') is distinct from (r.col ->> 'typ')) then
      perform _gnomon.require_safe_rel(format('%I.%I', sh, r.col ->> 'relname')::regclass, r.col ->> 'attname');
    end if;
    -- a table this version created: changes to it are made for real on its hidden table
    own := null;
    select z.* into own from gnomon.schema_change z where z.op = 'create_table' and z.detail ->> 'table' = r.col ->> 'relname'
       and z.version = any(_gnomon.version_lineage(v)) limit 1;
    tid := null; ownrel := null;
    if own.id is not null then
      ownrel := format('%I.%I', _gnomon.hidden_schema(snsp, own.version), r.col ->> 'relname');
      tid := (select x2.id from gnomon.tracked x2 where x2.rel = ownrel::regclass);
    else
      select x2.* into bt from gnomon.tracked x2 where x2.nsp = snsp and x2.relname = r.col ->> 'relname';
      brel := _gnomon.branch_rel(v, snsp, r.col ->> 'relname');
    end if;
    if old is null then
      continue when (r.col ->> 'dropped')::bool;
      if (r.col ->> 'def') is not null and not _gnomon.constant_default(r.col ->> 'def') and own.id is null then
        raise exception 'column %.% has a default that cannot be copied to every row: %', r.col ->> 'relname', r.col ->> 'attname', r.col ->> 'def'
          using errcode = '0A000', hint = 'Use a constant default, or add the column on main. [gnomon:volatile_default]';
      end if;
      if (r.col ->> 'notnull')::bool and (r.col ->> 'def') is null and own.id is null then
        raise exception 'a NOT NULL column needs a default on a branch: %.%', r.col ->> 'relname', r.col ->> 'attname'
          using errcode = '0A000', hint = '[gnomon:not_null_without_default]';
      end if;
      if own.id is not null then
        perform _gnomon.own_ddl(tid, format('alter table %s add column %I %s%s%s', ownrel, r.col ->> 'attname', r.col ->> 'typ',
          case when r.col ->> 'def' is not null then ' default ' || (r.col ->> 'def') else '' end,
          case when (r.col ->> 'notnull')::bool then ' not null' else '' end));
      end if;
      seq := seq + 1;
      insert into gnomon.schema_change(version, seq, sql, op, tbl, detail)
      values (v, seq, statement, 'add_column', ttbl,
              jsonb_build_object('column', r.col ->> 'attname', 'type', r.col ->> 'typ', 'default', r.col ->> 'def',
                                 'not_null', (r.col ->> 'notnull')::bool, 'own_table', own.id is not null));
      ops := ops || jsonb_build_object('op', 'add_column', 'table', r.col ->> 'relname', 'column', r.col ->> 'attname', 'type', r.col ->> 'typ');
      continue;
    end if;
    continue when (old ->> 'dropped')::bool;
    -- drops, renames and type changes; NOT NULL and defaults
    if (r.col ->> 'dropped')::bool then
      nm := old ->> 'attname';
      if own.id is null then
        if nm = any(bt.key_cols) then
          raise exception 'a key column cannot be dropped on a branch: %.%', r.col ->> 'relname', nm using errcode = '0A000', hint = '[gnomon:key_column]';
        end if;
        if exists (select 1 from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
                    where a.attrelid = bt.rel and a.attname = nm and a.attnotnull and d.adbin is null) then
          raise exception 'dropping %.%: main''s NOT NULL column without a default could not be filled by inserts on the branch', r.col ->> 'relname', nm
            using errcode = '0A000', hint = 'Give it a default on main first, or drop it on main. [gnomon:drop_not_null_column]';
        end if;
      else
        perform _gnomon.own_ddl(tid, format('alter table %s drop column %I', ownrel, nm));
      end if;
      seq := seq + 1;
      insert into gnomon.schema_change(version, seq, sql, op, tbl, detail)
      values (v, seq, statement, 'drop_column', ttbl, jsonb_build_object('column', nm, 'own_table', own.id is not null));
      ops := ops || jsonb_build_object('op', 'drop_column', 'table', r.col ->> 'relname', 'column', nm);
      continue;
    end if;
    if old ->> 'attname' <> r.col ->> 'attname' then
      nm := old ->> 'attname';
      if own.id is null then
        if exists (select 1 from gnomon.tracked x2 where x2.rel = bt.rel and nm = any(x2.key_cols)) then
          raise exception 'a key column cannot be renamed on a branch: %.%', r.col ->> 'relname', nm using errcode = '0A000', hint = '[gnomon:key_column]';
        end if;
        if exists (select 1 from gnomon.schema_change z where z.version = any(_gnomon.version_lineage(v)) and z.tbl = ttbl
                      and z.op in ('add_check', 'add_unique', 'add_fk') and (z.detail -> 'columns' ? nm or _gnomon.mentions(lower(coalesce(z.detail ->> 'expr', '')), nm))) then
          raise exception 'column %.% is named by a constraint this branch added: drop the constraint first', r.col ->> 'relname', nm
            using errcode = '0A000', hint = '[gnomon:rename_constrained]';
        end if;
      else
        perform _gnomon.own_ddl(tid, format('alter table %s rename column %I to %I', ownrel, nm, r.col ->> 'attname'));
      end if;
      seq := seq + 1;
      insert into gnomon.schema_change(version, seq, sql, op, tbl, detail)
      values (v, seq, statement, 'rename_column', ttbl, jsonb_build_object('column', nm, 'to', r.col ->> 'attname', 'own_table', own.id is not null));
      ops := ops || jsonb_build_object('op', 'rename_column', 'table', r.col ->> 'relname', 'column', nm, 'to', r.col ->> 'attname');
    end if;
    nm := r.col ->> 'attname';
    if old ->> 'typ' <> r.col ->> 'typ' then
      if own.id is null then
        if nm = any(bt.key_cols) then
          raise exception 'a key column cannot change type on a branch: %.%', r.col ->> 'relname', nm using errcode = '0A000', hint = '[gnomon:key_column]';
        end if;
        if p.up is not null and not _gnomon.expr_safe(sh, p.up, nm, old ->> 'typ') then
          raise exception 'the up expression may use pg_catalog functions and operators only' using errcode = '42501', hint = '[gnomon:unsafe_expression]';
        end if;
        if p.down is not null and not _gnomon.expr_safe(sh, p.down, nm, r.col ->> 'typ') then
          raise exception 'the down expression may use pg_catalog functions and operators only' using errcode = '42501', hint = '[gnomon:unsafe_expression]';
        end if;
        -- main's rows must convert, and the branch's writes must convert back
        perform _gnomon.expr_safe(sh, format('(%s)::%s', coalesce(p.up, format('%I::%s', nm, r.col ->> 'typ')), r.col ->> 'typ'), nm, old ->> 'typ');
        perform _gnomon.expr_safe(sh, format('(%s)::%s', coalesce(p.down, format('%I::%s', nm, old ->> 'typ')), old ->> 'typ'), nm, r.col ->> 'typ');
      else
        perform _gnomon.own_ddl(tid, format('alter table %s alter column %I type %s using (%s)', ownrel, nm, r.col ->> 'typ',
                                            coalesce(p.up, format('%I::%s', nm, r.col ->> 'typ'))));
      end if;
      seq := seq + 1;
      insert into gnomon.schema_change(version, seq, sql, op, tbl, detail)
      values (v, seq, statement, 'alter_type', ttbl,
              jsonb_strip_nulls(jsonb_build_object('column', nm, 'from', old ->> 'typ', 'to', r.col ->> 'typ', 'up', p.up, 'down', p.down)) || jsonb_build_object('own_table', own.id is not null));
      ops := ops || jsonb_build_object('op', 'alter_type', 'table', r.col ->> 'relname', 'column', nm, 'type', r.col ->> 'typ');
    end if;
    if old ->> 'notnull' <> r.col ->> 'notnull' then
      if (r.col ->> 'notnull')::bool then
        if own.id is null then
          execute format('select exists (select 1 from %s where %I is null)', brel, nm) into hit;
          if hit then
            raise exception 'column "%" of relation "%" contains null values on the branch', nm, r.col ->> 'relname' using errcode = '23502', hint = '[gnomon:not_null_violated]';
          end if;
        else
          perform _gnomon.own_ddl(tid, format('alter table %s alter column %I set not null', ownrel, nm));
        end if;
        seq := seq + 1;
        insert into gnomon.schema_change(version, seq, sql, op, tbl, detail)
        values (v, seq, statement, 'set_not_null', ttbl, jsonb_build_object('column', nm, 'own_table', own.id is not null));
        ops := ops || jsonb_build_object('op', 'set_not_null', 'table', r.col ->> 'relname', 'column', nm);
      else
        if own.id is null and exists (select 1 from pg_attribute a where a.attrelid = bt.rel and a.attname = nm and a.attnotnull) then
          raise exception 'main''s NOT NULL on %.% stays on the branch''s writes: drop it on main', r.col ->> 'relname', nm
            using errcode = '0A000', hint = '[gnomon:main_constraint]';
        elsif own.id is not null then
          perform _gnomon.own_ddl(tid, format('alter table %s alter column %I drop not null', ownrel, nm));
        end if;
        seq := seq + 1;
        insert into gnomon.schema_change(version, seq, sql, op, tbl, detail)
        values (v, seq, statement, 'drop_not_null', ttbl, jsonb_build_object('column', nm, 'own_table', own.id is not null));
        ops := ops || jsonb_build_object('op', 'drop_not_null', 'table', r.col ->> 'relname', 'column', nm);
      end if;
    end if;
    if (old ->> 'def') is distinct from (r.col ->> 'def') then
      if own.id is not null then
        perform _gnomon.own_ddl(tid, case when r.col ->> 'def' is null then format('alter table %s alter column %I drop default', ownrel, nm)
                                          else format('alter table %s alter column %I set default %s', ownrel, nm, r.col ->> 'def') end);
      end if;
      seq := seq + 1;
      insert into gnomon.schema_change(version, seq, sql, op, tbl, detail)
      values (v, seq, statement, case when r.col ->> 'def' is null then 'drop_default' else 'set_default' end, ttbl,
              jsonb_strip_nulls(jsonb_build_object('column', nm, 'default', r.col ->> 'def')) || jsonb_build_object('own_table', own.id is not null));
      ops := ops || jsonb_build_object('op', case when r.col ->> 'def' is null then 'drop_default' else 'set_default' end, 'table', r.col ->> 'relname', 'column', nm);
    end if;
  end loop;

  -- constraints added and dropped on tables that were there
  for x in select a from jsonb_array_elements(acons) a
            where exists (select 1 from jsonb_array_elements(p.before) y where y.value ->> 'relname' = a ->> 'table')
              and not exists (select 1 from jsonb_array_elements(p.cons) y where y.value ->> 'table' = a ->> 'table' and y.value ->> 'name' = a ->> 'name') loop
    ttbl := format('%I.%I', snsp, x ->> 'table');
    own := null;
    select z.* into own from gnomon.schema_change z where z.op = 'create_table' and z.detail ->> 'table' = x ->> 'table'
       and z.version = any(_gnomon.version_lineage(v)) limit 1;
    if x ->> 'type' in ('x', 'p') then
      raise exception 'exclusion and primary key constraints cannot be added on a branch' using errcode = '0A000', hint = '[gnomon:branch_constraint]';
    end if;
    if x ->> 'type' = 'c' then
      perform _gnomon.require_safe('pg_constraint'::regclass,
        (select k.oid from pg_constraint k where k.conrelid = format('%I.%I', sh, x ->> 'table')::regclass and k.conname = x ->> 'name'),
        'a check constraint');
    end if;
    if own.id is not null then
      ownrel := format('%I.%I', _gnomon.hidden_schema(snsp, own.version), x ->> 'table');
      def := x ->> 'def';
      if x ->> 'type' = 'f' then
        def := regexp_replace(def, 'REFERENCES \S+\(', 'REFERENCES ' || _gnomon.own_ref(v, snsp, sh, x ->> 'ref_nsp', x ->> 'ref') || '(');
      end if;
      perform _gnomon.own_ddl((select x2.id from gnomon.tracked x2 where x2.rel = ownrel::regclass),
                              format('alter table %s add constraint %I %s', ownrel, x ->> 'name', def));
    else
      brel := _gnomon.branch_rel(v, snsp, x ->> 'table');
      if x ->> 'type' = 'c' then
        execute format('select exists (select 1 from %s gn_x where not (%s))', brel, x ->> 'expr') into hit;
        if hit then raise exception 'check constraint "%" of relation "%" is violated by some row on the branch', x ->> 'name', x ->> 'table' using errcode = '23514', hint = '[gnomon:check_violated]'; end if;
      elsif x ->> 'type' = 'u' then
        execute format('select exists (select 1 from %s where %s group by %s having count(*) > 1)', brel,
                       (select string_agg(format('%I is not null', c2), ' and ') from jsonb_array_elements_text(x -> 'columns') c2),
                       (select string_agg(quote_ident(c2), ', ') from jsonb_array_elements_text(x -> 'columns') c2)) into hit;
        if hit then raise exception 'could not add unique constraint "%": the branch has duplicate values', x ->> 'name' using errcode = '23505', hint = '[gnomon:unique_violated]'; end if;
      elsif x ->> 'type' = 'f' then
        if x ->> 'ref_nsp' <> sh then
          raise exception 'a foreign key on a branch references a table of the schema, by its name without a schema' using errcode = '0A000', hint = '[gnomon:fk_outside]';
        end if;
        execute format('select exists (select 1 from %s gn_c where %s and not exists (select 1 from %s gn_p where row(%s) = row(%s)))', brel,
                       (select string_agg(format('gn_c.%I is not null', c2), ' and ') from jsonb_array_elements_text(x -> 'columns') c2),
                       _gnomon.branch_rel(v, snsp, x ->> 'ref'),
                       (select string_agg(format('gn_p.%I', c2), ', ') from jsonb_array_elements_text(x -> 'ref_columns') c2),
                       (select string_agg(format('gn_c.%I', c2), ', ') from jsonb_array_elements_text(x -> 'columns') c2)) into hit;
        if hit then raise exception 'foreign key "%" is violated by some row on the branch', x ->> 'name' using errcode = '23503', hint = '[gnomon:fk_violated]'; end if;
      end if;
    end if;
    seq := seq + 1;
    insert into gnomon.schema_change(version, seq, sql, op, tbl, detail)
    values (v, seq, statement, case x ->> 'type' when 'c' then 'add_check' when 'u' then 'add_unique' else 'add_fk' end, ttbl,
            jsonb_build_object('name', x ->> 'name', 'def', x ->> 'def', 'expr', x ->> 'expr', 'columns', x -> 'columns',
                               'ref', x ->> 'ref', 'ref_columns', x -> 'ref_columns', 'own_table', own.id is not null));
    ops := ops || jsonb_build_object('op', case x ->> 'type' when 'c' then 'add_check' when 'u' then 'add_unique' else 'add_fk' end,
                                     'table', x ->> 'table', 'name', x ->> 'name');
  end loop;
  for x in select y from jsonb_array_elements(p.cons) y
            where exists (select 1 from jsonb_array_elements(after) a where a.value ->> 'relname' = y ->> 'table')
              and not exists (select 1 from jsonb_array_elements(acons) a where a ->> 'table' = y ->> 'table' and a ->> 'name' = y ->> 'name') loop
    ttbl := format('%I.%I', snsp, x ->> 'table');
    own := null;
    select z.* into own from gnomon.schema_change z where z.op = 'create_table' and z.detail ->> 'table' = x ->> 'table'
       and z.version = any(_gnomon.version_lineage(v)) limit 1;
    if own.id is not null then
      ownrel := format('%I.%I', _gnomon.hidden_schema(snsp, own.version), x ->> 'table');
      perform _gnomon.own_ddl((select x2.id from gnomon.tracked x2 where x2.rel = ownrel::regclass),
                              format('alter table %s drop constraint %I', ownrel, x ->> 'name'));
    elsif not exists (select 1 from gnomon.schema_change z where z.version = any(_gnomon.version_lineage(v)) and z.tbl = ttbl
                         and z.op in ('add_check', 'add_unique', 'add_fk') and z.detail ->> 'name' = x ->> 'name') then
      raise exception 'main''s constraint "%" stays on the branch''s writes: drop it on main', x ->> 'name' using errcode = '0A000', hint = '[gnomon:main_constraint]';
    end if;
    seq := seq + 1;
    insert into gnomon.schema_change(version, seq, sql, op, tbl, detail)
    values (v, seq, statement, 'drop_constraint', ttbl, jsonb_build_object('name', x ->> 'name', 'own_table', own.id is not null));
    ops := ops || jsonb_build_object('op', 'drop_constraint', 'table', x ->> 'table', 'name', x ->> 'name');
  end loop;

  -- indexes: recorded, built at merge (they change no result on the branch); a unique index on
  -- main's table is a unique constraint the version's view enforces
  for r in select i.indexrelid as oid, pg_get_indexdef(i.indexrelid) as def, i.indisunique, cl.relname, i.indexprs is null and i.indpred is null as plain,
                  (select jsonb_agg(a.attname order by k.o) from unnest(i.indkey::int2[]) with ordinality k(n, o) join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.n) as cols,
                  (select c3.relname from pg_class c3 where c3.oid = i.indexrelid) as iname
             from pg_index i join pg_class cl on cl.oid = i.indrelid
              join pg_namespace ns on ns.oid = cl.relnamespace
             where ns.nspname = sh and pg_get_indexdef(i.indexrelid) <> all(p.idx)
               and not exists (select 1 from pg_constraint k where k.conindid = i.indexrelid) loop
    -- a table this statement created brought its indexes with it
    continue when exists (select 1 from gnomon.schema_change z where z.version = v and z.op = 'create_table' and z.detail ->> 'table' = r.relname and z.seq >= first_seq);
    if not _gnomon.index_safe(r.oid) then
      raise exception 'an index on a branch may call pg_catalog functions only' using errcode = '0A000', hint = '[gnomon:index_function]';
    end if;
    def := regexp_replace(r.def, ' ON (ONLY )?' || quote_ident(sh) || '\.', ' ON \1');
    own := null;
    select z.* into own from gnomon.schema_change z where z.op = 'create_table' and z.detail ->> 'table' = r.relname
       and z.version = any(_gnomon.version_lineage(v)) limit 1;
    if r.indisunique and own.id is not null then
      ownrel := format('%I.%I', _gnomon.hidden_schema(snsp, own.version), r.relname);
      perform _gnomon.own_ddl((select x2.id from gnomon.tracked x2 where x2.rel = ownrel::regclass),
                              regexp_replace(def, ' ON (ONLY )?' || quote_ident(r.relname) || ' ', ' ON \1' || ownrel || ' '));
      seq := seq + 1;
      insert into gnomon.schema_change(version, seq, sql, op, tbl, detail)
      values (v, seq, statement, 'create_index', format('%I.%I', snsp, r.relname), jsonb_build_object('definition', def, 'own_table', true));
    elsif r.indisunique then
      if not r.plain then
        raise exception 'a unique index on a branch takes plain columns' using errcode = '0A000', hint = '[gnomon:unique_index]';
      end if;
      brel := _gnomon.branch_rel(v, snsp, r.relname);
      execute format('select exists (select 1 from %s where %s group by %s having count(*) > 1)', brel,
                     (select string_agg(format('%I is not null', c2), ' and ') from jsonb_array_elements_text(r.cols) c2),
                     (select string_agg(quote_ident(c2), ', ') from jsonb_array_elements_text(r.cols) c2)) into hit;
      if hit then raise exception 'could not create unique index "%": the branch has duplicate values', r.iname using errcode = '23505', hint = '[gnomon:unique_violated]'; end if;
      seq := seq + 1;
      insert into gnomon.schema_change(version, seq, sql, op, tbl, detail)
      values (v, seq, statement, 'add_unique', format('%I.%I', snsp, r.relname),
              jsonb_build_object('name', r.iname, 'columns', r.cols, 'index', def, 'own_table', false,
                                 'def', 'UNIQUE (' || (select string_agg(quote_ident(c2), ', ') from jsonb_array_elements_text(r.cols) c2) || ')'));
    else
      seq := seq + 1;
      insert into gnomon.schema_change(version, seq, sql, op, tbl, detail)
      values (v, seq, statement, 'create_index', format('%I.%I', snsp, r.relname), jsonb_build_object('definition', def));
    end if;
    ops := ops || jsonb_build_object('op', case when r.indisunique and own.id is null then 'add_unique' else 'create_index' end, 'table', r.relname, 'definition', def);
  end loop;
  -- comments, replayed at merge from what the shadow's catalog holds (never the statement's text)
  for r in select x2.value as cm from jsonb_array_elements(_gnomon.shadow_comments(sh::name)) x2
            where not exists (select 1 from jsonb_array_elements(p.comments) y where y.value = x2.value)
           union all
           select jsonb_set(y.value, '{text}', 'null') from jsonb_array_elements(p.comments) y
            where not exists (select 1 from jsonb_array_elements(_gnomon.shadow_comments(sh::name)) x2
                               where x2.value ->> 'table' = y.value ->> 'table' and x2.value -> 'column' = y.value -> 'column')
              and exists (select 1 from jsonb_array_elements(after) a where a.value ->> 'relname' = y.value ->> 'table') loop
    seq := seq + 1;
    insert into gnomon.schema_change(version, seq, sql, op, tbl, detail)
    values (v, seq, statement, 'comment', format('%I.%I', snsp, r.cm ->> 'table'), r.cm);
    ops := ops || (r.cm || jsonb_build_object('op', 'comment'));
  end loop;
  if jsonb_array_length(ops) = 0 then
    raise exception 'the statement changed nothing gnomon.ddl understands' using errcode = '0A000', hint = '[gnomon:ddl_nothing]';
  end if;
  perform set_config('client_min_messages', 'warning', true);
  execute format('drop schema %I cascade', sh);
  perform set_config('client_min_messages', cmm, true);
  perform _gnomon.gen_version(v);
  perform set_config('gnomon._in_ddl', prev, true);
  perform set_config('gnomon._ddl_internal', '', true);
  perform gnomon._bump();
  return jsonb_build_object('version', v, 'branch', b.name, 'changes', ops);
end $$;

-- Where a hidden table's foreign key points: main's table, or another table of the version.
create function _gnomon.own_ref(v int, snsp name, sh text, refnsp text, ref text) returns text language sql stable as $$
  select case when $4 <> $3 then format('%I.%I', $4, $5)
              when to_regclass(format('%I.%I', $2, $5)) is not null then format('%I.%I', $2, $5)
              else coalesce((select format('%I.%I', _gnomon.hidden_schema($2, z.version), $5) from gnomon.schema_change z
                              where z.op = 'create_table' and z.detail ->> 'table' = $5 and z.version = any(_gnomon.version_lineage($1)) limit 1),
                            format('%I.%I', _gnomon.hidden_schema($2, $1), $5)) end
$$;

-- A default copied to every row when a column is added: a literal, optionally cast.
create function _gnomon.constant_default(d text) returns bool language sql immutable as $$
  select d ~ '^(''([^'']|'''')*''|-?[0-9]+(\.[0-9]+)?|true|false|NULL)(::[a-z][a-z0-9_ ]*(\([0-9, ]+\))?(\[\])?)?$'
      or d ~ '^\(-?[0-9]+(\.[0-9]+)?\)(::[a-z][a-z0-9_ ]*)?$'
$$;

-- Schema changes on a branch. On a branch session the statement runs against the
-- version's shadow as the caller, and what it did is recorded; the session then reads the new
-- shape. On main it is plain DDL. up and down: for a column whose type changes, the expressions
-- that convert main's values to the new type and the branch's writes back (default: casts).
create function gnomon.ddl(statement text, up text default null, down text default null) returns jsonb language plpgsql volatile as $$
declare sh text; sp text := current_setting('search_path'); prev text := coalesce(current_setting('gnomon._in_ddl', true), '');
        b text := gnomon.current_branch(); res jsonb;
begin
  if b = 'main' then
    execute statement;
    return jsonb_build_object('branch', 'main', 'applied', true);
  end if;
  sh := _gnomon.ddl_prepare(up, down);
  perform set_config('search_path', quote_ident(sh) || ', pg_catalog', true);
  perform set_config('gnomon._in_ddl', '1', true);
  execute statement;
  perform set_config('gnomon._in_ddl', prev, true);
  perform set_config('search_path', sp, true);
  res := _gnomon.ddl_record(statement);
  -- the session reads the version's shape from now on
  perform gnomon.use(b, null, coalesce(current_setting('gnomon._local_route', true), '') = '1');
  return res || jsonb_build_object('search_path', current_setting('search_path'));
end $$;

-- The schema changes of a branch (the PR comment's "Schema changes" table).
create function gnomon.schema_changes(branch text) returns table(version int, seq int, op text, tbl text, detail jsonb, sql text)
language sql stable as $$
  select sc.version, sc.seq, sc.op, sc.tbl, sc.detail, sc.sql from gnomon.schema_change sc
   where sc.version = any(_gnomon.version_lineage((gnomon._branch_row($1)).schema_version))
   order by array_position(_gnomon.version_lineage((gnomon._branch_row($1)).schema_version), sc.version), sc.seq
$$;

-- Values written to the version's columns (what a diff of them shows).
-- The values a branch set in columns its version added, for one table, by key (as text): what
-- gnomon.diff adds to the branch's side of a row.
create function _gnomon.branch_side_values(b int, tbl text) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
begin
  if not gnomon._may_read_branch(b) then return '{}'; end if;
  return (select coalesce(jsonb_object_agg(s.k::text, s.cols), '{}')
            from (select v.key as k, jsonb_object_agg(v.col, v.value) as cols
                    from (select distinct on (bc.change, bc.key) bc.key, sc.detail ->> 'column' as col, bc.value
                            from _gnomon.branch_column bc join gnomon.schema_change sc on sc.id = bc.change
                           where bc.branch = branch_side_values.b and sc.tbl = branch_side_values.tbl and sc.op = 'add_column'
                           order by bc.change, bc.key, bc.gn_key desc) v
                   group by v.key) s);
end $$;

create function gnomon.schema_diff(branch text) returns table(tbl text, key jsonb, col text, value jsonb)
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
begin
  return query
  select distinct on (sc.id, bc.key) sc.tbl, bc.key, sc.detail ->> 'column', bc.value
    from gnomon.schema_change sc join _gnomon.branch_column bc on bc.change = sc.id
   where bc.branch = (gnomon._branch_row(schema_diff.branch)).id and gnomon._may_read_branch(bc.branch)
   order by sc.id, bc.key, bc.gn_key desc;
end $$;

-- The merge's part: schema conflicts, the DDL replayed on main, the values copied into the
-- real columns (as branch writes, so the data merge carries them), the version closed. Runs in
-- the merge transaction before any data is planned. Returns false when it stopped on a conflict.
create function _gnomon.merge_schema(s gnomon.branch, mid bigint) returns bool
language plpgsql volatile set search_path = pg_catalog, pg_temp as $$
declare v int := s.schema_version; lin int[] := _gnomon.version_lineage(s.schema_version); c gnomon.schema_change; t gnomon.tracked; nsp name; k record;
        cur jsonb; ctx _gnomon.ctx; prev text := coalesce(current_setting('gnomon._in_ddl', true), ''); lt text := current_setting('lock_timeout');
        hid text; br gnomon.branch; conflicts jsonb := '[]'; cmm text; def text; deferred jsonb := '[]'; touched regclass[] := '{}'; rt int;
        sim jsonb := '{}'; scons jsonb := '{}'; adopt bigint[] := '{}'; cols jsonb; tid int; mt text; finals jsonb := '[]'; x jsonb;
        rtbl regclass; colname text;
begin
  if v is null then return true; end if;
  -- the columns and constraints of main's tables now, then each change applied to them in order:
  -- what no longer fits is a conflict; what main already did the same way is adopted
  for c in select * from gnomon.schema_change sc where sc.version = any(lin) and not coalesce((sc.detail ->> 'own_table')::bool, false)
             and sc.op not in ('comment')
           order by array_position(lin, sc.version), sc.seq loop
    if c.op = 'create_table' then
      if to_regclass(c.tbl) is not null and not exists (select 1 from gnomon.schema_change z where z.version = any(lin) and z.op = 'drop_table' and z.tbl = c.tbl and z.seq < c.seq) then
        conflicts := conflicts || jsonb_build_object('tbl', c.tbl, 'col', null, 'ours', 'exists', 'theirs', 'created on the branch');
      end if;
      continue;
    end if;
    if to_regclass(c.tbl) is null then
      if c.op = 'drop_table' then
        adopt := adopt || c.id;
      elsif not exists (select 1 from gnomon.schema_change z where z.version = any(lin) and z.op = 'create_table' and z.tbl = c.tbl) then
        conflicts := conflicts || jsonb_build_object('tbl', null, 'col', c.tbl, 'ours', 'dropped on main', 'theirs', c.op);
      end if;
      -- (a table the branch creates reaches main in this merge, before its changes are replayed)
      continue;
    end if;
    if not sim ? c.tbl then
      sim := sim || jsonb_build_object(c.tbl, (select jsonb_object_agg(a.attname, format_type(a.atttypid, a.atttypmod)) from pg_attribute a
                                                 where a.attrelid = c.tbl::regclass and a.attnum > 0 and not a.attisdropped));
      scons := scons || jsonb_build_object(c.tbl, (select coalesce(jsonb_object_agg(k2.conname, pg_get_constraintdef(k2.oid)), '{}') from pg_constraint k2 where k2.conrelid = c.tbl::regclass));
    end if;
    cols := sim -> c.tbl;
    colname := c.detail ->> 'column';
    if c.op = 'add_column' then
      if cols ? colname then
        if cols ->> colname = c.detail ->> 'type' then adopt := adopt || c.id;
        else conflicts := conflicts || jsonb_build_object('tbl', c.tbl, 'col', colname, 'ours', cols ->> colname, 'theirs', c.detail ->> 'type'); end if;
      else
        cols := cols || jsonb_build_object(colname, c.detail ->> 'type');
      end if;
    elsif c.op in ('rename_column', 'drop_column', 'alter_type', 'set_not_null', 'drop_not_null', 'set_default', 'drop_default') then
      if not cols ? colname then
        if c.op = 'drop_column' then adopt := adopt || c.id;
        else conflicts := conflicts || jsonb_build_object('tbl', c.tbl, 'col', colname, 'ours', 'not on main', 'theirs', c.op); end if;
      elsif c.op = 'rename_column' then
        if cols ? (c.detail ->> 'to') then
          conflicts := conflicts || jsonb_build_object('tbl', c.tbl, 'col', c.detail ->> 'to', 'ours', 'exists', 'theirs', 'renamed from ' || colname);
        else
          cols := (cols - colname) || jsonb_build_object(c.detail ->> 'to', cols ->> colname);
        end if;
      elsif c.op = 'drop_column' then
        cols := cols - colname;
      elsif c.op = 'alter_type' then
        if cols ->> colname = c.detail ->> 'to' then adopt := adopt || c.id; else cols := jsonb_set(cols, array[colname], to_jsonb(c.detail ->> 'to')); end if;
      end if;
    elsif c.op in ('add_check', 'add_unique', 'add_fk') then
      if scons -> c.tbl ? (c.detail ->> 'name') then
        if scons -> c.tbl ->> (c.detail ->> 'name') = c.detail ->> 'def' or c.op = 'add_unique' then adopt := adopt || c.id;
        else conflicts := conflicts || jsonb_build_object('tbl', c.tbl, 'col', c.detail ->> 'name', 'ours', scons -> c.tbl ->> (c.detail ->> 'name'), 'theirs', c.detail ->> 'def'); end if;
      elsif c.op = 'add_fk' and to_regclass(format('%I.%I', split_part(c.tbl, '.', 1), c.detail ->> 'ref')) is null
            and not exists (select 1 from gnomon.schema_change z where z.version = any(lin) and z.op = 'create_table' and z.detail ->> 'table' = c.detail ->> 'ref') then
        conflicts := conflicts || jsonb_build_object('tbl', c.tbl, 'col', c.detail ->> 'name', 'ours', 'no table ' || (c.detail ->> 'ref'), 'theirs', c.detail ->> 'def');
      end if;
    end if;
    sim := jsonb_set(sim, array[c.tbl], cols);
  end loop;
  if jsonb_array_length(conflicts) > 0 then
    insert into gnomon.conflict(merge_id, tbl, key, col, kind, ours, theirs)
    select mid, coalesce((e ->> 'tbl')::regclass, 'gnomon.schema_change'::regclass), '{}', e ->> 'col', 'schema', e -> 'ours', e -> 'theirs'
      from jsonb_array_elements(conflicts) e;
    return false;
  end if;
  perform set_config('gnomon._ddl_internal', '1', true);
  cmm := current_setting('client_min_messages');
  perform set_config('client_min_messages', 'warning', true);
  -- where each version column's values go once main has the change: its final name per table
  for t in select * from gnomon.tracked x2 where x2.nsp not like 'gnomon\_sv%' loop
    for x in select e from jsonb_array_elements(_gnomon.version_shape(v, t.id) -> 'cols') e where e ->> 'side' is not null loop
      finals := finals || jsonb_build_object('tid', t.id, 'change', (x ->> 'side')::bigint, 'column', x ->> 'name');
    end loop;
  end loop;
  update gnomon.schema_version set status = 'merged' where id = any(lin) and created_on_branch = s.id;
  perform set_config('lock_timeout', gnomon._cfg('ddl_lock_timeout'), true);
  for c in select * from gnomon.schema_change sc where sc.version = any(lin)
            order by array_position(lin, sc.version), sc.seq loop
    continue when c.id = any(adopt);
    nsp := split_part(c.tbl, '.', 1);
    if c.op = 'create_table' then
      hid := _gnomon.hidden_schema(nsp::name, c.version);
      execute format('alter table %I.%I set schema %I', hid, c.detail ->> 'table', nsp);
      touched := touched || format('%I.%I', nsp, c.detail ->> 'table')::regclass;
      continue;
    end if;
    continue when coalesce((c.detail ->> 'own_table')::bool, false);   -- made for real on the hidden table already
    rtbl := to_regclass(c.tbl);
    tid := (select x2.id from gnomon.tracked x2 where x2.rel = rtbl);
    if c.op in ('rename_column', 'drop_column', 'alter_type', 'drop_table') and tid is not null then
      -- the views over the table block the change: gone now, rebuilt by the event trigger after it
      -- (a dropped table's functions go too: their signatures name its row type)
      perform _gnomon.drop_routing(tid, c.op <> 'drop_table');
    end if;
    if c.op = 'add_column' then
      execute format('alter table %s add column %I %s%s%s', c.tbl, c.detail ->> 'column', c.detail ->> 'type',
                     case when c.detail ->> 'default' is not null then ' default ' || (c.detail ->> 'default') else '' end,
                     case when coalesce((c.detail ->> 'not_null')::bool, false) then ' not null' else '' end);
    elsif c.op = 'rename_column' then
      execute format('alter table %s rename column %I to %I', c.tbl, c.detail ->> 'column', c.detail ->> 'to');
    elsif c.op = 'drop_column' then
      execute format('alter table %s drop column %I', c.tbl, c.detail ->> 'column');
    elsif c.op = 'alter_type' then
      -- history and other branches' rows convert through the same expression (retype_storage)
      perform set_config('gnomon._retype_using', jsonb_build_object('rel', c.tbl, 'column', c.detail ->> 'column', 'expr', c.detail ->> 'up')::text, true);
      execute format('alter table %s alter column %I type %s using (%s)', c.tbl, c.detail ->> 'column', c.detail ->> 'to',
                     coalesce(c.detail ->> 'up', format('%I::%s', c.detail ->> 'column', c.detail ->> 'to')));
      perform set_config('gnomon._retype_using', '', true);
    elsif c.op = 'set_not_null' then
      execute format('alter table %s alter column %I set not null', c.tbl, c.detail ->> 'column');
    elsif c.op = 'drop_not_null' then
      execute format('alter table %s alter column %I drop not null', c.tbl, c.detail ->> 'column');
    elsif c.op = 'set_default' then
      execute format('alter table %s alter column %I set default %s', c.tbl, c.detail ->> 'column', c.detail ->> 'default');
    elsif c.op = 'drop_default' then
      execute format('alter table %s alter column %I drop default', c.tbl, c.detail ->> 'column');
    elsif c.op = 'add_check' then
      execute format('alter table %s add constraint %I %s not valid', c.tbl, c.detail ->> 'name', c.detail ->> 'def');
      execute format('alter table %s validate constraint %I', c.tbl, c.detail ->> 'name');
    elsif c.op = 'add_unique' then
      if c.detail ? 'index' then
        execute replace(c.detail ->> 'index', ' ON ' || quote_ident(split_part(c.tbl, '.', 2)) || ' ', ' ON ' || c.tbl || ' ');
      else
        execute format('alter table %s add constraint %I %s', c.tbl, c.detail ->> 'name', c.detail ->> 'def');
      end if;
    elsif c.op = 'add_fk' then
      execute format('alter table %s add constraint %I foreign key (%s) references %I.%I (%s) not valid', c.tbl, c.detail ->> 'name',
                     (select string_agg(quote_ident(y), ', ') from jsonb_array_elements_text(c.detail -> 'columns') y), nsp, c.detail ->> 'ref',
                     (select string_agg(quote_ident(y), ', ') from jsonb_array_elements_text(c.detail -> 'ref_columns') y));
      execute format('alter table %s validate constraint %I', c.tbl, c.detail ->> 'name');
    elsif c.op = 'drop_constraint' then
      execute format('alter table %s drop constraint if exists %I', c.tbl, c.detail ->> 'name');
      execute format('drop index if exists %I.%I', nsp, c.detail ->> 'name');
    elsif c.op = 'drop_table' then
      execute format('drop table %s', c.tbl);
    elsif c.op = 'create_index' then
      def := replace(c.detail ->> 'definition', ' ON ' || quote_ident(split_part(c.tbl, '.', 2)) || ' ', ' ON ' || c.tbl || ' ');
      if gnomon._cfg('ddl_concurrent_rows') <> 'off' and (select greatest(reltuples, 0) from pg_class where oid = rtbl) >= gnomon._cfg('ddl_concurrent_rows')::float8
         and mid is not null and (select mode from gnomon.merge where id = mid) = 'atomic' then
        deferred := deferred || to_jsonb(regexp_replace(def, '^CREATE INDEX ', 'CREATE INDEX CONCURRENTLY IF NOT EXISTS '));
      else
        execute def;
      end if;
    elsif c.op = 'comment' then
      if c.detail ->> 'column' is null then
        execute format('comment on table %s is %L', c.tbl, c.detail ->> 'text');
      else
        execute format('comment on column %s.%I is %L', c.tbl, c.detail ->> 'column', c.detail ->> 'text');
      end if;
    end if;
    if rtbl is not null and c.op not in ('comment', 'create_index') then touched := touched || rtbl; end if;
  end loop;
  perform set_config('lock_timeout', lt, true);
  -- tables related to a changed one by a foreign key emulate it in their generated functions, by
  -- its name and columns as they were: regenerate them. A table the loop above already rebuilt is
  -- included, because it was rebuilt where the version's new tables still lived in the hidden
  -- schema: its functions would still name a row type that the move above has taken away.
  if cardinality(touched) > 0 then
    perform set_config('gnomon._in_ddl', '1', true);
    for rt in select distinct x2.id from gnomon.tracked x2 join pg_constraint fkc on fkc.contype = 'f'
                and ((fkc.conrelid = x2.rel and fkc.confrelid = any(touched)) or (fkc.confrelid = x2.rel and fkc.conrelid = any(touched))) loop
      perform _gnomon.drop_routing(rt, true);
      perform _gnomon.generate(rt);
    end loop;
    perform set_config('gnomon._in_ddl', prev, true);
  end if;
  -- the values, into the now-real columns, as writes on each branch that holds them
  for x in select e from jsonb_array_elements(finals) e loop
    select * into t from gnomon.tracked x2 where x2.id = (x ->> 'tid')::int;
    continue when t.id is null or not exists (select 1 from pg_attribute a where a.attrelid = t.rel and a.attname = x ->> 'column' and not a.attisdropped);
    for k in select distinct on (bc.branch, bc.key) bc.branch, bc.key, bc.value from _gnomon.branch_column bc where bc.change = (x ->> 'change')::bigint
              order by bc.branch, bc.key, bc.gn_key desc loop
      select * into br from gnomon.branch where id = k.branch;
      continue when br.status <> 'open';
      ctx := gnomon._ctx_compute(br.name, null, null);
      cur := (select y.r from _gnomon.read_rows(t.id, row(br.name, null)::gnomon.ref, jsonb_build_array(k.key)) y limit 1);
      continue when cur is null or cur -> (x ->> 'column') = k.value;
      perform _gnomon.apply_branch(t.id, ctx, 'update', cur, jsonb_set(cur, array[x ->> 'column'], k.value));
    end loop;
  end loop;
  -- close the version: its branches stand on its parent's shape
  update gnomon.branch set schema_version = (select parent from gnomon.schema_version where id = v) where schema_version = v;
  perform set_config('gnomon._in_ddl', '1', true);
  for nsp in select n.nspname from pg_namespace n
              where n.nspname like 'gnomon\_r\_%\_\_v' || v or n.nspname like 'gnomon\_sv' || v || '\_%' or n.nspname like 'gnomon\_r\_gnomon\_sv' || v || '\_%' loop
    execute format('drop schema if exists %I cascade', nsp);
  end loop;
  perform set_config('gnomon._in_ddl', prev, true);
  delete from _gnomon.branch_column bc where bc.change in (select id from gnomon.schema_change where version = v);
  perform _gnomon.regen_versions();
  perform set_config('gnomon._ddl_internal', '', true);
  perform set_config('client_min_messages', cmm, true);
  perform set_config('gnomon._deferred_indexes', deferred::text, true);
  perform gnomon._bump();
  return true;
end $$;
revoke all on function _gnomon.merge_schema(gnomon.branch, bigint) from public;

-- A dropped branch takes its version with it: views, hidden tables, values.
create function _gnomon.drop_branch_version(b int) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare v gnomon.schema_version; t gnomon.tracked; nsp name; prev text := coalesce(current_setting('gnomon._in_ddl', true), '');
        cmm text := current_setting('client_min_messages'); related int[]; rt int;
begin
  perform set_config('client_min_messages', 'warning', true);
  for v in select * from gnomon.schema_version where created_on_branch = b and status = 'open' loop
    -- tables a hidden table references (or is referenced by) emulate the foreign key in their
    -- generated functions: regenerate them once it is gone
    related := array(select distinct x.id from gnomon.tracked x join pg_constraint fkc on fkc.contype = 'f'
                       join gnomon.tracked h on h.nsp like 'gnomon\_sv' || v.id || '\_%'
                        and ((fkc.conrelid = x.rel and fkc.confrelid = h.rel) or (fkc.confrelid = x.rel and fkc.conrelid = h.rel))
                      where x.nsp not like 'gnomon\_sv' || v.id || '\_%');
    for t in select * from gnomon.tracked x where x.nsp like 'gnomon\_sv' || v.id || '\_%' loop
      perform gnomon.untrack(t.rel);
      perform set_config('gnomon._in_ddl', '1', true);
      execute format('drop table if exists %s cascade', t.rel);
      perform set_config('gnomon._in_ddl', prev, true);
    end loop;
    perform set_config('gnomon._in_ddl', '1', true);
    for nsp in select n.nspname from pg_namespace n where n.nspname like 'gnomon\_r\_%\_\_v' || v.id or n.nspname like 'gnomon\_sv' || v.id || '\_%'
                  or n.nspname like 'gnomon\_r\_gnomon\_sv' || v.id || '\_%' loop
      execute format('drop schema if exists %I cascade', nsp);
    end loop;
    perform set_config('gnomon._in_ddl', prev, true);
    update gnomon.schema_version set status = 'dropped' where id = v.id;
    update gnomon.branch set schema_version = v.parent where schema_version = v.id and id <> b;
    perform set_config('gnomon._in_ddl', '1', true);
    foreach rt in array related loop
      perform _gnomon.drop_routing(rt, true);
      perform _gnomon.generate(rt);
    end loop;
    perform set_config('gnomon._in_ddl', prev, true);
  end loop;
  perform _gnomon.regen_versions();
  perform set_config('client_min_messages', cmm, true);
end $$;
revoke all on function _gnomon.drop_branch_version(int) from public;

-- Rebuild every open version's views (the routing views under them were regenerated).
create function _gnomon.regen_versions() returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare v gnomon.schema_version;
begin
  for v in select * from gnomon.schema_version where status = 'open' order by id loop
    perform _gnomon.gen_version(v.id);
    -- main now has a column the version adds with another type: the branch is told at once
    -- (the merge reports it as a conflict of kind schema)
    insert into gnomon.warning(branch, tbl, key, col, kind, detail)
    select v.created_on_branch, sc.tbl::regclass, '{}', sc.detail ->> 'column', 'schema',
           jsonb_build_object('main', _gnomon.col_type(sc.tbl, sc.detail ->> 'column'), 'branch', sc.detail ->> 'type', 'change', sc.id)
      from gnomon.schema_change sc
     where sc.version = any(_gnomon.version_lineage(v.id)) and sc.op = 'add_column' and v.created_on_branch is not null
       and not coalesce((sc.detail ->> 'own_table')::bool, false)
       and _gnomon.col_type(sc.tbl, sc.detail ->> 'column') <> sc.detail ->> 'type'
    on conflict (branch, tbl, key, col) do update set kind = excluded.kind, detail = excluded.detail, at = now();
  end loop;
end $$;
revoke all on function _gnomon.regen_versions() from public;

-- A child merged into its parent on the same version: its values of the version's columns go
-- with it (the source's value wins; these are not merged three ways).
create function _gnomon.merge_branch_columns(s int, tg int) returns int language plpgsql volatile
set search_path = pg_catalog, pg_temp as $$
declare st gnomon.stamp := gnomon._stamp(); n int;
begin
  insert into _gnomon.branch_column(change, branch, key, value, gn_key, gn_xoff)
  select x.change, tg, x.key, x.value, st.key, st.xoff
    from (select distinct on (bc.change, bc.key) bc.change, bc.key, bc.value from _gnomon.branch_column bc where bc.branch = s
           order by bc.change, bc.key, bc.gn_key desc) x
  on conflict (change, key, branch, gn_key) do update set value = excluded.value;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function _gnomon.merge_branch_columns(int, int) from public;

-- The merge's schema step for a branch on a version, shared by gnomon.merge and the
-- incremental merge: into main, the version's DDL and values (false on a schema conflict); into
-- a branch on the same version, the values of its columns; anything else is refused.
create function _gnomon.merge_schema_gate(s gnomon.branch, tg gnomon.branch, mid bigint) returns bool
language plpgsql volatile set search_path = pg_catalog, pg_temp as $$
declare owner text;
begin
  if s.schema_version is null then return true; end if;
  if tg.schema_version is not distinct from s.schema_version then
    if tg.id <> 0 then perform _gnomon.merge_branch_columns(s.id, tg.id); end if;
    return true;
  end if;
  if tg.id <> 0 then
    raise exception 'branch "%" is on schema version % and "%" is not: merge it into main', s.name, s.schema_version, tg.name
      using errcode = '0A000', hint = '[gnomon:schema_version_target]';
  end if;
  select b2.name into owner from gnomon.schema_version sv join gnomon.branch b2 on b2.id = sv.created_on_branch
   where sv.id = any(_gnomon.version_lineage(s.schema_version)) and sv.status = 'open' and sv.created_on_branch <> s.id limit 1;
  if owner is not null then
    raise exception 'branch "%" stands on schema changes made on "%": merge that branch first', s.name, owner
      using errcode = '0A000', hint = '[gnomon:schema_version_owner]';
  end if;
  return _gnomon.merge_schema(s, mid);
end $$;
revoke all on function _gnomon.merge_schema_gate(gnomon.branch, gnomon.branch, bigint) from public;
