"""pytest fixtures: a scratch branch of one seeded database per test.

    def test_signup(gnomon_conn):       # a psycopg connection on a fresh branch
        gnomon_conn.execute("insert into users ...")

Tests run in parallel against one database (pytest-xdist works): each gets its own branch, so
nothing a test writes is seen by another, and nothing reaches main. Configure the database with
``--gnomon-dsn`` or ``GNOMON_TEST_DSN``.
"""
from __future__ import annotations

import os

import pytest

from . import create_scratch, drop_branch, use


def pytest_addoption(parser):
    parser.addoption("--gnomon-dsn", default=os.environ.get("GNOMON_TEST_DSN"), help="database with gnomon (seeded)")
    parser.addoption("--gnomon-keep", action="store_true", help="keep test branches for inspection")
    parser.addoption("--gnomon-update-snapshots", action="store_true", help="record branch snapshots instead of comparing")
    parser.addoption("--gnomon-snapshot-dir", default=None, help="where snapshots live (default: __gnomon_snapshots__ beside the test)")


@pytest.fixture
def gnomon_snapshot(request):
    """Compare the test branch's diff with a stored snapshot: ``gnomon_snapshot.assert_match(gnomon_conn)``."""
    from .testing import Snapshot, snapshot_dir
    return Snapshot(snapshot_dir(request), request.config.getoption("--gnomon-update-snapshots"))


@pytest.fixture(scope="session")
def gnomon_dsn(request):
    dsn = request.config.getoption("--gnomon-dsn")
    if not dsn:
        pytest.skip("set --gnomon-dsn or GNOMON_TEST_DSN")
    return dsn


@pytest.fixture
def gnomon_branch(request, gnomon_dsn):
    import psycopg

    with psycopg.connect(gnomon_dsn, autocommit=True) as admin:
        name = create_scratch(admin, prefix="pytest")
    yield name
    if not request.config.getoption("--gnomon-keep"):
        with psycopg.connect(gnomon_dsn, autocommit=True) as admin:
            drop_branch(admin, name)


@pytest.fixture
def gnomon_conn(gnomon_dsn, gnomon_branch):
    import psycopg

    conn = psycopg.connect(gnomon_dsn, autocommit=True)
    use(conn, gnomon_branch)
    try:
        yield conn
    finally:
        conn.close()
