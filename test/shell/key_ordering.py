"""A transaction's old snapshot must not put a reused key before a concurrent delete in history."""
import os
import sys

import psycopg


failures = []
cases = ['row', 'statement', 'logged', 'scratch']
if os.environ.get('GNOMON_C'):
    cases.append('c')

with psycopg.connect(dbname=sys.argv[1], autocommit=True) as older, \
     psycopg.connect(dbname=sys.argv[1], autocommit=True) as newer:
    case_id = 0
    for isolation in ['read committed', 'repeatable read', 'serializable']:
        for mode in cases:
            for deleted in [False, True]:
                case_id += 1
                table = f'ko_{case_id}'
                label = f'{isolation}, {mode}, final {"delete" if deleted else "update"}'
                newer.execute("select gnomon.use('main')")
                newer.execute(f'create table {table} (id int primary key, v int)')
                newer.execute('select gnomon.track(%s::regclass)', (table,))
                if mode == 'row' and os.environ.get('GNOMON_C'):
                    newer.execute('select gnomon.use_c_trigger(%s::regclass, false)', (table,))
                branch = 'main'
                if mode in ['logged', 'scratch']:
                    branch = table
                    newer.execute('select gnomon.create_branch(%s, kind => %s)', (branch, mode))
                elif mode == 'statement':
                    newer.execute("select gnomon.set_write_mode(%s::regclass, 'statement')", (table,))
                elif mode == 'c':
                    newer.execute('select gnomon.use_c_trigger(%s::regclass)', (table,))
                newer.execute('select gnomon.use(%s)', (branch,))

                # Leave a touched-key lock row on a branch, but no live row. Locking it later
                # does not refresh a repeatable-read snapshot: the lock row has not changed.
                newer.execute(f'insert into {table} values (1, 0)')
                newer.execute(f'delete from {table} where id = 1')
                older.execute(f'begin isolation level {isolation}')
                older.execute('select gnomon.begin(%s)', (branch,))
                older.execute('select pg_current_xact_id(), pg_current_snapshot()')
                newer.execute(f'insert into {table} values (1, 2)')
                newer.execute(f'delete from {table} where id = 1')
                older.execute(f'insert into {table} values (1, 3)')
                # Later writes in the same transaction must also stay after the fresh insert.
                older.execute(f'update {table} set v = 4 where id = 1')
                if deleted:
                    older.execute(f'delete from {table} where id = 1')
                older.execute('commit')

                coordinate, live = newer.execute(
                    f"select gnomon.coordinate_text(), coalesce(jsonb_agg(v order by id), '[]') from {table}"
                ).fetchone()
                assert live == ([] if deleted else [4]), (label, live)
                # Force a historical read even on main: it cannot take the unchanged-row path.
                newer.execute(f'delete from {table} where id = 1')
                newer.execute(f'insert into {table} values (1, 99)')
                newer.execute('select gnomon.use(%s, %s)', (branch, coordinate))
                replay = newer.execute(
                    f"select coalesce(jsonb_agg(v order by id), '[]') from {table}"
                ).fetchone()[0]
                if replay != live:
                    failures.append(f'{label}: recorded {live}, replayed {replay}')
                newer.execute("select gnomon.use('main')")
                suffix = 'bv_u' if mode == 'scratch' else 'bv' if mode == 'logged' else 'v'
                inversions = newer.execute(
                    f'select count(*) from (select gn_key, lag(gn_key) over (order by gn_lsn) previous '
                    f'from _gnomon.{table}__{suffix} where gn_flags & 48 = 0) versions where gn_key < previous'
                ).fetchone()[0]
                if inversions:
                    failures.append(f'{label}: {inversions} version keys went backwards')

assert not failures, '\n' + '\n'.join(failures)
print(f'ok: {case_id} key-reuse and historical-replay cases')
