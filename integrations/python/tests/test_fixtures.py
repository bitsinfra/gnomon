"""The pytest fixtures: each test gets its own branch of one seeded database."""
import psycopg
import pytest


@pytest.mark.parametrize("n", range(4))
def test_each_test_has_its_own_branch(gnomon_conn, n):
    # every parametrized run starts from the seed, whatever the others wrote
    assert gnomon_conn.execute("select balance from account where id = 1").fetchone()[0] == 100
    gnomon_conn.execute("update account set balance = balance + %s where id = 1", (n + 1,))
    assert gnomon_conn.execute("select balance from account where id = 1").fetchone()[0] == 101 + n
    gnomon_conn.execute("insert into account values (%s, 'new', 0)", (100 + n,))


def test_main_untouched_by_tests(gnomon_dsn):
    with psycopg.connect(gnomon_dsn) as c:
        assert c.execute("select balance from account where id = 1").fetchone()[0] == 100
        assert c.execute("select count(*) from account").fetchone()[0] == 10


def test_branch_dropped_after_test(gnomon_dsn, gnomon_branch):
    with psycopg.connect(gnomon_dsn) as c:
        assert c.execute("select count(*) from gnomon.branch where name = %s", (gnomon_branch,)).fetchone()[0] == 1
