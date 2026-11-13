-- Branch writes in the SQL core: INSTEAD OF triggers on routing views.
--   iot  (security invoker): main-now writes go straight to the table as the caller;
--        anything else goes to bw.
--   bw   (security definer, gnomon_writer): context, privilege and acl checks.
--   bwi  (security definer, internal): copy-up, locking, constraint emulation, history.
--        One per branch kind (logged, scratch). Cascades call a child's bwi directly.

-- The C module's upsert spec: JSON (action, arbiter, arbiter_exprs, pred, set,
-- where), or the older action|arbiter columns|update columns form.
create function _gnomon.upsert_spec() returns jsonb language plpgsql stable as $$
declare up text := coalesce(current_setting('gnomon._upsert', true), '');
begin
  if up = '' then return null; end if;
  if left(up, 1) = '{' then return up::jsonb; end if;
  return jsonb_build_object('action', split_part(up, '|', 1),
    'arbiter', to_jsonb(coalesce(string_to_array(nullif(split_part(up, '|', 2), ''), ','), '{}')),
    'set', (select coalesce(jsonb_object_agg(x, format('gn_x.%I', x)), '{}') from unnest(string_to_array(nullif(split_part(up, '|', 3), ''), ',')) x));
end $$;

-- How an existing row v conflicts with the proposed row p: the arbiter's columns (the key when
-- none is named), its expressions, and a partial index's predicate over v.
create function _gnomon.upsert_match(spec jsonb, keys text[]) returns text language sql immutable as $$
  select concat_ws(' AND ',
           (select string_agg(format('v.%1$I = p.%1$I', x), ' AND ')
              from jsonb_array_elements_text(case when jsonb_array_length(coalesce(spec -> 'arbiter', '[]')) = 0 and spec -> 'arbiter_exprs' is null
                                                  then to_jsonb(keys) else coalesce(spec -> 'arbiter', '[]') end) x),
           (select string_agg(format('(%s) = (%s)', e ->> 'v', e ->> 'p'), ' AND ') from jsonb_array_elements(coalesce(spec -> 'arbiter_exprs', '[]')) e),
           case when spec ->> 'pred' is not null then '(' || (spec ->> 'pred') || ')' end)
$$;

-- The row a DO UPDATE writes: the existing row with the SET expressions applied, evaluated over
-- it (gn_t) and the excluded row (gn_x); null when the WHERE clause says no.
create function _gnomon.upsert_row(ex anyelement, n anyelement) returns anyelement language plpgsql volatile as $$
declare spec jsonb := _gnomon.upsert_spec(); res jsonb; ok bool;
begin
  execute format('select %s, (%s) from (select ($1).*) gn_t, (select ($2).*) gn_x',
                 coalesce((select 'jsonb_build_object(' || string_agg(format('%L, (%s)', k, v), ', ') || ')'
                             from jsonb_each_text(coalesce(spec -> 'set', '{}')) s(k, v)), '''{}''::jsonb'),
                 coalesce(spec ->> 'where', 'true'))
    into res, ok using ex, n;
  if not coalesce(ok, false) then return null; end if;
  return jsonb_populate_record(ex, res);
end $$;

create function gnomon._write_check(c _gnomon.ctx, tid int, op text, who text, rview regclass) returns void
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch; conf gnomon.confined;
begin
  if c.asof is not null then
    raise exception 'writes are refused while gnomon.as_of is set (reading the past is read-only)' using errcode = '25006', hint = '[gnomon:writes_refused_while_as_of]';
  end if;
  select * into b from gnomon.branch where id = c.branch;
  if b.status <> 'open' then
    raise exception 'branch "%" is %; it no longer accepts writes', b.name, b.status using errcode = '25006',
      hint = '[gnomon:branch_closed]';
  end if;
  if b.over_quota is not null then
    raise exception 'branch "%" is over its quota: %', b.name, b.over_quota using errcode = '53400',
      hint = 'Merge or drop work on it, or raise the quota (gnomon.set_quota). [gnomon:over_quota]';
  end if;
  if not has_table_privilege(who, rview, op) then
    raise exception 'permission denied for table %', rview using errcode = '42501', hint = '[gnomon:permission_denied_table]';
  end if;
  select * into conf from gnomon.confined where role = who;
  if conf.role is not null and not exists (select 1 from gnomon.acl a where a.role = who and a.branch = c.branch and a.can_write) then
    raise exception 'role % is confined and may not write branch "%"', who, b.name using errcode = '42501', hint = '[gnomon:role_confined_may_not]';
  end if;
  if gnomon._cfg('event_triggers') = 'off' then
    perform _gnomon.fingerprint_check(tid);
  end if;
end $$;
grant execute on function gnomon._write_check(_gnomon.ctx, int, text, text, regclass) to public;

-- The routing view a branch-write body reads a related table through: a token resolved to the
-- logged or the scratch view when the body for that branch kind is generated (rv_detok).
create function _gnomon.fk_routes(rel regclass) returns text language sql stable as $$
  select _gnomon.rv_tok(rel)
$$;

create function _gnomon.gen_write(tid int) returns void language plpgsql volatile
set search_path = pg_catalog, pg_temp as $g$
declare
  t gnomon.tracked := _gnomon.trow(tid);
  cs _gnomon.col[] := _gnomon.tcols(tid);
  ks _gnomon.col[] := _gnomon.keys(cs);
  ng _gnomon.col[] := _gnomon.nongen(cs);
  upd _gnomon.col[];
  q text := _gnomon.qrel(_gnomon.trow(tid));
  R text := _gnomon.rv_tok((_gnomon.trow(tid)).rel);
  checks text := ''; fkdel text := ''; fkupd text := ''; fkupd_cas text := '';
  con record; sfx text; body text; has_utrig bool; trg record; def text; guard text;
  pcols text; ccols text; ptgt text; ctrack gnomon.tracked; cfn text; setnull text;
begin
  upd := (select coalesce(array_agg(x order by x.num), '{}') from unnest(ng) x where x.ident is distinct from 'a');

  -- 3. constraint emulation: primary key and unique constraints against the merged view
  checks := checks || format($c$
    IF op = 'INSERT' AND EXISTS (SELECT 1 FROM %s v WHERE %s) THEN
      RAISE EXCEPTION 'duplicate key value violates unique constraint "%s" on branch "%%"', gnomon.current_branch()
        USING ERRCODE = '23505', DETAIL = format('Key (%s)=(%%s) already exists.', concat_ws(', ', %s));
    END IF;$c$, R, _gnomon.eqs(ks, 'v', 'n'),
      (select conname from pg_constraint where conrelid = t.rel and contype = 'p'),
      _gnomon.lst(ks), _gnomon.lst(ks, 'n.'));
  -- every unique index on plain columns, constraint or not (partial and expression indexes are
  -- checked among the branch's own rows by the mirrors only: docs/branches.md)
  for con in
    select ci.relname as conname,
           (select array_agg(a.attname order by k.ord) from unnest(i.indkey) with ordinality k(attnum, ord)
              join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum) as cols
      from pg_index i join pg_class ci on ci.oid = i.indexrelid
     where i.indrelid = t.rel and i.indisunique and not i.indisprimary and i.indexprs is null and i.indpred is null
  loop
    checks := checks || format($c$
    IF %1$s AND (op = 'INSERT' OR %2$s)
       AND EXISTS (SELECT 1 FROM %3$s v WHERE %4$s AND NOT (%5$s)) THEN
      RAISE EXCEPTION 'duplicate key value violates unique constraint "%6$s" on branch "%%"', gnomon.current_branch()
        USING ERRCODE = '23505';
    END IF;$c$,
      (select string_agg(format('n.%I IS NOT NULL', x), ' AND ') from unnest(con.cols) x),
      (select string_agg(_gnomon.ne(c2, 'n.' || c2.q, 'o.' || c2.q), ' OR ') from unnest(cs) c2 where c2.raw = any(con.cols)),
      R,
      (select string_agg(_gnomon.eq(c2, 'v.' || c2.q, 'n.' || c2.q), ' AND ') from unnest(cs) c2 where c2.raw = any(con.cols)),
      _gnomon.eqs(ks, 'v', 'n'), con.conname);
  end loop;
  -- foreign keys from this table: the parent must exist in the merged view
  for con in
    select c.conname, c.confrelid::regclass as parent,
           (select array_agg(a.attname order by k.ord) from unnest(c.conkey) with ordinality k(attnum, ord)
              join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum) as cols,
           (select array_agg(a.attname order by k.ord) from unnest(c.confkey) with ordinality k(attnum, ord)
              join pg_attribute a on a.attrelid = c.confrelid and a.attnum = k.attnum) as rcols
      from pg_constraint c where c.conrelid = t.rel and c.contype = 'f'
  loop
    checks := checks || format($c$
    IF %1$s AND (op = 'INSERT' OR %2$s)
       AND NOT EXISTS (SELECT 1 FROM %3$s p WHERE %4$s) THEN
      RAISE EXCEPTION 'insert or update on table "%5$s" violates foreign key constraint "%6$s" on branch "%%"', gnomon.current_branch()
        USING ERRCODE = '23503';
    END IF;$c$,
      (select string_agg(format('n.%I IS NOT NULL', x), ' AND ') from unnest(con.cols) x),
      (select string_agg(_gnomon.ne(c2, 'n.' || c2.q, 'o.' || c2.q), ' OR ') from unnest(cs) c2 where c2.raw = any(con.cols)),
      _gnomon.fk_routes(con.parent),
      (select string_agg(format('p.%I = n.%I', con.rcols[i], con.cols[i]), ' AND ') from generate_subscripts(con.cols, 1) i),
      t.relname, con.conname);
  end loop;

  -- foreign keys into this table: emulate ON DELETE / ON UPDATE on the branch
  for con in
    select c.conname, c.conrelid::regclass as child, c.confdeltype, c.confupdtype,
           (select array_agg(a.attname order by k.ord) from unnest(c.conkey) with ordinality k(attnum, ord)
              join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum) as cols,
           (select array_agg(a.attname order by k.ord) from unnest(c.confkey) with ordinality k(attnum, ord)
              join pg_attribute a on a.attrelid = c.confrelid and a.attnum = k.attnum) as rcols
      from pg_constraint c where c.confrelid = t.rel and c.contype = 'f'
  loop
    ccols := (select string_agg(format('ch.%I = o.%I', con.cols[i], con.rcols[i]), ' AND ') from generate_subscripts(con.cols, 1) i);
    select * into ctrack from gnomon.tracked where rel = con.child;
    if ctrack.id is null or con.confdeltype in ('a', 'r') then
      fkdel := fkdel || format($c$
      IF EXISTS (SELECT 1 FROM %s ch WHERE %s) THEN
        RAISE EXCEPTION 'update or delete on table "%s" violates foreign key constraint "%s" on table "%s" on branch "%%"', gnomon.current_branch()
          USING ERRCODE = '23503';
      END IF;$c$, _gnomon.fk_routes(con.child), ccols, t.relname, con.conname, con.child);
    else
      cfn := _gnomon.obj(ctrack, 'bwi');
      if con.confdeltype = 'c' then
        fkdel := fkdel || format($c$
      FOR rr_%5$s IN SELECT ch.* FROM %1$s ch WHERE %2$s LOOP
        IF c.kind = 'scratch' THEN PERFORM %3$s_u('DELETE', rr_%5$s, NULL, c, sp);
        ELSE PERFORM %3$s('DELETE', rr_%5$s, NULL, c, sp); END IF;
      END LOOP;$c$, _gnomon.rv_tok(ctrack.rel), ccols, cfn, con.child, ctrack.id);
      else
        setnull := (select string_agg(format('nn_%s.%I := %s;', ctrack.id, x, case when con.confdeltype = 'n' then 'NULL' else
                       coalesce((select pg_get_expr(d.adbin, d.adrelid) from pg_attrdef d join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
                                  where d.adrelid = con.child and a.attname = x), 'NULL') end), ' ') from unnest(con.cols) x);
        fkdel := fkdel || format($c$
      FOR rr_%5$s IN SELECT ch.* FROM %1$s ch WHERE %2$s LOOP
        nn_%5$s := rr_%5$s; %4$s
        IF c.kind = 'scratch' THEN PERFORM %3$s_u('UPDATE', rr_%5$s, nn_%5$s, c, sp);
        ELSE PERFORM %3$s('UPDATE', rr_%5$s, nn_%5$s, c, sp); END IF;
      END LOOP;$c$, _gnomon.rv_tok(ctrack.rel), ccols, cfn, setnull, ctrack.id);
      end if;
    end if;
    -- ON UPDATE of the referenced columns: refused while referenced (NO ACTION, RESTRICT, or a child
    -- gnomon does not track), else the referencing rows follow (CASCADE: to the new values; SET
    -- NULL, SET DEFAULT). The refusal runs before the write, the others after (fkupd_cas): for a
    -- key change, once the row with the new key exists.
    pcols := (select string_agg(format('(n.%1$I IS DISTINCT FROM o.%1$I)', x), ' OR ') from unnest(con.rcols) x);
    if ctrack.id is null or con.confupdtype in ('a', 'r') then
      fkupd := fkupd || format($c$
      IF (%s) AND EXISTS (SELECT 1 FROM %s ch WHERE %s) THEN
        RAISE EXCEPTION 'update on table "%s" violates foreign key constraint "%s" on table "%s" on branch "%%"', gnomon.current_branch()
          USING ERRCODE = '23503';
      END IF;$c$, pcols, _gnomon.fk_routes(con.child), ccols, t.relname, con.conname, con.child);
    else
      fkupd_cas := fkupd_cas || format($c$
      IF (%1$s) THEN
        FOR rr_%6$s IN SELECT ch.* FROM %2$s ch WHERE %3$s LOOP
          nu_%6$s := rr_%6$s; %7$s
          IF c.kind = 'scratch' THEN PERFORM %4$s_u('UPDATE', rr_%6$s, nu_%6$s, c, sp);
          ELSE PERFORM %4$s('UPDATE', rr_%6$s, nu_%6$s, c, sp); END IF;
        END LOOP;
      END IF;$c$, pcols, _gnomon.rv_tok(ctrack.rel), ccols, _gnomon.obj(ctrack, 'bwi'), con.child, ctrack.id,
        case when con.confupdtype = 'c' then
          (select string_agg(format('nu_%s.%I := n.%I;', ctrack.id, con.cols[i], con.rcols[i]), ' ') from generate_subscripts(con.cols, 1) i)
        else
          (select string_agg(format('nu_%s.%I := %s;', ctrack.id, x, case when con.confupdtype = 'n' then 'NULL' else
                    coalesce((select pg_get_expr(d.adbin, d.adrelid) from pg_attrdef d join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
                               where d.adrelid = con.child and a.attname = x), 'NULL') end), ' ') from unnest(con.cols) x)
        end);
    end if;
  end loop;

  -- user triggers mirrored onto the branch heads
  has_utrig := exists (select 1 from pg_trigger tg where tg.tgrelid = t.rel and not tg.tgisinternal and tg.tgname not like 'gnomon%');

  foreach sfx in array array['', '_u'] loop
    body := _gnomon.tpl($b$
create or replace function @FN@(op text, o @REL@, n @REL@, c _gnomon.ctx, sp text) returns @REL@
language plpgsql security definer set search_path = pg_catalog, pg_temp 
set enable_seqscan = off as $f$
#variable_conflict use_variable
declare st gnomon.stamp; r @REL@; h @REL@; kr @REL@; hfound bool; ins bool; fl int2; rr record; km bool; uu bool;@NNDECL@
begin
  -- constraint probes read the merged view of the branch being written, whichever the session is on
  IF coalesce(current_setting('gnomon.branch', true), '') IS DISTINCT FROM c.name
     OR coalesce(current_setting('gnomon.as_of', true), '') <> '' THEN
    PERFORM set_config('gnomon.branch', c.name, true);
    PERFORM set_config('gnomon.as_of', '', true);
  END IF;
  -- a delete made for a key change: rows referencing the old key follow the ON UPDATE rules, not ON DELETE
  km := coalesce(current_setting('gnomon._keymove', true), '') = '1';
  IF km THEN PERFORM set_config('gnomon._keymove', '', true); END IF;
  -- the update half of an upsert on this table (consumed here, so cascades and later rows never see it)
  uu := op = 'UPDATE' AND coalesce(current_setting('gnomon._upsert_upd', true), '') = '@TID@';
  IF uu OR coalesce(current_setting('gnomon._upsert_upd', true), '') <> '' THEN PERFORM set_config('gnomon._upsert_upd', '', true); END IF;
  IF NOT uu AND coalesce(current_setting('gnomon._upsert_excl', true), '') <> '' AND op <> 'UPDATE' THEN PERFORM set_config('gnomon._upsert_excl', '', true); END IF;
  IF op = 'UPDATE' AND NOT (@KEYS_SAME@) THEN    -- a key change is a delete plus an insert
    IF TRUE THEN@FKUPD@
    END IF;
    PERFORM set_config('gnomon._keymove', '1', true);
    PERFORM @FN@('DELETE', o, NULL, c, sp);
    r := @FN@('INSERT', NULL, n, c, sp);
    IF r IS NOT NULL THEN@FKUPD_CAS@
    END IF;
    RETURN r;
  END IF;
  -- INSERT ... ON CONFLICT rewritten by the C module: gnomon._upsert = action|arbiter cols|update cols
  IF op = 'INSERT' AND coalesce(current_setting('gnomon._upsert', true), '') <> '' THEN
    DECLARE spec jsonb := _gnomon.upsert_spec(); ex @REL@; nn2 @REL@;
    BEGIN
      EXECUTE format('SELECT v.* FROM @R@ v, jsonb_populate_record(null::@REL@, $1) p WHERE %s LIMIT 1', _gnomon.upsert_match(spec, @KEYARR@))
        INTO ex USING to_jsonb(n);
      IF ex IS NOT NULL THEN
        IF spec ->> 'action' = 'nothing' THEN RETURN NULL; END IF;
        nn2 := _gnomon.upsert_row(ex, n);
        IF nn2 IS NULL THEN RETURN NULL; END IF;   -- DO UPDATE ... WHERE said no: the row stays
        PERFORM set_config('gnomon._upsert_upd', '@TID@', true);   -- (see the lock wait below)
        PERFORM set_config('gnomon._upsert_excl', to_jsonb(n)::text, true);
        RETURN @FN@('UPDATE', ex, nn2, c, sp);
      END IF;
    END;
  END IF;
  IF op <> 'DELETE' THEN@CHECKS@
  END IF;
  kr := CASE WHEN op = 'INSERT' THEN n ELSE o END;
  st := gnomon._stamp();
  -- 2. lock this key on this branch: the touched-key row is the lock (first touch inserts it)
  INSERT INTO @BK@ (gn_branch, @KS@, gn_fkey, gn_fxoff) VALUES (c.branch, @KR@, st.key, st.xoff)
    ON CONFLICT DO NOTHING RETURNING true INTO ins;
  ins := coalesce(ins, false);
  IF NOT ins THEN
    PERFORM 1 FROM @BK@ k WHERE k.gn_branch = c.branch AND @EQ_K@ FOR UPDATE;
    -- stamp again now that the lock is held: the previous writer of this key on this branch has
    -- committed, so this snapshot's xmax is past its xid (keys along a row never decrease; a stamp taken before a
    -- lock wait can order this version before the one it follows)
    st := gnomon._stamp();
  END IF;
  SELECT @HCOLS@ INTO h FROM @B@ b WHERE b.gn_branch = c.branch AND @EQ_B@;
  hfound := FOUND;
  IF op <> 'INSERT' THEN
    IF NOT hfound THEN
      IF NOT ins THEN
        RAISE EXCEPTION 'could not serialize access: row was deleted on branch "%" by a concurrent transaction', gnomon.current_branch()
          USING ERRCODE = '40001';
      END IF;
    ELSIF NOT (h *= o) THEN
      IF uu THEN
        -- an upsert's update, and another session changed the row while this one waited for its
        -- lock: it applies to the row as it is now, as PostgreSQL's own upsert does after a wait
        -- (SET expressions and WHERE evaluated again over it)
        n := _gnomon.upsert_row(h, jsonb_populate_record(h, coalesce(nullif(current_setting('gnomon._upsert_excl', true), ''), to_jsonb(n)::text)::jsonb));
        IF n IS NULL THEN @RESET@ RETURN NULL; END IF;
        o := h;
      ELSE
        RAISE EXCEPTION 'could not serialize access: row changed on branch "%" since this statement read it', gnomon.current_branch()
          USING ERRCODE = '40001', HINT = 'Retry the transaction.';
      END IF;
    END IF;
  ELSIF hfound THEN
    -- INSERT ... ON CONFLICT (the C module): another session inserted this key first, and this one
    -- waited for its lock: now it is the conflict case, as PostgreSQL's own upsert finds after a wait
    IF coalesce(current_setting('gnomon._upsert', true), '') <> '' THEN
      IF _gnomon.upsert_spec() ->> 'action' = 'nothing' THEN @RESET@ RETURN NULL; END IF;
      DECLARE nn3 @REL@ := _gnomon.upsert_row(h, n);
      BEGIN
        IF nn3 IS NULL THEN @RESET@ RETURN NULL; END IF;
        PERFORM set_config('gnomon._upsert_upd', '@TID@', true);
        PERFORM set_config('gnomon._upsert_excl', to_jsonb(n)::text, true);
        RETURN @FN@('UPDATE', h, nn3, c, sp);
      END;
    END IF;
    RAISE EXCEPTION 'duplicate key value violates unique constraint on branch "%"', gnomon.current_branch() USING ERRCODE = '23505';
  END IF;
  IF op = 'UPDATE' THEN@FKUPD@
  ELSIF op = 'DELETE' AND NOT km THEN@FKDEL@
  END IF;@SETPATH@
  IF op = 'INSERT' THEN
    INSERT INTO @B@ AS b (@NG@, gn_branch) VALUES (@NG_N@, c.branch) RETURNING @RCOLS@ INTO r;
    IF NOT FOUND THEN @RESET@ RETURN NULL; END IF;
    fl := 9;
  ELSE
    IF NOT hfound THEN   -- copy-up of the ancestor row, with user triggers suppressed
      PERFORM set_config('gnomon._cu', '1', true);
      INSERT INTO @B@ (@NG@, gn_branch) VALUES (@NG_O@, c.branch);
      PERFORM set_config('gnomon._cu', '', true);
    END IF;
    IF op = 'UPDATE' THEN
      UPDATE @B@ b SET (@UPD@) = ROW(@UPD_N@) WHERE b.gn_branch = c.branch AND @EQ_BO@ RETURNING @RCOLS@ INTO r;
      IF NOT FOUND THEN @RESET@ RETURN NULL; END IF;
      fl := 2;
    ELSE
      DELETE FROM @B@ b WHERE b.gn_branch = c.branch AND @EQ_BO@;
      IF NOT FOUND THEN @RESET@ RETURN NULL; END IF;
      r := o; fl := 4;
    END IF;
  END IF;@RESET@
  IF fl = 2 AND current_setting('gnomon._lockonly', true) = '1' THEN fl := 18; END IF;   -- a copy taken to lock the row
  -- 5. history
  INSERT INTO @BV@ (@ALL@, gn_branch, gn_key, gn_xoff, gn_lsn, gn_role, gn_flags)
  VALUES (@ALL_R@, c.branch, st.key, st.xoff, st.lsn, st.role, fl);
  IF coalesce(current_setting('gnomon.actor', true), '') <> '' OR coalesce(current_setting('gnomon.reason', true), '') <> '' THEN
    PERFORM gnomon._log_xact(c.branch);
  END IF;
  IF op = 'UPDATE' THEN@FKUPD_CAS@
  END IF;
  RETURN r;
end $f$;$b$,
      'FN', _gnomon.obj(t, 'bwi') || sfx, 'REL', q, 'TID', tid::text,
      'NNDECL', (select coalesce(string_agg(format(' nn_%s %s; nu_%s %s; rr_%s %s;', tc.id, tc.rel, tc.id, tc.rel, tc.id, tc.rel), ''), '')
                   from gnomon.tracked tc where tc.rel in (select conrelid from pg_constraint where confrelid = t.rel and contype = 'f')),
      'KEYS_SAME', _gnomon.eqs(ks, 'n', 'o'), 'CHECKS', checks,
      'BK', _gnomon.obj(t, 'bk' || sfx), 'B', _gnomon.obj(t, 'b' || sfx), 'BV', _gnomon.obj(t, 'bv' || sfx),
      'KS', _gnomon.lst(ks), 'KR', _gnomon.lst(ks, 'kr.'), 'EQ_K', _gnomon.eqs(ks, 'k', 'kr'), 'EQ_B', _gnomon.eqs(ks, 'b', 'kr'),
      'EQ_BO', _gnomon.eqs(ks, 'b', 'o'),
      'HCOLS', _gnomon.lst(cs, 'b.'), 'RCOLS', _gnomon.lst(cs, 'b.'), 'NG', _gnomon.lst(ng), 'NG_N', _gnomon.lst(ng, 'n.'),
      'NG_O', _gnomon.lst(ng, 'o.'), 'UPD', _gnomon.lst(upd), 'UPD_N', _gnomon.lst(upd, 'n.'),
      'ALL', _gnomon.lst(ng), 'ALL_R', _gnomon.lst(ng, 'r.'),
      'FKDEL', fkdel, 'FKUPD', fkupd, 'FKUPD_CAS', fkupd_cas, 'R', R,
      'KEYARR', format('%L::text[]', t.key_cols::text),
      'SETPATH', case when has_utrig then E'\n  IF sp IS NOT NULL THEN PERFORM set_config(''search_path'', sp, true); END IF;' else '' end,
      'RESET', case when has_utrig then 'PERFORM set_config(''search_path'', ''pg_catalog, pg_temp'', true);' else '' end);
    execute _gnomon.rv_detok(body, sfx = '_u');
    execute format('alter function %s(text, %s, %s, _gnomon.ctx, text) owner to gnomon_writer', _gnomon.obj(t, 'bwi') || sfx, q, q);
    execute format('revoke all on function %s(text, %s, %s, _gnomon.ctx, text) from public', _gnomon.obj(t, 'bwi') || sfx, q, q);
  end loop;

  -- bw: entry point with checks
  execute _gnomon.tpl($b$
create or replace function @FN@(op text, o @REL@, n @REL@, sp text) returns @REL@
language plpgsql security definer set search_path = pg_catalog, pg_temp 
set enable_seqscan = off as $f$
#variable_conflict use_variable
declare c _gnomon.ctx := gnomon._ctx();
        who text := coalesce(nullif(current_setting('role'), 'none'), session_user::text);
begin
  PERFORM gnomon._write_check(c, @TID@, op, who, '@R@'::regclass);
  IF c.kind = 'scratch' THEN RETURN @BWI@_u(op, o, n, c, sp); END IF;
  RETURN @BWI@(op, o, n, c, sp);
end $f$;$b$, 'FN', _gnomon.obj(t, 'bw'), 'REL', q, 'TID', tid::text, 'R', _gnomon.robj(t), 'BWI', _gnomon.obj(t, 'bwi'));
  execute format('alter function %s(text, %s, %s, text) owner to gnomon_writer', _gnomon.obj(t, 'bw'), q, q);

  -- iot: the INSTEAD OF trigger, as the caller
  execute _gnomon.tpl($b$
create or replace function @FN@() returns trigger language plpgsql as $f$
#variable_conflict use_variable
declare r @REL@;
begin
  -- without event triggers, DDL since the last gnomon.sync() leaves this trigger stale: refuse
  -- clearly before it handles a row of the old shape
  IF gnomon._cfg('event_triggers') = 'off' THEN PERFORM _gnomon.fingerprint_check(@TID@); END IF;
  IF (SELECT gnomon._ctx_main_now()) THEN   -- main, now: the table itself, with the caller's rights
    IF TG_OP = 'INSERT' THEN
      INSERT INTO @REL@ AS t (@NG@) OVERRIDING SYSTEM VALUE VALUES (@NG_NEW@) RETURNING * INTO r;
      RETURN r;
    -- An INSTEAD OF trigger cannot re-evaluate the statement against a row changed since the
    -- statement read it (OLD), and writing NEW over it would lose that change: a serialization
    -- failure, as on a branch. A row deleted meanwhile is skipped, as PostgreSQL does.
    ELSIF TG_OP = 'UPDATE' THEN
      UPDATE @REL@ AS t SET (@UPD@) = ROW(@UPD_NEW@) WHERE @EQ_TOLD@ AND t *= ROW(OLD.*)::@REL@ RETURNING * INTO r;
      IF NOT FOUND THEN
        PERFORM 1 FROM @REL@ AS t WHERE @EQ_TOLD@;
        IF FOUND THEN
          RAISE EXCEPTION 'could not serialize access due to concurrent update' USING ERRCODE = '40001';
        END IF;
        RETURN NULL;
      END IF;
      RETURN r;
    ELSE
      DELETE FROM @REL@ AS t WHERE @EQ_TOLD@ AND t *= ROW(OLD.*)::@REL@;
      IF NOT FOUND THEN
        PERFORM 1 FROM @REL@ AS t WHERE @EQ_TOLD@;
        IF FOUND THEN
          RAISE EXCEPTION 'could not serialize access due to concurrent update' USING ERRCODE = '40001';
        END IF;
        RETURN NULL;
      END IF;
      RETURN OLD;
    END IF;
  END IF;@RLS@
  r := @BW@(TG_OP, CASE WHEN TG_OP <> 'INSERT' THEN ROW(OLD.*)::@REL@ END,
                   CASE WHEN TG_OP <> 'DELETE' THEN ROW(NEW.*)::@REL@ END, current_setting('search_path'));
  IF r IS NULL AND TG_OP <> 'DELETE' THEN RETURN NULL; END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN r;
end $f$;$b$, 'FN', _gnomon.obj(t, 'iot'), 'REL', q, 'TID', tid::text, 'NG', _gnomon.lst(ng), 'NG_NEW', _gnomon.lst(ng, 'NEW.'),
     'UPD', _gnomon.lst(upd), 'UPD_NEW', _gnomon.lst(upd, 'NEW.'), 'EQ_TOLD', _gnomon.eqs(ks, 't', 'OLD'), 'BW', _gnomon.obj(t, 'bw'),
     -- the table's own row-level security for writes, checked here as the caller: rows the
     -- update or delete policies hide are skipped, new rows their checks refuse are an error,
     -- as on main (reads are filtered by the routing view and its policies)
     'RLS', case when not t.user_rls then '' else _gnomon.tpl($r$
  IF TG_OP IN ('UPDATE', 'DELETE') AND NOT @RLSFN@(TG_OP, 'using', ROW(OLD.*)::@REL@) THEN RETURN NULL; END IF;
  IF TG_OP IN ('INSERT', 'UPDATE') AND NOT @RLSFN@(TG_OP, 'check', ROW(NEW.*)::@REL@) THEN
    RAISE EXCEPTION 'new row violates row-level security policy for table "%"', @RELNAME@ USING ERRCODE = '42501';
  END IF;$r$, 'RLSFN', _gnomon.obj(t, 'rls'), 'REL', q, 'RELNAME', quote_literal(t.relname)) end);
  -- the policies' write predicates as one function, run as the caller (current_user in them is
  -- the caller, as on main)
  if t.user_rls then
    execute format($r$create or replace function %1$s(cmd text, part text, gn_row %2$s) returns bool
language sql stable as $f$
  select case
    when cmd = 'INSERT' then (select %3$s from (select (gn_row).*) %7$I)
    when cmd = 'UPDATE' and part = 'using' then (select %4$s from (select (gn_row).*) %7$I)
    when cmd = 'UPDATE' then (select %5$s from (select (gn_row).*) %7$I)
    when cmd = 'DELETE' then (select %6$s from (select (gn_row).*) %7$I)
  end
$f$$r$, _gnomon.obj(t, 'rls'), q,
      _gnomon.user_rls_wpred(t.rel, 'INSERT', 'check'), _gnomon.user_rls_wpred(t.rel, 'UPDATE', 'using'),
      _gnomon.user_rls_wpred(t.rel, 'UPDATE', 'check'), _gnomon.user_rls_wpred(t.rel, 'DELETE', 'using'),
      t.relname);   -- (named as the table: a policy may qualify its columns with it)
  end if;
  execute format('create trigger gnomon_iot instead of insert or update or delete on %s for each row execute function %s()',
                 _gnomon.robj(t), _gnomon.obj(t, 'iot'));
  execute format('create trigger gnomon_iot instead of insert or update or delete on %s for each row execute function %s()',
                 _gnomon.robj_s(t), _gnomon.obj(t, 'iot'));
  -- search views write through the same path
  if to_regclass(quote_ident('gnomon_q_' || t.nsp) || '.' || quote_ident(t.relname)) is not null then
    execute format('create trigger gnomon_iot instead of insert or update or delete on %I.%I for each row execute function %s()',
                   'gnomon_q_' || t.nsp, t.relname, _gnomon.obj(t, 'iot'));
  end if;

  -- mirror user triggers onto the branch heads, suppressed during copy-up
  foreach sfx in array array['', '_u'] loop
    for trg in select tg.tgname from pg_trigger tg
                where tg.tgrelid = _gnomon.obj(t, 'b' || sfx)::regclass and not tg.tgisinternal loop
      execute format('drop trigger %I on %s', trg.tgname, _gnomon.obj(t, 'b' || sfx));
    end loop;
    for trg in select tg.oid, tg.tgname from pg_trigger tg
                where tg.tgrelid = t.rel and not tg.tgisinternal and tg.tgname not like 'gnomon%' loop
      def := pg_get_triggerdef(trg.oid);
      def := replace(def, ' ON ' || q || ' ', ' ON ' || _gnomon.obj(t, 'b' || sfx) || ' ');
      guard := '(current_setting(''gnomon._cu'', true) IS DISTINCT FROM ''1'')';
      if def ~ ' WHEN \(' then
        def := regexp_replace(def, ' WHEN \((.*)\) EXECUTE ', ' WHEN (' || guard || ' AND (\1)) EXECUTE ');
      else
        def := replace(def, ' EXECUTE ', ' WHEN ' || guard || ' EXECUTE ');
      end if;
      begin
        execute def;
      exception when others then
        raise warning 'gnomon: user trigger % on % cannot be mirrored onto branches: %', trg.tgname, t.rel, sqlerrm;
      end;
    end loop;
  end loop;
end $g$;

-- SELECT ... FOR UPDATE on a branch (C module): copy the row up and lock it on the branch.
create function gnomon._lock_row(p_rel regclass, r anyelement) returns bool language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; c _gnomon.ctx := gnomon._ctx(); who text := _gnomon.who();
begin
  select * into t from gnomon.tracked tr where tr.rel = p_rel;
  if t.id is null or c.main_now or c.asof is not null then return true; end if;
  if not has_table_privilege(who, _gnomon.robj(t), 'UPDATE') then
    raise exception 'permission denied for table %', _gnomon.robj(t) using errcode = '42501', hint = '[gnomon:permission_denied_table]';
  end if;
  perform set_config('gnomon._cu', '1', true);
  perform set_config('gnomon._lockonly', '1', true);
  execute format('select %s(''UPDATE'', x, x, $2, null) from jsonb_populate_record(null::%s, $1) x',
                 _gnomon.obj(t, 'bwi') || case when c.kind = 'scratch' then '_u' else '' end, _gnomon.qrel(t))
    using to_jsonb(r), c;
  perform set_config('gnomon._lockonly', '', true);
  perform set_config('gnomon._cu', '', true);
  return true;
end $$;

-- Read-set tracking for stale-read detection (C module, 5): keys a branch transaction read.
create table _gnomon.read_set (
  branch int not null references gnomon.branch on delete cascade,
  tbl    regclass not null,
  key    jsonb not null,
  at     timestamptz not null default now(),
  seen   gnomon.coord,   -- the parent's cutoff the read saw: the parent changing after it is stale
  primary key (branch, tbl, key)
);
insert into gnomon.setting_default values
  ('read_sample', '1.0', 'Fraction of rows read on a branch that read-set tracking records (gnomon.track_reads = on).');

create function gnomon._note_read(p_rel regclass, r anyelement) returns bool language plpgsql volatile
security definer set search_path = pg_catalog, pg_temp as $$
declare t gnomon.tracked; c _gnomon.ctx := gnomon._ctx();
begin
  if c.main_now or c.asof is not null or c.branch = 0 then return true; end if;
  -- the branch's own sampling (gnomon.track_reads(branch, sample)), else the setting
  if random() > coalesce((select b.read_sample from gnomon.branch b where b.id = c.branch), gnomon._cfg('read_sample')::float8, 1) then
    return true;
  end if;
  select * into t from gnomon.tracked tr where tr.rel = p_rel;
  if t.id is null then return true; end if;
  -- (the first read of a key is kept: the oldest state the branch acted on)
  insert into _gnomon.read_set(branch, tbl, key, seen) values (c.branch, p_rel, _gnomon.keyj(t, to_jsonb(r)), coalesce(c.lc[2], c.main_cut))
    on conflict do nothing;
  return true;
end $$;

-- Read-set tracking for one branch (C module): every session that selects the branch with
-- gnomon.use() records its reads, the fraction sample of them (null: back to the setting
-- read_sample and gnomon.track_reads per session).
create function gnomon.track_reads(branch text, sample float8 default 1.0) returns void
language plpgsql volatile security definer set search_path = pg_catalog, pg_temp as $$
declare b gnomon.branch := gnomon._branch_row(branch);
begin
  if b.id = 0 then raise exception 'reads are tracked on branches' using hint = '[gnomon:reads_tracked_branches]'; end if;
  if not gnomon._may_manage(b) then raise exception 'role % may not change branch "%"', _gnomon.who(), b.name using errcode = '42501', hint = '[gnomon:role_may_not_change]'; end if;
  if sample is not null and (sample < 0 or sample > 1) then raise exception 'sample is a fraction from 0 to 1' using hint = '[gnomon:sample_fraction]'; end if;
  update gnomon.branch set read_sample = sample where id = b.id;
  perform gnomon._bump();
end $$;

-- Keys the branch read (and did not write) that the target changed since the read: since the
-- cutoff that read saw (a rebase in between does not hide a change the read missed).
create function gnomon.stale_reads(branch text)
returns table(tbl regclass, key jsonb, read_at timestamptz) language plpgsql volatile as $$
#variable_conflict use_column
declare b gnomon.branch := gnomon._branch_row(branch); bb gnomon.branch_base := gnomon._base_at((gnomon._branch_row(branch)).id, null);
        t gnomon.tracked; tgt gnomon.branch;
begin
  tgt := (select x from gnomon.branch x where x.id = bb.lin_b[1]);
  for t in select * from gnomon.tracked where rel in (select rs.tbl from _gnomon.read_set rs where rs.branch = b.id) loop
    -- one pass grouped by key (no joins of set-returning functions, which carry no row
    -- estimates), with the branch's own changes computed once
    return query
      with rk as (select rs.key, rs.at, gnomon.coord_text(coalesce(rs.seen, bb.lin_c[1])) as seen from _gnomon.read_set rs where rs.branch = b.id and rs.tbl = t.rel),
           ka as (select jsonb_agg(key) as a from rk),
           u as (select rk.key as k, 2 as side, null::jsonb as r, rk.at from rk
                 -- the target as each read saw it, by the cutoffs the reads saw (usually one)
                 union all select x.k, 0, x.r, null
                             from (select distinct rk.seen from rk) sv
                             cross join lateral _gnomon.read_rows(t.id, row(tgt.name, sv.seen)::gnomon.ref,
                                                                 (select jsonb_agg(rk2.key) from rk rk2 where rk2.seen = sv.seen)) x
                 union all select x.k, 1, x.r, null from _gnomon.read_rows(t.id, row(tgt.name, null)::gnomon.ref, (select a from ka)) x
                 union all select w.value, 3, null, null from jsonb_array_elements(_gnomon.touched_since(t.id, b.id, coalesce(_gnomon.merge_since(b.id), bb.lin_c[1]))) w),
           g as (select u.k, max(u.at) as at, (array_agg(u.r) filter (where u.side = 0))[1] as br,
                        (array_agg(u.r) filter (where u.side = 1))[1] as cr,
                        bool_or(u.side = 2) as was_read, bool_or(u.side = 3) as own
                   from u group by u.k)
      select t.rel, g.k, g.at from g where g.was_read and not g.own and g.br is distinct from g.cr;
  end loop;
end $$;
