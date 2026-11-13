import os
import pathlib

import psycopg
import pytest

ROOT = pathlib.Path(__file__).resolve().parents[3]
SERVER = os.environ.get("GNOMON_TEST_SERVER", f"host={ROOT / 'build'} port=54329 user=postgres")
DB = "py_gnomon_test"


def pytest_configure(config):
    # one seeded database for the whole session; every test branches it
    with psycopg.connect(SERVER + " dbname=postgres", autocommit=True) as c:
        c.execute(f"drop database if exists {DB} with (force)")
        c.execute(f"create database {DB}")
    dsn = f"{SERVER} dbname={DB}"
    with psycopg.connect(dsn, autocommit=True) as c:
        c.execute("set client_min_messages = warning")
        c.execute("create extension gnomon")
        c.execute("create table account (id int primary key, name text not null, balance int not null default 0)")
        c.execute("insert into account select g, 'acct ' || g, 100 from generate_series(1, 10) g")
        c.execute("select gnomon.track('account')")
    config.option.gnomon_dsn = dsn
    os.environ["GNOMON_TEST_DSN"] = dsn


def pytest_unconfigure(config):
    with psycopg.connect(SERVER + " dbname=postgres", autocommit=True) as c:
        c.execute(f"drop database if exists {DB} with (force)")
