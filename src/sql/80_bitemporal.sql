-- Valid time: change points, corrections, scheduled changes.
-- Bitemporal version tables are unpartitioned and store full images. Branch writes on bitemporal tables are known-time only.

-- One row's writers on a bitemporal table are serialized by an advisory transaction lock as well
-- as by the row lock: a BEFORE INSERT trigger runs before the unique-index wait that orders it
-- after a concurrent delete, and corrections write change points without touching the row. The
-- stamp is taken after this lock.
create function _gnomon.bt_lock(tid int, key jsonb) returns void language sql volatile as $$
  select pg_advisory_xact_lock(hashtext('gnomon:' || tid), hashtext(key::text))
$$;

-- BEFORE ROW trigger on a bitemporal table.
create function _gnomon.gen_bitemporal_trigger(tid int) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $g$
declare t gnomon.tracked := _gnomon.trow(tid); cs _gnomon.col[] := _gnomon.tcols(tid); ks _gnomon.col[] := _gnomon.keys(cs);
        vs _gnomon.col[] := _gnomon.vals(cs); c _gnomon.col; V text := _gnomon.obj(t, 'v'); S text := _gnomon.obj(t, 'sched');
        valcols text := ''; vals_new text := ''; vals_old text := ''; thr text := t.blob_threshold::text;
        vk text; vk_new text; vk_old text; vk_eq_old text; vk_eq_new text; trk_xid text;
begin
  trk_xid := ((t.track_key & 281474976710655) - t.track_xoff)::text;
  foreach c in array vs loop
    valcols := valcols || format(', gn_c%s', c.slot) || case when c.large then format(', gn_h%s', c.slot) else '' end;
    vals_new := vals_new || ', ' || _gnomon.wval(c, 'NEW') || case when c.large then ', ' || _gnomon.whash(c, 'NEW') else '' end;
    vals_old := vals_old || ', ' || _gnomon.wval(c, 'OLD') || case when c.large then ', ' || _gnomon.whash(c, 'OLD') else '' end;
  end loop;
  vals_new := replace(vals_new, '__THR__', thr); vals_old := replace(vals_old, '__THR__', thr);
  if t.wide_key then
    vk := 'gn_rid';
    vk_new := format('_gnomon.%I(%s)', t.base || '__rid', _gnomon.lst(ks, 'NEW.'));
    vk_old := format('_gnomon.%I(%s)', t.base || '__rid', _gnomon.lst(ks, 'OLD.'));
    vk_eq_old := format('v.gn_rid = %s', vk_old); vk_eq_new := format('v.gn_rid = %s', vk_new);
  else
    vk := _gnomon.lst(ks); vk_new := _gnomon.lst(ks, 'NEW.'); vk_old := _gnomon.lst(ks, 'OLD.');
    vk_eq_old := _gnomon.eqs(ks, 'v', 'OLD'); vk_eq_new := _gnomon.eqs(ks, 'v', 'NEW');
  end if;
  execute _gnomon.tpl($b$
create or replace function @FN@() returns trigger language plpgsql
security definer set search_path = pg_catalog, pg_temp 
set enable_seqscan = off as $f$
#variable_conflict use_variable
declare st gnomon.stamp; vf timestamptz; fut bool; cur jsonb;
begin
  -- the ticker and corrections update the current table from change points already written
  IF current_setting('gnomon._bt_apply', true) = '1' OR current_setting('gnomon._erasing', true) = '1' OR _gnomon.is_apply() THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  IF (coalesce(current_setting('gnomon.branch', true), '') NOT IN ('', 'main') OR coalesce(current_setting('gnomon.as_of', true), '') <> '')
     AND coalesce(current_setting('gnomon._main_write', true), '') <> '1' THEN
    PERFORM _gnomon.main_write_refused(TG_RELID::regclass);
  END IF;
  IF TG_OP = 'UPDATE' AND NOT (@KEYS_SAME@) THEN   -- both keys of a key change, in key order
    PERFORM _gnomon.bt_lock(@TID@, x.k) FROM (SELECT unnest(ARRAY[@KJ_OLD@, @KJ_NEW@]) AS k ORDER BY 1) x;
  ELSE
    PERFORM _gnomon.bt_lock(@TID@, CASE WHEN TG_OP = 'DELETE' THEN @KJ_OLD@ ELSE @KJ_NEW@ END);
  END IF;
  st := gnomon._stamp();
  -- an insert may follow a delete this snapshot cannot see (gnomon._fresh_xid)
  IF TG_OP = 'INSERT' THEN st := gnomon._stamp_fresh(st); END IF;
  vf := coalesce(nullif(current_setting('gnomon.valid_from', true), '')::timestamptz, now());
  fut := vf > now();
  IF coalesce(current_setting('gnomon.actor', true), '') <> '' OR coalesce(current_setting('gnomon.reason', true), '') <> '' THEN
    PERFORM gnomon._log_xact(0);
  END IF;
  IF TG_OP <> 'INSERT' AND NOT EXISTS (SELECT 1 FROM @V@ v WHERE @VK_EQ_OLD@) THEN
    -- lazy baseline: the pre-image, valid since -infinity, stamped with the tracking transaction
    INSERT INTO @V@ (@VK@, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_valid_from@VALCOLS@)
    VALUES (@VK_OLD@, least(@TKEY@::int8, st.key), ((least(@TKEY@::int8, st.key) & 281474976710655) - @TXID@)::int4,
            '0/0'::pg_lsn, @TROLE@::oid, 40, '-infinity'@VALS_OLD@);
  END IF;
  -- a key change at valid time vf: the end of the old key's timeline and the start
  -- of the new one's, one stamp; a future-dated one schedules both, applied together
  IF TG_OP = 'UPDATE' AND NOT (@KEYS_SAME@) THEN
    INSERT INTO @V@ (@VK@, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_valid_from)
    VALUES (@VK_OLD@, st.key, st.xoff, st.lsn, st.role, 4 | 8, vf);
    INSERT INTO @V@ (@VK@, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_valid_from@VALCOLS@)
    VALUES (@VK_NEW@, st.key, st.xoff, st.lsn, st.role, 9, vf@VALS_NEW@);
    IF fut THEN
      INSERT INTO @S@ (@VK@, gn_valid_from, gn_key) VALUES (@VK_OLD@, vf, st.key), (@VK_NEW@, vf, st.key) ON CONFLICT DO NOTHING;
      RETURN NULL;
    END IF;
    RETURN NEW;
  END IF;
  -- A scheduled change for this row came due and the ticker has not applied it yet: main's row is
  -- stale, so this write applies to the row as in effect now, its changed columns over that state
  -- (main catches up on the next write to the row)
  IF TG_OP = 'UPDATE' AND NOT fut AND EXISTS (SELECT 1 FROM @S@ v WHERE @SCHED_EQ@ AND v.gn_valid_from <= now()) THEN
    cur := _gnomon.bt_state(@TID@, @KJ_OLD@, gnomon._coordinate_self(), now());
    IF cur IS NOT NULL THEN
      NEW := jsonb_populate_record(NEW, (SELECT coalesce(jsonb_object_agg(e.key, e.value), '{}') FROM jsonb_each(cur) e
                                          WHERE (to_jsonb(NEW) -> e.key) IS NOT DISTINCT FROM (to_jsonb(OLD) -> e.key)));
    END IF;
  END IF;
  IF TG_OP = 'DELETE' THEN
    INSERT INTO @V@ (@VK@, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_valid_from)
    VALUES (@VK_OLD@, st.key, st.xoff, st.lsn, st.role, 4 | 8, vf);
  ELSE
    INSERT INTO @V@ (@VK@, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_valid_from@VALCOLS@)
    VALUES (@VK_NEW@, st.key, st.xoff, st.lsn, st.role, CASE WHEN TG_OP = 'INSERT' THEN 9 ELSE 10 END, vf@VALS_NEW@);
  END IF;
  IF fut THEN
    -- a scheduled change: exact at once for time-aware reads; main catches up at its time
    INSERT INTO @S@ (@VK@, gn_valid_from, gn_key) VALUES (CASE WHEN TG_OP = 'DELETE' THEN @VK_OLD@ ELSE @VK_NEW@ END, vf, st.key)
      ON CONFLICT DO NOTHING;
    RETURN NULL;
  END IF;
  -- a write now supersedes any due scheduled change for this row
  DELETE FROM @S@ v WHERE @SCHED_EQ@ AND v.gn_valid_from <= now();
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
end $f$;$b$,
    'FN', _gnomon.obj(t, 'trg'), 'V', V, 'S', S, 'VK', vk, 'VK_NEW', vk_new, 'VK_OLD', vk_old, 'VK_EQ_OLD', vk_eq_old,
    'VALCOLS', valcols, 'VALS_NEW', vals_new, 'VALS_OLD', vals_old, 'KEYS_SAME', _gnomon.eqs(ks, 'NEW', 'OLD'),
    'TKEY', t.track_key::text, 'TXID', trk_xid, 'TROLE', t.track_role::text,
    'TID', tid::text, 'KJ_OLD', _gnomon.key_sql(t, 'OLD'), 'KJ_NEW', _gnomon.key_sql(t, 'NEW'),

    'SCHED_EQ', case when t.wide_key then format('v.gn_rid = (CASE WHEN TG_OP = ''DELETE'' THEN %s ELSE %s END)', vk_old, vk_new)
                     else (select string_agg(format('v.%1$s = (CASE WHEN TG_OP = ''DELETE'' THEN OLD.%1$s ELSE NEW.%1$s END)', k.q), ' AND ') from unnest(ks) k) end);
  execute format('alter function %s() owner to gnomon_writer', _gnomon.obj(t, 'trg'));
  execute format('grant select, insert, delete on %s to gnomon_writer', S);
  execute format('grant insert, select on %s to gnomon_writer', V);
  -- statement mode is not used for bitemporal tables
  execute format('create or replace function %s() returns trigger language plpgsql as $f$ begin return null; end $f$', _gnomon.obj(t, 'strg'));
  perform _gnomon.attach_main_triggers(tid);
end $g$;

-- Lookup at (C, v): the first change point with valid_from <= v visible at C and not retracted at C.
create function _gnomon.bt_point_sql(t gnomon.tracked, vk_eq text, c_expr text, v_expr text) returns text language sql immutable as $$
  select format($s$SELECT v.* FROM %1$s v
     WHERE %2$s AND v.gn_valid_from <= %4$s AND (v.gn_flags & 64) = 0 AND gnomon._vis(v.gn_key, v.gn_xoff, %3$s)
       AND NOT EXISTS (SELECT 1 FROM %1$s r WHERE %5$s AND (r.gn_flags & 64) <> 0 AND r.gn_retracts = v.gn_key
                         AND r.gn_valid_from = v.gn_valid_from AND gnomon._vis(r.gn_key, r.gn_xoff, %3$s))
     ORDER BY v.gn_valid_from DESC, v.gn_key DESC, v.gn_lsn DESC LIMIT 1$s$,
     _gnomon.obj(t, 'v'), vk_eq, c_expr, v_expr, replace(vk_eq, 'v.', 'r.'))
$$;

-- History arm for bitemporal tables: every row with change points, at (main cutoff or now, valid_at).
create function _gnomon.gen_bitemporal_hist(tid int, scratch bool default true) returns text language plpgsql volatile
set search_path = pg_catalog, pg_temp as $g$
declare t gnomon.tracked := _gnomon.trow(tid); cs _gnomon.col[] := _gnomon.tcols(tid); ks _gnomon.col[] := _gnomon.keys(cs);
        o_list text; m_list text; key_src text; vk_c text; vk_eq text; id_join text := '';
begin
  o_list := (select string_agg(case when c2.iskey then 'o.' || c2.q else 'h.' || c2.q end, ', ' order by c2.num) from unnest(cs) c2);
  if t.wide_key then
    key_src := 'i'; vk_c := 'v.gn_rid'; vk_eq := 'v.gn_rid = c.gn_rid';
    id_join := format('JOIN %s i ON i.gn_rid = c.gn_rid', _gnomon.obj(t, 'id'));
  else
    key_src := 'c'; vk_c := _gnomon.lst(ks, 'v.'); vk_eq := _gnomon.eqs(ks, 'v', 'c');
  end if;
  m_list := (select string_agg(case when c2.iskey then key_src || '.' || c2.q else _gnomon.sval(c2, 'v') || ' AS ' || c2.q end, ', ' order by c2.num) from unnest(cs) c2);
  return _gnomon.tpl($v$
create view @HIST@ as
@BRANCH_ARM@
UNION ALL
SELECT @M_LIST@
  FROM @V@ c
  CROSS JOIN LATERAL (@POINT@) v
  @ID_JOIN@
 WHERE NOT (SELECT gnomon._ctx_main_now())
   AND NOT EXISTS (SELECT 1 FROM @V@ c2 WHERE @EQ_C2C@ AND (c2.gn_key, c2.gn_lsn) > (c.gn_key, c.gn_lsn))
   AND (v.gn_flags & 4) = 0
   AND (SELECT gnomon._ctx_clear(@TID@)) IS NULL
   AND NOT @TOUCHED@$v$,
    'HIST', _gnomon.obj(t, case when scratch then 'hist_s' else 'hist' end), 'O_LIST', o_list, 'KK', _gnomon.lst(ks, 'k.'), 'KS', _gnomon.lst(ks),
    'EQ_BO', _gnomon.eqs(ks, 'b', 'o'), 'TID', tid::text, 'M_LIST', m_list, 'VK_V', vk_c, 'V', _gnomon.obj(t, 'v'),
    'POINT', _gnomon.bt_point_sql(t, vk_eq, format('(SELECT gnomon._ctx_main_cut_t(%s))', tid), '(SELECT gnomon._ctx_valid_at())'),
    'ID_JOIN', id_join, 'TOUCHED', _gnomon.touched_sql(t, ks, key_src, case when scratch then 'lu' else 'l' end),
    'BRANCH_ARM', _gnomon.hist_branch_sql(t, ks, o_list, scratch),
    'EQ_C2C', case when t.wide_key then 'c2.gn_rid = c.gn_rid' else _gnomon.eqs(ks, 'c2', 'c') end);
end $g$;

-- State of one bitemporal row at (C, v) as jsonb (null = absent).
create function _gnomon.bt_state(tid int, key jsonb, c gnomon.coord, v timestamptz) returns jsonb language plpgsql volatile as $$
declare t gnomon.tracked := _gnomon.trow(tid); cs _gnomon.col[] := _gnomon.tcols(tid); r jsonb; vk_eq text;
begin
  if t.wide_key then
    vk_eq := format('v.gn_rid = (select i.gn_rid from %s i where %s)', _gnomon.obj(t, 'id'),
                    (select string_agg(format('i.%s = ($1->>%L)::%s', k.q, k.raw, k.typ), ' and ') from unnest(_gnomon.keys(cs)) k));
  else
    vk_eq := (select string_agg(format('v.%s = ($1->>%L)::%s', k.q, k.raw, k.typ), ' and ') from unnest(_gnomon.keys(cs)) k);
  end if;
  execute format('select case when (v.gn_flags & 4) <> 0 then null else jsonb_build_object(%s) end from (%s) v',
                 (select string_agg(format('%L, %s', c2.raw, case when c2.iskey then format('($1->%L)', c2.raw) else _gnomon.sval(c2, 'v') end), ', ' order by c2.num) from unnest(cs) c2),
                 _gnomon.bt_point_sql(t, vk_eq, '$2', '$3'))
    into r using key, c, v;
  return r;
end $$;

-- Write a change point directly (used by corrections and the ticker).
create function _gnomon.bt_write_point(tid int, key jsonb, img jsonb, vf timestamptz, flags int, retracts int8 default null)
returns void language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked := _gnomon.trow(tid); cs _gnomon.col[] := _gnomon.tcols(tid); vs _gnomon.col[]; st gnomon.stamp := gnomon._stamp();
        vkv text; c _gnomon.col; cols text := ''; vals text := ''; ks _gnomon.col[];
begin
  ks := _gnomon.keys(cs); vs := _gnomon.vals(cs);
  if t.wide_key then
    vkv := format('_gnomon.%I(%s)', t.base || '__rid', (select string_agg(format('($1->>%L)::%s', k.raw, k.typ), ', ') from unnest(ks) k));
  else
    vkv := (select string_agg(format('($1->>%L)::%s', k.raw, k.typ), ', ') from unnest(ks) k);
  end if;
  -- a correction follows the row's latest version even when its snapshot is older (gnomon._fresh_xid)
  st := gnomon._stamp_fresh(st);
  if img is not null then
    foreach c in array vs loop
      cols := cols || format(', gn_c%s', c.slot);
      vals := vals || format(', ($2->>%L)::%s', c.raw, c.typ);
    end loop;
  end if;
  execute format('insert into %s (%s, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_valid_from, gn_retracts%s) values (%s, $3, $4, $5, $6, $7, $8, $9%s)',
                 _gnomon.obj(t, 'v'), case when t.wide_key then 'gn_rid' else _gnomon.lst(ks) end, cols, vkv, vals)
    using key, img, st.key, st.xoff, st.lsn, st.role, flags, vf, retracts;
end $$;

-- Bring main's current table to the state at valid time now for one row.
create function _gnomon.bt_sync_current(tid int, key jsonb) returns void language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked := _gnomon.trow(tid); want jsonb := _gnomon.bt_state(tid, key, gnomon._coordinate_self(), now());   -- (this transaction's change points included)
        cur jsonb;
begin
  cur := (select x.r from _gnomon.read_rows(tid, row('main', null)::gnomon.ref, jsonb_build_array(key)) x limit 1);
  if cur is not distinct from want then return; end if;
  perform set_config('gnomon._bt_apply', '1', true);
  if want is null then perform _gnomon.apply_main(tid, 'delete', jsonb_build_array(cur));
  elsif cur is null then perform _gnomon.apply_main(tid, 'insert', jsonb_build_array(want));
  else perform _gnomon.apply_main(tid, 'update', jsonb_build_array(want)); end if;
  perform set_config('gnomon._bt_apply', '', true);
end $$;

-- A correction for [valid_from, valid_to): a change point at the start, one at the end restoring
-- the state then in effect, and retractions of the points in between.
create function gnomon.correct(tbl regclass, key jsonb, valid_from timestamptz, valid_to timestamptz, changes jsonb)
returns void language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; nowc gnomon.coord; at_a jsonb; at_b jsonb; p record; vk_eq text; cs _gnomon.col[]; kn jsonb;
begin

  tbl := _gnomon.base_rel(tbl);  select * into t from gnomon.tracked where rel = tbl;
  if t.mode <> 'bitemporal' then raise exception '% is not bitemporal', tbl using hint = '[gnomon:not_bitemporal]'; end if;
  if not has_table_privilege(_gnomon.who(), tbl, 'UPDATE') then raise exception 'permission denied for table %', tbl using errcode = '42501', hint = '[gnomon:permission_denied_table]'; end if;
  if valid_to is not null and valid_to <= valid_from then raise exception 'valid_to must be after valid_from' using hint = '[gnomon:valid_to_must_after_valid_from]'; end if;
  cs := _gnomon.tcols(t.id);
  -- serialize with this row's other writers, then read "as known now" (a new snapshot under
  -- READ COMMITTED; under REPEATABLE READ, locking a row changed since the snapshot fails)
  execute format('select %s from jsonb_populate_record(null::%s, $1) r', _gnomon.key_sql(t, 'r'), tbl) into kn using key;
  perform _gnomon.bt_lock(t.id, kn);
  execute format('select 1 from %s r where %s for update', tbl,
                 (select string_agg(format('r.%1$I = (jsonb_populate_record(null::%2$s, $1)).%1$I', k, tbl), ' and ') from unnest(t.key_cols) k))
    using key;
  nowc := gnomon._coordinate_self();   -- as known now, this transaction's earlier writes included
  at_a := _gnomon.bt_state(t.id, key, nowc, valid_from);
  if valid_to is not null then at_b := _gnomon.bt_state(t.id, key, nowc, valid_to); end if;
  -- retract the points strictly inside the interval, as known now
  if t.wide_key then
    vk_eq := format('v.gn_rid = (select i.gn_rid from %s i where %s)', _gnomon.obj(t, 'id'),
                    (select string_agg(format('i.%s = ($1->>%L)::%s', k.q, k.raw, k.typ), ' and ') from unnest(_gnomon.keys(cs)) k));
  else
    vk_eq := (select string_agg(format('v.%s = ($1->>%L)::%s', k.q, k.raw, k.typ), ' and ') from unnest(_gnomon.keys(cs)) k);
  end if;
  for p in execute format($q$select v.gn_key, v.gn_valid_from from %s v where %s and (v.gn_flags & 64) = 0
                                and v.gn_valid_from > $2 and ($3 is null or v.gn_valid_from < $3)
                                and gnomon._vis(v.gn_key, v.gn_xoff, $4)$q$, _gnomon.obj(t, 'v'), vk_eq)
           using key, valid_from, valid_to, nowc loop
    perform _gnomon.bt_write_point(t.id, key, null, p.gn_valid_from, 64, p.gn_key);
  end loop;
  perform _gnomon.bt_write_point(t.id, key, coalesce(at_a, key) || changes, valid_from, 10);
  if valid_to is not null and valid_to <> 'infinity' then
    if at_b is null then
      perform _gnomon.bt_write_point(t.id, key, null, valid_to, 4 | 8);
    else
      perform _gnomon.bt_write_point(t.id, key, at_b, valid_to, 10);
    end if;
  end if;
  if valid_from > now() then
    execute format('insert into %s select %s, $2, 0 on conflict do nothing', _gnomon.obj(t, 'sched'),
                   case when t.wide_key then format('_gnomon.%I(%s)', t.base || '__rid', (select string_agg(format('($1->>%L)::%s', k.raw, k.typ), ', ') from unnest(_gnomon.keys(cs)) k))
                        else (select string_agg(format('($1->>%L)::%s', k.raw, k.typ), ', ') from unnest(_gnomon.keys(cs)) k) end)
      using key, valid_from;
  end if;
  perform _gnomon.bt_sync_current(t.id, key);
  perform gnomon._log_xact(0, null, null, jsonb_build_object('correction', jsonb_build_object('table', tbl::text, 'key', key,
                                          'valid_from', valid_from, 'valid_to', valid_to)));
end $$;
grant execute on function gnomon.correct(regclass, jsonb, timestamptz, timestamptz, jsonb) to public;
revoke all on function _gnomon.bt_write_point(int, jsonb, jsonb, timestamptz, int, int8) from public;
revoke all on function _gnomon.bt_sync_current(int, jsonb) from public;

-- Scheduled changes that came due: main's current table catches up (called by the ticker).
create function gnomon.apply_scheduled() returns int language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; r record; n int := 0;
begin
  for t in select * from gnomon.tracked where mode = 'bitemporal' loop
    for r in execute format('delete from %s s where s.gn_valid_from <= now() returning %s as k',
                            _gnomon.obj(t, 'sched'),
                            case when t.wide_key then format('(select %s from %s i where i.gn_rid = s.gn_rid)', _gnomon.key_sql(t, 'i'), _gnomon.obj(t, 'id'))
                                 else _gnomon.key_sql(t, 's') end) loop
      perform _gnomon.bt_sync_current(t.id, r.k);
      n := n + 1;
    end loop;
  end loop;
  return n;
end $$;
