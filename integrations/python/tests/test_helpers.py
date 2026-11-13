import psycopg
import pytest

import gnomon


def test_branch_dsn_routes_a_new_connection(gnomon_dsn):
    with psycopg.connect(gnomon_dsn, autocommit=True) as admin:
        gnomon.create_branch(admin, "dsn-branch")
    try:
        with psycopg.connect(gnomon.branch_dsn(gnomon_dsn, "dsn-branch")) as c:
            c.execute("update account set name = 'via dsn' where id = 2")
            c.commit()
            assert c.execute("select name from account where id = 2").fetchone()[0] == "via dsn"
        with psycopg.connect(gnomon_dsn) as c:
            assert c.execute("select name from account where id = 2").fetchone()[0] == "acct 2"
    finally:
        with psycopg.connect(gnomon_dsn, autocommit=True) as admin:
            gnomon.drop_branch(admin, "dsn-branch")


def test_context_manager_merge_and_diff(gnomon_dsn):
    with psycopg.connect(gnomon_dsn, autocommit=True) as c:
        gnomon.create_branch(c, "ctx")
        with gnomon.branch(c, "ctx"):
            c.execute("update account set balance = 5 where id = 3")
        assert c.execute("select balance from account where id = 3").fetchone()[0] == 100
        d = gnomon.diff(c, "ctx")
        assert d and d[0]["col"] == "balance" and d[0]["new"] == 5
        m = gnomon.merge(c, "ctx")
        assert m["status"] == "applied"
        assert c.execute("select balance from account where id = 3").fetchone()[0] == 5
        c.execute("update account set balance = 100 where id = 3")
        gnomon.drop_branch(c, "ctx")


def test_begin_lasts_one_transaction(gnomon_dsn):
    with psycopg.connect(gnomon_dsn, autocommit=True) as admin:
        gnomon.create_branch(admin, "tx-branch")
    try:
        with psycopg.connect(gnomon_dsn) as c:
            gnomon.begin(c, "tx-branch")
            c.execute("update account set name = 'tx' where id = 4")
            c.commit()
            assert c.execute("select name from account where id = 4").fetchone()[0] == "acct 4"
            gnomon.begin(c, "tx-branch")
            assert c.execute("select name from account where id = 4").fetchone()[0] == "tx"
            c.rollback()
    finally:
        with psycopg.connect(gnomon_dsn, autocommit=True) as admin:
            gnomon.drop_branch(admin, "tx-branch")


def test_routing_schema_and_scratch_options():
    assert gnomon.routing_schema("public") == "gnomon_r_public"
    assert gnomon.routing_schema("app", scratch=True) == "gnomon_r_app__s"
    assert gnomon.branch_options("s", scratch=True) == "-c gnomon.branch=s -c search_path=gnomon_r_public__s,public"


def test_scratch_branch_dsn(gnomon_dsn):
    import psycopg
    with psycopg.connect(gnomon_dsn, autocommit=True) as admin:
        name = gnomon.create_scratch(admin, "dsn")
        with psycopg.connect(gnomon.branch_dsn(gnomon_dsn, name, scratch=True), autocommit=True) as c:
            # (read through the logged routing schema, a scratch branch is refused: 55000)
            c.execute("update account set name = 'scratch dsn' where id = 4")
            assert c.execute("select name from account where id = 4").fetchone()[0] == "scratch dsn"
        assert admin.execute("select name from account where id = 4").fetchone()[0] != "scratch dsn"
        gnomon.drop_branch(admin, name)


def test_connection_options_follow_a_schema_version(gnomon_dsn):
    """The database's options name the branch's schema version: a column added on
    the branch is read through a connection opened with them."""
    with psycopg.connect(gnomon_dsn, autocommit=True) as admin:
        gnomon.create_branch(admin, "py-sv")
        gnomon.use(admin, "py-sv")
        admin.execute("select gnomon.ddl($$alter table account add column tier text default 'basic'$$)")
        gnomon.use(admin, "main")
        opts = gnomon.connection_options(admin, "py-sv")
    try:
        assert "__v" in opts
        with psycopg.connect(gnomon.branch_dsn(gnomon_dsn, "py-sv", options=opts)) as c:
            assert c.execute("select tier from account where id = 1").fetchone()[0] == "basic"
    finally:
        with psycopg.connect(gnomon_dsn, autocommit=True) as admin:
            gnomon.drop_branch(admin, "py-sv")
