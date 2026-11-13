import psycopg
import pytest

sqlalchemy = pytest.importorskip("sqlalchemy")
from sqlalchemy import text  # noqa: E402

import gnomon  # noqa: E402
from gnomon.sqlalchemy import attach_branch, branch_engine  # noqa: E402


def url(dsn):
    parts = dict(p.split("=", 1) for p in dsn.split())
    return f"postgresql+psycopg://{parts['user']}@/{parts['dbname']}?host={parts['host']}&port={parts['port']}"


def test_branch_engine(gnomon_dsn):
    with psycopg.connect(gnomon_dsn, autocommit=True) as admin:
        gnomon.create_branch(admin, "sa")
    try:
        eng = branch_engine(url(gnomon_dsn), "sa")
        with eng.begin() as c:
            c.execute(text("update account set name = 'orm' where id = 5"))
        with eng.connect() as c:
            assert c.execute(text("select name from account where id = 5")).scalar() == "orm"
        eng.dispose()
        main = sqlalchemy.create_engine(url(gnomon_dsn))
        with main.connect() as c:
            assert c.execute(text("select name from account where id = 5")).scalar() == "acct 5"
        main.dispose()
    finally:
        with psycopg.connect(gnomon_dsn, autocommit=True) as admin:
            gnomon.drop_branch(admin, "sa")


def test_attach_branch_per_transaction(gnomon_dsn):
    with psycopg.connect(gnomon_dsn, autocommit=True) as admin:
        gnomon.create_branch(admin, "sa2")
    current = {"b": "sa2"}
    eng = sqlalchemy.create_engine(url(gnomon_dsn), pool_size=1)
    attach_branch(eng, lambda: current["b"])
    try:
        with eng.begin() as c:
            c.execute(text("update account set name = 'per tx' where id = 6"))
        current["b"] = None
        with eng.begin() as c:   # same pooled connection, now on main
            assert c.execute(text("select name from account where id = 6")).scalar() == "acct 6"
        current["b"] = "sa2"
        with eng.begin() as c:
            assert c.execute(text("select name from account where id = 6")).scalar() == "per tx"
    finally:
        eng.dispose()
        with psycopg.connect(gnomon_dsn, autocommit=True) as admin:
            gnomon.drop_branch(admin, "sa2")


def test_orm_session_on_a_branch(gnomon_dsn):
    """The ORM itself (a declarative model and a Session), not raw SQL, on a branch engine."""
    from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column

    class Base(DeclarativeBase):
        pass

    class Note(Base):
        __tablename__ = "orm_note"
        id: Mapped[int] = mapped_column(primary_key=True)   # a serial: ids come from main's sequence
        body: Mapped[str]

    with psycopg.connect(gnomon_dsn, autocommit=True) as admin:
        admin.execute("create table if not exists orm_note (id serial primary key, body text not null)")
        admin.execute("insert into orm_note (body) values ('first'), ('second')")
        admin.execute("select gnomon.track('orm_note')")
        gnomon.create_branch(admin, "sa-orm")
    eng = branch_engine(url(gnomon_dsn), "sa-orm")
    try:
        with Session(eng) as s:
            first = s.query(Note).filter_by(body="first").one()
            first.body = "first, edited on the branch"
            s.add(Note(body="added on the branch"))
            s.delete(s.query(Note).filter_by(body="second").one())
            s.commit()
            added = s.query(Note).filter_by(body="added on the branch").one()
            assert added.id > 2   # the insert's RETURNING came back through the routing view
        with Session(eng) as s:
            assert sorted(n.body for n in s.query(Note)) == ["added on the branch", "first, edited on the branch"]
        with psycopg.connect(gnomon_dsn, autocommit=True) as admin:
            assert [r[0] for r in admin.execute("select body from orm_note order by id")] == ["first", "second"]
            assert gnomon.merge(admin, "sa-orm")["status"] == "applied"
            assert sorted(r[0] for r in admin.execute("select body from orm_note")) == ["added on the branch", "first, edited on the branch"]
    finally:
        eng.dispose()
        with psycopg.connect(gnomon_dsn, autocommit=True) as admin:
            gnomon.drop_branch(admin, "sa-orm")
