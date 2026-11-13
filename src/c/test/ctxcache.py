"""The C module's read context is reused across statements while the catalog rows it came from
are unchanged. Another session's rebase, merge, re-tag or branch change must reach this session's
very next statement (src/c/test/ctxcache.sh runs this)."""
import sys
import psycopg

H = dict(host=sys.argv[1], port=int(sys.argv[2]), user='postgres')
adm = psycopg.connect(dbname='postgres', autocommit=True, **H)
adm.execute("drop database if exists gc_ctxcache")
adm.execute("create database gc_ctxcache")
db = dict(dbname='gc_ctxcache', **H)
b = psycopg.connect(autocommit=True, **db)   # the other session
b.execute("set client_min_messages = warning")
b.execute("create extension gnomon")
b.execute("create extension gnomon_c")
b.execute("create table t (id int primary key, v int)")
b.execute("insert into t select g, g from generate_series(1, 10) g")
b.execute("select gnomon.track('t')")
b.execute("select gnomon.create_branch('f')")
b.execute("insert into gnomon.tag(name, coord) select 'tg', gnomon.coordinate()")

a = psycopg.connect(autocommit=True, **db)   # the reading session, on the branch through the C module
a.execute("set gnomon.branch = 'f'")
def v(conn, i=1):
    return conn.execute("select v from t where id = %s", (i,)).fetchone()[0]
def check(got, want, what):
    if got != want:
        print(f"FAILED: {what}: got {got}, expected {want}"); sys.exit(1)

check(v(a), 1, "branch at the fork")
for _ in range(3):
    v(a)                                      # warm the cached context
b.execute("update t set v = 99 where id = 1")
check(v(a), 1, "main's change after the fork is not on the branch")
b.execute("select gnomon.rebase('f')")        # another session moves the branch's base
check(v(a), 99, "the next statement after another session's rebase")

# merge into the branch's parent moves its base too
b.execute("select gnomon.use('f')"); b.execute("update t set v = 7 where id = 2"); b.execute("select gnomon.use('main')")
check(v(a, 2), 7, "branch write seen on the branch")
b.execute("update t set v = 55 where id = 3")
check(v(a, 3), 3, "main's change after the rebase is not on the branch")
b.execute("select gnomon.merge('f')")
check(v(a, 3), 55, "after another session's merge the branch is based on main's new state")

# as of a tag, re-tagged by another session
a.execute("set gnomon.branch = ''")
a.execute("set gnomon.as_of = 'tag:tg'")
check(v(a, 1), 1, "as of the tag")
for _ in range(3):
    v(a, 1)
b.execute("update gnomon.tag set coord = gnomon.coordinate() where name = 'tg'")
check(v(a, 1), 99, "after another session moved the tag")
print("ok")
