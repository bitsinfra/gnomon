"""With gnomon.report_coordinate on, the client gets the coordinate each statement read in the
reported setting gnomon.last_coordinate, and reading as of it gives the same rows (exact
replay). src/c/test/coordreport.sh runs this."""
import sys
import psycopg

H = dict(host=sys.argv[1], port=int(sys.argv[2]), user='postgres')
adm = psycopg.connect(dbname='postgres', autocommit=True, **H)
adm.execute("drop database if exists gc_coordreport")
adm.execute("create database gc_coordreport")
db = dict(dbname='gc_coordreport', **H)
w = psycopg.connect(autocommit=True, **db)
w.execute("set client_min_messages = warning")
w.execute("create extension gnomon")
w.execute("create table t (id int primary key, v int)")
w.execute("insert into t select g, g from generate_series(1, 5) g")
w.execute("select gnomon.track('t')")

def check(got, want, what):
    if got != want:
        print(f"FAILED: {what}: got {got!r}, expected {want!r}"); sys.exit(1)

r = psycopg.connect(autocommit=True, **db)
check(r.info.parameter_status('gnomon.last_coordinate') in (None, ''), True, "nothing reported before it is turned on")
r.execute("set gnomon.report_coordinate = on")
rows = r.execute("select id, v from t order by id").fetchall()
coord = r.info.parameter_status('gnomon.last_coordinate')
check(bool(coord) and coord.startswith('e'), True, f"a coordinate is reported ({coord!r})")
w.execute("update t set v = v * 10")          # main moves on
again = w.execute("select gnomon.use('main', %s)", (coord,)).fetchone()
check(w.execute("select id, v from t order by id").fetchall(), rows, "reading as of the reported coordinate replays the read exactly")
w.execute("select gnomon.use('main')")
r.execute("select count(*) from t")
check(r.info.parameter_status('gnomon.last_coordinate') != coord, True, "each statement reports its own coordinate")
# in a REPEATABLE READ transaction every statement reads the transaction's snapshot
r.execute("begin isolation level repeatable read")
r.execute("select 1 from t limit 1")
c1 = r.info.parameter_status('gnomon.last_coordinate')
w.execute("update t set v = v + 1")
r.execute("select 1 from t limit 1")
check(r.info.parameter_status('gnomon.last_coordinate').split('@')[0], c1.split('@')[0], "one snapshot per REPEATABLE READ transaction")
r.execute("commit")
r.close(); w.close()
adm.execute("drop database gc_coordreport")
print("ok")
