"""Helpers for apps on a PostgreSQL database with the gnomon extension.

Choosing a branch is plain SQL. In SQL-only mode it takes the setting *and* the routing
search_path, which ``gnomon.use()`` (session) and ``gnomon.begin()`` (one transaction, safe behind
transaction poolers) set together; with the C module loaded, ``SET gnomon.branch`` alone routes.
"""
from __future__ import annotations

import contextlib
import os
import secrets
from typing import Iterator, Optional
from urllib.parse import quote

__all__ = [
    "routing_schema", "branch_options", "connection_options", "branch_dsn", "use", "begin", "create_branch", "create_scratch",
    "drop_branch", "merge", "diff", "branch", "connect",
    # the SDK
    "Gnomon", "AsyncGnomon", "Run", "AsyncRun", "GnomonError",
]


def routing_schema(schema: str = "public", *, scratch: bool = False) -> str:
    """The routing schema of a user schema; scratch branches have their own (``__s``)."""
    return f"gnomon_r_{schema}" + ("__s" if scratch else "")


def branch_options(branch: str, *, c_module: bool = False, schemas: tuple[str, ...] = ("public",),
                   as_of: Optional[str] = None, scratch: bool = False) -> str:
    """The libpq ``options`` value that puts a connection on a branch.
    ``scratch``: the branch is a scratch branch (it is read through the scratch routing schemas)."""
    opts = [f"-c gnomon.branch={branch}"]
    if as_of:
        opts.append(f"-c gnomon.as_of={as_of}")
    if not c_module:
        path = ",".join(p for s in schemas for p in (routing_schema(s, scratch=scratch), s))
        opts.append(f"-c search_path={path}")
    return " ".join(opts)


def connection_options(conn, branch: str, *, c_module: bool = False) -> str:
    """The ``options`` value the database computes for ``branch`` (``gnomon.connection_options``):
    unlike :func:`branch_options`, it knows the branch's kind, a confined role's mask profile and
    the branch's schema version."""
    return conn.execute("select gnomon.connection_options(%s, %s)", (branch, c_module)).fetchone()[0]


def branch_dsn(dsn: str, branch: str, *, options: Optional[str] = None, **kw) -> str:
    """A connection string (URL or key=value) whose sessions start on ``branch``. ``options``: a
    value from :func:`connection_options` instead of the one built here."""
    opts = options or branch_options(branch, **kw)
    if "://" in dsn:
        sep = "&" if "?" in dsn else "?"
        return f"{dsn}{sep}options={quote(opts)}"
    return f"{dsn} options='{opts}'"


def use(conn, branch: str = "main", as_of: Optional[str] = None) -> str:
    """Put a psycopg connection's session on a branch (``main`` resets it)."""
    with conn.cursor() as cur:
        cur.execute("select gnomon.use(%s, %s)", (branch, as_of))
        return cur.fetchone()[0]


def begin(conn, branch: str, as_of: Optional[str] = None) -> None:
    """Put the current transaction on a branch (SET LOCAL semantics, for poolers)."""
    with conn.cursor() as cur:
        cur.execute("select gnomon.begin(%s, %s)", (branch, as_of))


def create_branch(conn, name: str, parent: str = "main", *, scratch: bool = False,
                  at: Optional[str] = None) -> int:
    with conn.cursor() as cur:
        cur.execute("select gnomon.create_branch(%s, %s, %s, %s)", (name, parent, "scratch" if scratch else "logged", at))
        return cur.fetchone()[0]


def create_scratch(conn, prefix: str = "test", parent: str = "main") -> str:
    name = f"{prefix}-{os.getpid():x}-{secrets.token_hex(4)}"
    create_branch(conn, name, parent, scratch=True)
    return name


def drop_branch(conn, name: str, cascade: bool = True) -> None:
    with conn.cursor() as cur:
        cur.execute("select gnomon.drop_branch(%s, %s)", (name, cascade))


def merge(conn, source: str, target: Optional[str] = None) -> dict:
    with conn.cursor() as cur:
        cur.execute("select gnomon.merge(%s, %s)", (source, target))
        mid = cur.fetchone()[0]
        cur.execute("select id, status, stats from gnomon.merge where id = %s", (mid,))
        i, status, stats = cur.fetchone()
        return {"id": i, "status": status, "stats": stats}


def diff(conn, a: str, b: Optional[str] = None) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute("select tbl::text, key, kind, col, old, new from gnomon.diff(%s, %s)", (a, b))
        cols = ["table", "key", "kind", "col", "old", "new"]
        return [dict(zip(cols, r)) for r in cur.fetchall()]


@contextlib.contextmanager
def branch(conn, name: str, as_of: Optional[str] = None) -> Iterator[None]:
    """``with gnomon.branch(conn, "feature"):`` - the session reads and writes the branch inside."""
    use(conn, name, as_of)
    try:
        yield
    finally:
        if not conn.closed:
            if conn.info.transaction_status != 0:  # not idle: leave the caller's transaction alone
                conn.rollback()
            use(conn, "main")


def connect(dsn: str, branch_name: Optional[str] = None, **kw):
    """psycopg.connect, optionally starting on a branch."""
    import psycopg

    conn = psycopg.connect(dsn, **kw)
    if branch_name:
        use(conn, branch_name)
    return conn


# The SDK: runs, review, core. Imported lazily so the helpers above need
# nothing but psycopg.
def __getattr__(name):
    if name in ("Gnomon", "Run", "Request", "Branches"):
        from . import client
        return getattr(client, name)
    if name in ("AsyncGnomon", "AsyncRun", "AsyncRequest", "AsyncBranches"):
        from . import aio
        return getattr(aio, name)
    if name in ("GnomonError",):
        from . import errors
        return getattr(errors, name)
    raise AttributeError(name)
