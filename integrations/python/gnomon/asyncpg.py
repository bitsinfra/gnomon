"""asyncpg for the async SDK.

    import asyncpg
    from gnomon import AsyncGnomon
    from gnomon.asyncpg import asyncpg_source

    app = await asyncpg.create_pool("postgresql://app@db/shop")
    runs = await asyncpg.create_pool("postgresql://runs@db/shop")
    gn = AsyncGnomon(app=asyncpg_source(app), runs=asyncpg_source(runs))

The SDK speaks psycopg's interface; this hands it connections from an asyncpg pool (or a single
asyncpg connection) that answer the part of it the SDK uses: ``%s`` placeholders become ``$n``,
rows come back as dicts (or tuples), row counts come from the command status, and PostgreSQL's
errors come back as psycopg errors carrying the SQLSTATE and hint, so they map to the SDK's typed
errors. A statement outside a transaction runs in one of its own, so behind a transaction pooler
(pgbouncer) its prepare and execute stay on one server connection.
"""
from __future__ import annotations

import asyncio
import contextlib
import re
from typing import Any, AsyncIterator, Optional

import psycopg


def to_dollar(sql: str) -> str:
    """psycopg's placeholders (%s, %% for a percent sign) as PostgreSQL's ($1, $2, ...), leaving
    quoted strings, identifiers, dollar-quoted bodies and comments alone."""
    out, i, n, k = [], 0, len(sql), 0
    while i < n:
        c = sql[i]
        if c in "'\"":
            j = i + 1
            while j < n:
                if sql[j] == c:
                    if j + 1 < n and sql[j + 1] == c:
                        j += 2
                        continue
                    break
                j += 1
            out.append(sql[i:j + 1])
            i = j + 1
        elif c == "$" and (m := re.match(r"\$([A-Za-z_][A-Za-z_0-9]*)?\$", sql[i:])):
            tag = m.group(0)
            j = sql.find(tag, i + len(tag))
            j = n if j < 0 else j + len(tag)
            out.append(sql[i:j])
            i = j
        elif sql.startswith("--", i):
            j = sql.find("\n", i)
            j = n if j < 0 else j
            out.append(sql[i:j])
            i = j
        elif sql.startswith("/*", i):
            j = sql.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(sql[i:j])
            i = j
        elif sql.startswith("%s", i):
            k += 1
            out.append(f"${k}")
            i += 2
        elif sql.startswith("%%", i):
            out.append("%")
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


class _Diag:
    def __init__(self, e: BaseException):
        self.message_primary = getattr(e, "message", None) or str(e)
        self.message_detail = getattr(e, "detail", None)
        self.message_hint = getattr(e, "hint", None)
        self.sqlstate = getattr(e, "sqlstate", None)


class AsyncpgError(psycopg.Error):
    """An asyncpg PostgreSQL error, as the SDK reads psycopg's."""

    def __init__(self, e: BaseException):
        self.cause = e  # (first: psycopg's constructor reads sqlstate)
        super().__init__(getattr(e, "message", None) or str(e))

    @property
    def sqlstate(self) -> Optional[str]:  # type: ignore[override]
        return getattr(self.cause, "sqlstate", None)

    @property
    def diag(self) -> _Diag:  # type: ignore[override]
        return _Diag(self.cause)


class _Cursor:
    def __init__(self, conn: Any, dicts: bool):
        self.conn, self.dicts = conn, dicts
        self.description: Optional[list[str]] = None
        self.rowcount = -1
        self.statusmessage: Optional[str] = None
        self._rows: list = []

    async def __aenter__(self) -> "_Cursor":
        return self

    async def __aexit__(self, *exc) -> bool:
        return False

    async def execute(self, sql: str, params: Any = None, prepare: Any = None) -> None:
        q = to_dollar(sql) if params else sql
        args = list(params or ())

        async def run():
            ps = await self.conn.prepare(q)
            return ps, await ps.fetch(*args)

        try:
            if self.conn.is_in_transaction():
                ps, rows = await run()
            else:
                async with self.conn.transaction():
                    ps, rows = await run()
        except Exception as e:  # asyncpg.PostgresError carries sqlstate
            if getattr(e, "sqlstate", None):
                raise AsyncpgError(e) from e
            raise
        attrs = list(ps.get_attributes())
        self.description = [a.name for a in attrs] or None
        self._rows = [dict(r) if self.dicts else tuple(r) for r in rows] if attrs else []
        self.statusmessage = ps.get_statusmsg()
        m = re.search(r"(\d+)\s*$", self.statusmessage or "")
        self.rowcount = int(m.group(1)) if m else len(self._rows)

    async def fetchall(self) -> list:
        return self._rows

    async def fetchone(self) -> Any:
        return self._rows[0] if self._rows else None


class _Conn:
    def __init__(self, conn: Any):
        self._c = conn

    def transaction(self):
        return self._c.transaction()

    def cursor(self, row_factory: Any = None) -> _Cursor:
        return _Cursor(self._c, row_factory is not None)


class asyncpg_source:
    """A login for AsyncGnomon from an asyncpg pool (a connection per call) or one asyncpg
    connection (used one call at a time)."""

    def __init__(self, source: Any):
        self.source = source
        self.lock = asyncio.Lock()

    @contextlib.asynccontextmanager
    async def connection(self) -> AsyncIterator[_Conn]:
        s = self.source
        if hasattr(s, "acquire"):
            async with s.acquire() as c:
                yield _Conn(c)
        else:
            async with self.lock:
                yield _Conn(s)
