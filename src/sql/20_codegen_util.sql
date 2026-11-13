-- Code-generation helpers. Every per-table object is generated from the table's catalog
-- definition at track/sync time, with explicit column lists, so the hot paths are static SQL.

create type _gnomon.col as (
  num     int2,
  q       text,      -- quoted column name
  raw     name,
  typ     text,      -- schema-qualified type
  typoid  oid,
  nonnull bool,
  gen     bool,      -- generated column
  ident   "char",
  def     text,      -- default expression
  large   bool,      -- may be stored in _gnomon.blob
  eqop    text,      -- qualified equality operator, or null when the type has none
  iskey   bool,
  slot    int,       -- value slot in version tables (stable across renames); -1 for keys
  missing text       -- SQL literal for rows that predate the column (its fast default), or NULL
);

create function _gnomon.eqop_for(t oid) returns text language sql stable as $$
  select format('OPERATOR(%I.=)', n.nspname)
    from pg_operator o join pg_namespace n on n.oid = o.oprnamespace
   where o.oprname = '=' and o.oprleft = t and o.oprright = t and o.oprresult = 'bool'::regtype
   order by (n.nspname = 'pg_catalog') desc
   limit 1
$$;

-- Column metadata. Must run with search_path = pg_catalog so format_type qualifies names.
create function _gnomon.cols(rel regclass) returns _gnomon.col[]
language sql stable set search_path = pg_catalog, pg_temp as $$
  with k as (
    select unnest(t.key_cols) as kname from gnomon.tracked t where t.rel = $1
  )
  select coalesce(array_agg(row(
           a.attnum, quote_ident(a.attname), a.attname,
           format_type(a.atttypid, a.atttypmod), a.atttypid, a.attnotnull,
           a.attgenerated <> '', a.attidentity,
           pg_get_expr(d.adbin, d.adrelid),
           (t.typlen = -1 and coalesce(bt.typcategory, t.typcategory) in ('S','U')
              and coalesce(bt.typname, t.typname) in ('text','varchar','bpchar','jsonb','json','bytea','xml','citext')),
           coalesce(_gnomon.eqop_for(a.atttypid),
                    case when t.typbasetype <> 0 then _gnomon.eqop_for(t.typbasetype) end,
                    case when t.typcategory = 'A' and _gnomon.eqop_for(t.typelem) is not null
                         then 'OPERATOR(pg_catalog.=)' end),
           a.attname in (select kname from k),
           -1,
           case when a.atthasmissing then format('((%L)::%s[])[1]', a.attmissingval::text, format_type(a.atttypid, a.atttypmod)) end
         )::_gnomon.col order by a.attnum), '{}')
    from pg_attribute a
    join pg_type t on t.oid = a.atttypid
    left join pg_type bt on bt.oid = t.typbasetype and t.typbasetype <> 0
    left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
   where a.attrelid = $1 and a.attnum > 0 and not a.attisdropped
$$;

-- "a is distinct from b", safe for any type and under a pinned search_path.
create function _gnomon.ne(c _gnomon.col, a text, b text) returns text language sql immutable as $$
  select case when c.eqop is null
    then format('(%s)::text IS DISTINCT FROM (%s)::text', a, b)
    else format('(NOT coalesce(%1$s %3$s %2$s, (%1$s) IS NULL AND (%2$s) IS NULL))', a, b, c.eqop)
  end
$$;

-- "a = b" for non-null key values.
create function _gnomon.eq(c _gnomon.col, a text, b text) returns text language sql immutable as $$
  select format('%s %s %s', a, coalesce(c.eqop, 'OPERATOR(pg_catalog.=)'), b)
$$;

-- Equality over a column list: a.c1 = b.c1 AND ...
create function _gnomon.eqs(cs _gnomon.col[], a text, b text) returns text language sql immutable as $$
  select coalesce(string_agg(_gnomon.eq(c, a || '.' || c.q, b || '.' || c.q), ' AND ' order by c.num), 'true')
    from unnest(cs) c
$$;

-- a.c1, a.c2 ...
create function _gnomon.lst(cs _gnomon.col[], pre text default '', suf text default '') returns text
language sql immutable as $$
  select coalesce(string_agg(pre || c.q || suf, ', ' order by c.num), '') from unnest(cs) c
$$;

create function _gnomon.keys(cs _gnomon.col[]) returns _gnomon.col[] language sql immutable as $$
  select coalesce(array_agg(c order by c.num), '{}') from unnest(cs) c where c.iskey
$$;
create function _gnomon.vals(cs _gnomon.col[]) returns _gnomon.col[] language sql immutable as $$
  select coalesce(array_agg(c order by c.num), '{}') from unnest(cs) c where not c.iskey
$$;
create function _gnomon.nongen(cs _gnomon.col[]) returns _gnomon.col[] language sql immutable as $$
  select coalesce(array_agg(c order by c.num), '{}') from unnest(cs) c where not c.gen
$$;

-- Storage object names for a tracked table.
create function _gnomon.obj(t gnomon.tracked, suffix text) returns text language sql immutable as $$
  select '_gnomon.' || quote_ident(t.base || '__' || suffix)
$$;
create function _gnomon.robj(t gnomon.tracked) returns text language sql immutable as $$
  select quote_ident('gnomon_r_' || t.nsp) || '.' || quote_ident(t.relname)
$$;
-- The scratch-branch routing view: the same arms plus the unlogged branch tables.
create function _gnomon.robj_s(t gnomon.tracked) returns text language sql immutable as $$
  select quote_ident('gnomon_r_' || t.nsp || '__s') || '.' || quote_ident(t.relname)
$$;
create function _gnomon.robj_for(t gnomon.tracked, kind text) returns text language sql immutable as $$
  select case when kind = 'scratch' then _gnomon.robj_s(t) else _gnomon.robj(t) end
$$;
-- Generated branch-write bodies name routing views through tokens, resolved per branch kind.
create function _gnomon.rv_tok(rel regclass) returns text language sql stable as $$
  select coalesce((select '@@rv' || t.rel::oid || '@@' from gnomon.tracked t where t.rel = $1), $1::text)
$$;
create function _gnomon.rv_detok(s text, scratch bool) returns text language plpgsql stable as $$
declare m text[]; t gnomon.tracked;
begin
  for m in select distinct regexp_matches(s, '@@rv(\d+)@@', 'g') loop
    select * into t from gnomon.tracked where rel = m[1]::oid;
    s := replace(s, '@@rv' || m[1] || '@@', case when scratch then _gnomon.robj_s(t) else _gnomon.robj(t) end);
  end loop;
  return s;
end $$;
create function _gnomon.qrel(t gnomon.tracked) returns text language sql immutable as $$
  select quote_ident(t.nsp) || '.' || quote_ident(t.relname)
$$;

-- Blob store for large values.
create function _gnomon.blob_put(v text) returns bytea language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
declare h bytea := sha256(convert_to(v, 'UTF8'));
begin
  insert into _gnomon.blob(h, v) values (h, v) on conflict do nothing;
  return h;
end $$;

create function _gnomon.blob_get(h bytea) returns text language sql stable security definer
set search_path = pg_catalog, pg_temp as $$
  select case when h is null then null else (select b.v from _gnomon.blob b where b.h = $1) end
$$;
grant execute on function _gnomon.blob_get(bytea) to public;
revoke all on function _gnomon.blob_put(text) from public;
grant execute on function _gnomon.blob_put(text) to gnomon_writer, gnomon_admin;

-- Stored value / hash expressions for a column on the write path.
create function _gnomon.wval(c _gnomon.col, src text) returns text language sql immutable as $$
  select case when c.large
    then format('CASE WHEN pg_column_size(%1$s) > %2$s THEN NULL ELSE %1$s END', src || '.' || c.q, '__THR__')
    else src || '.' || c.q end
$$;
create function _gnomon.whash(c _gnomon.col, src text) returns text language sql immutable as $$
  select format('CASE WHEN pg_column_size(%1$s) > %2$s THEN _gnomon.blob_put((%1$s)::text) END', src || '.' || c.q, '__THR__')
$$;

-- Rebuilt value of column c from version alias v and keyframe alias k.
-- Keyframes carry an all-ones mask as long as the table's slot count when written, so a slot
-- beyond a version's mask means the column did not exist yet: its fast default applies.
create function _gnomon.present(c _gnomon.col, a text) returns text language sql immutable as $$
  select format('(length(%1$s.gn_mask) > %2$s AND get_bit(%1$s.gn_mask, %2$s) = 1)', a, c.slot)
$$;
create function _gnomon.avail(c _gnomon.col, a text) returns text language sql immutable as $$
  select format('(length(%1$s.gn_mask) > %2$s)', a, c.slot)
$$;
create function _gnomon.sval(c _gnomon.col, a text) returns text language sql immutable as $$
  select case when c.large
    then format('coalesce(%1$s.gn_c%2$s, (_gnomon.blob_get(%1$s.gn_h%2$s))::%3$s)', a, c.slot, c.typ)
    else format('%s.gn_c%s', a, c.slot) end
$$;
create function _gnomon.rval(c _gnomon.col) returns text language sql immutable as $$
  select format('CASE WHEN %s THEN %s WHEN (v.gn_flags & 8) <> 0 THEN %s WHEN %s THEN %s ELSE %s END',
                _gnomon.present(c, 'v'), _gnomon.sval(c, 'v'), coalesce(c.missing, 'NULL'),
                _gnomon.avail(c, 'k'), _gnomon.sval(c, 'k'), coalesce(c.missing, 'NULL'))
$$;

create function _gnomon.refuse_truncate() returns trigger language plpgsql as $$
begin
  -- gnomon.truncate on main has taken a checkpoint and written its marker
  if current_setting('gnomon._truncating', true) = TG_RELID::text then return null; end if;
  raise exception 'TRUNCATE is refused on gnomon-tracked table %', TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME
    using hint = 'Delete rows instead so history records them, or untrack the table first (gnomon.untrack). [gnomon:truncate_refused_tracked_table]',
          errcode = '0A000';
end $$;

-- A table argument may name the routing view a branch session resolves it to; map it back.
create function _gnomon.base_rel(r regclass) returns regclass language sql stable as $$
  select coalesce((select t.rel from pg_class c join pg_namespace n on n.oid = c.relnamespace
                     join gnomon.tracked t on t.relname = c.relname and (n.nspname like 'gnomon\_r\_%' or n.nspname like 'gnomon\_q\_%')
                      and t.nsp = regexp_replace(n.nspname, '^gnomon_[rq]_(.*?)(__s|__m[0-9]+)?$', '\1')
                    where c.oid = r), r)
$$;
create function _gnomon.base_rels(rs regclass[]) returns regclass[] language sql stable as $$
  select case when rs is null then null else array(select _gnomon.base_rel(x) from unnest(rs) x) end
$$;

-- History readers run with gnomon's rights; they only serve tables the caller may SELECT.
-- A role that may read a table's routing view may read its history too: a confined
-- role holds no grant on the base table, yet diffs and merges its own branches.
create function _gnomon.can_read(rel regclass) returns bool language sql stable as $$
  select has_table_privilege(coalesce(nullif(current_setting('role'), 'none'), session_user::text), rel, 'SELECT')
      or exists (select 1 from gnomon.tracked t
                  where t.rel = can_read.rel
                    and to_regclass(_gnomon.robj(t)) is not null
                    and has_table_privilege(coalesce(nullif(current_setting('role'), 'none'), session_user::text), _gnomon.robj(t)::regclass, 'SELECT'))
$$;
create function _gnomon.require_read(rel regclass) returns void language plpgsql stable as $$
begin
  if not _gnomon.can_read(rel) then
    raise exception 'permission denied for table %', rel using errcode = '42501', hint = '[gnomon:permission_denied_table]';
  end if;
end $$;
