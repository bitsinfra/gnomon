"""The gnomon SDK, async (the specification is sdk/spec/SPEC.md).

``client.py`` is generated from this file by ``tools/unasync.py``: change this one.

    gn = AsyncGnomon(app="postgresql://app@db/app", runs="postgresql://runs@db/app")
    async with await gn.start_run("Refund order 3", actor="support-bot") as run:
        await run.sql("update orders set status = 'refunded' where id = 3")
        summary = await run.summary()
        if summary["checks"]["passed"] and summary["changes"]["rows"] <= 20:
            await run.merge()
        else:
            await run.submit("Refund order 3")
"""
from __future__ import annotations

import asyncio
import contextlib
import json
from typing import Any, AsyncIterator, Callable, Optional

import psycopg
import psycopg.conninfo
from psycopg.rows import dict_row

from ._util import parse_json, split_sql
from .errors import (GnomonError, IncompatibleVersionError, MergeConflictError, SerializationError,
                     to_gnomon_error)

SUPPORTED_API = (2, 2)


class AsyncAdapter:
    """A login: a connection string (a connection per call), a psycopg connection (used one call
    at a time), or a pool with a ``connection()`` context manager (psycopg_pool)."""

    def __init__(self, source: Any):
        self.source = source
        self.lock = asyncio.Lock()

    @contextlib.asynccontextmanager
    async def connection(self) -> AsyncIterator[psycopg.AsyncConnection]:
        s = self.source
        if isinstance(s, str):
            conn = await psycopg.AsyncConnection.connect(s, autocommit=True)
            try:
                yield conn
            finally:
                await conn.close()
        elif hasattr(s, "connection") and not isinstance(s, psycopg.AsyncConnection):
            async with s.connection() as conn:
                yield conn
        else:
            async with self.lock:
                yield s

    async def query(self, sql: str, params: tuple = ()) -> list[dict]:
        async with self.connection() as conn:
            async with conn.cursor(row_factory=dict_row) as cur:
                await cur.execute(sql, params)
                return await cur.fetchall() if cur.description else []


class AsyncGnomon:
    """The application's side: starts runs, reads them, accepts them; review; core."""

    def __init__(self, app: Any, runs: Any = None, *, statement_timeout_ms: int = 30000, lock_timeout_ms: int = 5000,
                 max_rows: int = 1000, on_statement: Optional[Callable[[dict], None]] = None, skip_version_check: bool = False,
                 url: Optional[str] = None):
        # url: the database's connection string (host, port, database), for run.url() and
        # run.connection(); default: the app login's, when it is a string
        self.url = url or (app if isinstance(app, str) else None)
        self.app = AsyncAdapter(app)
        self.runs = AsyncAdapter(runs) if runs is not None else None
        self.statement_timeout_ms, self.lock_timeout_ms, self.max_rows = statement_timeout_ms, lock_timeout_ms, max_rows
        self.on_statement = on_statement
        self._checked = skip_version_check
        self.requests = AsyncRequests(self)
        self.branches = AsyncBranches(self)

    async def ready(self) -> None:
        """Check once that the extension speaks this SDK's API."""
        if self._checked:
            return
        try:
            rows = await self.app.query("select gnomon.api_version() as v")
        except psycopg.Error as e:
            raise IncompatibleVersionError("this server's gnomon has no gnomon.api_version(): it predates this SDK (needs API 2)", cause=e)
        v = rows[0]["v"]
        if not SUPPORTED_API[0] <= v <= SUPPORTED_API[1]:
            raise IncompatibleVersionError(f"gnomon API {v} on the server; this SDK speaks {SUPPORTED_API[0]}..{SUPPORTED_API[1]}")
        self._checked = True

    def _event(self, login: str, run: Optional[str], sql: str, ok: bool, error: Optional[GnomonError] = None) -> None:
        if self.on_statement:
            self.on_statement({"login": login, "run": run, "statement": sql, "ok": ok, "error": error})

    async def query(self, sql: str, params: tuple = ()) -> list[dict]:
        """A statement on the app login, errors typed."""
        await self.ready()
        try:
            rows = await self.app.query(sql, params)
        except psycopg.Error as e:
            ge = to_gnomon_error(e)
            self._event("app", None, sql, False, ge)
            raise ge from e
        self._event("app", None, sql, True)
        return rows

    async def value(self, sql: str, params: tuple = ()) -> Any:
        rows = await self.query(sql, params)
        return next(iter(rows[0].values())) if rows else None

    async def json(self, sql: str, params: tuple = ()) -> Any:
        return parse_json(await self.value(f"select ({sql})::text", params))

    async def start_run(self, task: Optional[str] = None, *, actor: Optional[str] = None, kind: str = "logged",
                        ttl: Optional[str] = None, parent: str = "main") -> "AsyncRun":
        if self.runs is None:
            raise GnomonError("start_run needs the runs login: AsyncGnomon(app=..., runs=...)")
        branch = await self.value("select gnomon.run_start(%s, %s, %s, %s::interval, %s)", (task, actor, kind, ttl, parent))
        return AsyncRun(self, branch, task=task, actor=actor)

    def run(self, branch: str, *, task: Optional[str] = None, actor: Optional[str] = None) -> "AsyncRun":
        return AsyncRun(self, branch, task=task, actor=actor)

    # ---- core
    async def status(self) -> dict:
        return await self.json("select gnomon.status()")

    async def doctor(self) -> list[dict]:
        return await self.query("select check_name, status, detail from gnomon.doctor()")

    async def describe(self, schema: Optional[str] = None) -> dict:
        return await self.json("select gnomon.describe(%s)", (schema,))

    async def diff(self, a: str, b: Optional[str] = None) -> list[dict]:
        rows = await self.query("select tbl::text as table, key::text as key, kind, col as column, old::text as old, new::text as new from gnomon.diff(%s, %s)", (a, b))
        return [{**r, "key": parse_json(r["key"]), "old": parse_json(r["old"]), "new": parse_json(r["new"])} for r in rows]

    async def history(self, table: str, key: Any, *, branch: str = "main") -> list[dict]:
        rows = await self.query("select vkey, xid::text as xid, role, op, at, actor, reason, row_image::text as row_image, on_branch from gnomon.history(%s, %s::jsonb, %s)",
                                (table, json.dumps(key), branch))
        return [{**r, "row_image": parse_json(r["row_image"])} for r in rows]

    async def blame(self, table: str, key: Any, *, branch: str = "main") -> list[dict]:
        rows = await self.query("select col, value::text as value, xid::text as xid, role, actor, reason, at, on_branch from gnomon.blame(%s, %s::jsonb, %s)",
                                (table, json.dumps(key), branch))
        return [{**r, "value": parse_json(r["value"])} for r in rows]

    async def revert(self, table: str, at: str, *, keys: Optional[list] = None, filter: Optional[str] = None,
                     columns: Optional[list] = None, branch: str = "main", dry_run: bool = False) -> dict:
        return await self.json("select gnomon.revert(%s, %s, %s::jsonb, %s, %s::text[], %s, %s)",
                               (table, at, json.dumps(keys) if keys is not None else None, filter, columns, branch, dry_run))


class AsyncRun:
    """One agent run: a branch, its envelope, and what the application does with it."""

    def __init__(self, gnomon: AsyncGnomon, branch: str, *, task: Optional[str] = None, actor: Optional[str] = None):
        self.gnomon, self.branch, self.task, self.actor = gnomon, branch, task, actor
        self.state = "open"
        self._seq = 0

    async def __aenter__(self) -> "AsyncRun":
        return self

    async def __aexit__(self, *exc) -> None:
        if self.state == "open":
            await self.discard()

    def _check_open(self) -> None:
        if self.state != "open":
            raise GnomonError(f"run {self.branch} is {self.state}", code="branch_closed")

    async def _envelope(self, cur, reason: Optional[str], timeout_ms: Optional[int]) -> None:
        g = self.gnomon
        self._seq += 1
        await cur.execute("select gnomon.begin(%s)", (self.branch,))
        await cur.execute("select gnomon.note(%s, %s, %s::jsonb)", (self.actor or "agent", reason,
                                                                       json.dumps({"run": self.branch, "call": self._seq, "task": self.task})))
        await cur.execute("select set_config('statement_timeout', %s, true), set_config('lock_timeout', %s, true)",
                          (str(timeout_ms or g.statement_timeout_ms), str(g.lock_timeout_ms)))

    async def sql(self, statement: str, params: tuple = (), *, reason: Optional[str] = None, timeout_ms: Optional[int] = None,
                  max_rows: Optional[int] = None) -> dict:
        """One statement on the run (the envelope). Rows past the cap: ``truncated``. Retried on a
        serialization failure (the envelope held nothing else)."""
        self._check_open()
        g = self.gnomon
        await g.ready()
        if len(split_sql(statement)) > 1:
            raise GnomonError("one statement per call: this one holds several (split it, or use transaction())", code="one_statement", sqlstate="42601")
        cap = max_rows or g.max_rows
        for attempt in range(4):
            try:
                async with g.runs.connection() as conn:
                    async with conn.transaction():
                        async with conn.cursor(row_factory=dict_row) as cur:
                            await self._envelope(cur, reason, timeout_ms)
                            # (the extended protocol: psycopg sends parameters, so PostgreSQL refuses a second statement)
                            await cur.execute(statement, params or None, prepare=False)
                            rows = await cur.fetchall() if cur.description else []
                            rowcount = cur.rowcount
                g._event("runs", self.branch, statement, True)
                return {"rows": rows[:cap], "row_count": rowcount, "truncated": len(rows) > cap}
            except psycopg.Error as e:
                ge = to_gnomon_error(e)
                g._event("runs", self.branch, statement, False, ge)
                if isinstance(ge, SerializationError) and attempt < 3:
                    await asyncio.sleep(0.02 * 2 ** attempt)
                    continue
                raise ge from e

    @contextlib.asynccontextmanager
    async def transaction(self, *, reason: Optional[str] = None, timeout_ms: Optional[int] = None) -> AsyncIterator[Any]:
        """Several statements in one envelope: ``async with run.transaction() as tx: await tx.execute(...)``."""
        self._check_open()
        g = self.gnomon
        await g.ready()
        try:
            async with g.runs.connection() as conn:
                async with conn.transaction():
                    async with conn.cursor(row_factory=dict_row) as cur:
                        await self._envelope(cur, reason, timeout_ms)
                        yield cur
        except psycopg.Error as e:
            raise to_gnomon_error(e) from e

    async def diff(self) -> list[dict]:
        return await self.gnomon.diff(self.branch)

    async def summary(self, *, run_checks: bool = True) -> dict:
        return await self.gnomon.json("select gnomon.run_summary(%s, %s)", (self.branch, run_checks))

    async def checks(self) -> list[dict]:
        return await self.gnomon.query("select check_name, passed, detail from gnomon.run_checks(%s)", (self.branch,))

    async def merge(self, *, close: bool = True) -> dict:
        g = self.gnomon
        mid = await g.value("select gnomon.merge(%s, null, 'atomic', null, null, null, %s)", (self.branch, close))
        m = await g.json("select to_jsonb(m) from gnomon.merge m where id = %s", (mid,))
        if m["status"] == "conflicts":
            c = await g.json("select coalesce(jsonb_agg(to_jsonb(c)), '[]') from gnomon.conflict c where merge_id = %s", (mid,))
            raise MergeConflictError(f"merging run {self.branch} stopped on {len(c)} conflict(s)", mid, c)
        self.state = "merged"
        return {"merge": mid, "status": m["status"], "stats": m["stats"]}

    async def submit(self, title: Optional[str] = None, body: Optional[str] = None) -> "AsyncRequest":
        cr = await self.gnomon.value("select gnomon.open_change_request(%s, %s, %s)",
                                     (self.branch, title or self.task or f"Run {self.branch}", body))
        self.state = "submitted"
        return AsyncRequest(self.gnomon, cr)

    async def discard(self) -> None:
        if self.state == "discarded":
            return
        await self.gnomon.query("select gnomon.run_end(%s, false)", (self.branch,))
        self.state = "discarded"

    async def url(self, base: Optional[str] = None) -> str:
        """A connection string pinned to the run, for a tool that wants one: a login of the run's own
        (gnomon.run_login), confined to the run's branch, dropped when the run ends."""
        self._check_open()
        b = base or self.gnomon.url
        if not b:
            raise GnomonError("run.url() needs a base connection string (the url option, or an argument)", code="run_url_base")
        login = await self.gnomon.json("select gnomon.run_login(%s)", (self.branch,))
        return psycopg.conninfo.make_conninfo(b, user=login["role"], password=login["password"])

    async def connection(self, base: Optional[str] = None) -> psycopg.AsyncConnection:
        """A connection pinned to the run (close it when done)."""
        return await psycopg.AsyncConnection.connect(await self.url(base))

    async def checkpoint(self, name: str) -> str:
        return await self.gnomon.value("select gnomon.checkpoint(%s, %s)", (f"{self.branch}:{name}", self.branch))

    async def rewind(self, name: str) -> dict:
        return await self.gnomon.json("select gnomon.rewind(%s, %s)", (self.branch, f"{self.branch}:{name}"))

    async def dry_run(self, statements: list[str], *, checks: bool = True) -> dict:
        return await self.gnomon.json("select gnomon.dry_run(%s::text[], %s, %s)", (statements, self.branch, checks))

    async def describe(self, schema: Optional[str] = None) -> dict:
        async with self.gnomon.runs.connection() as conn:
            async with conn.transaction():
                async with conn.cursor() as cur:
                    await cur.execute("select gnomon.begin(%s)", (self.branch,))
                    await cur.execute("select gnomon.describe(%s)::text", (schema,))
                    return parse_json((await cur.fetchone())[0])


class AsyncRequests:
    def __init__(self, g: AsyncGnomon):
        self.gnomon = g

    async def open(self) -> list["AsyncRequest"]:
        rows = await self.gnomon.query("select id from gnomon.change_request where status in ('open', 'approved') order by id")
        return [AsyncRequest(self.gnomon, r["id"]) for r in rows]

    def get(self, id: int) -> "AsyncRequest":
        return AsyncRequest(self.gnomon, id)


class AsyncRequest:
    """A change request: what a product's own Approve, Reject and Undo buttons call."""

    def __init__(self, g: AsyncGnomon, id: int):
        self.gnomon, self.id = g, id

    async def status(self) -> dict:
        return await self.gnomon.json("select gnomon.change_request_status(%s)", (self.id,))

    async def diff(self) -> list[dict]:
        return await self.gnomon.diff((await self.status())["branch"])

    async def approve(self, body: Optional[str] = None) -> None:
        await self.gnomon.query("select gnomon.review(%s, 'approve', %s)", (self.id, body))

    async def reject(self, note: Optional[str] = None) -> None:
        await self.gnomon.query("select gnomon.review(%s, 'reject', %s)", (self.id, note))

    async def comment(self, body: str, *, table: Optional[str] = None, key: Any = None, column: Optional[str] = None) -> int:
        return await self.gnomon.value("select gnomon.comment(%s, %s, %s::regclass, %s::jsonb, %s)",
                                       (self.id, body, table, json.dumps(key) if key is not None else None, column))

    async def merge(self, *, close: bool = True) -> int:
        return await self.gnomon.value("select gnomon.merge(%s, null, 'atomic', null, null, null, %s)", ((await self.status())["branch"], close))

    async def undo(self) -> dict:
        s = await self.status()
        if not s.get("merge"):
            raise GnomonError(f"change request {self.id} is not merged")
        return await self.gnomon.json("select gnomon.undo_merge(%s)", (s["merge"]["id"],))

    async def wait(self, timeout_s: float = 300) -> dict:
        return await self.gnomon.json("select gnomon.wait_for_review(%s, %s::interval)", (self.id, f"{timeout_s} seconds"))


class AsyncBranches:
    def __init__(self, g: AsyncGnomon):
        self.gnomon = g

    async def create(self, name: str, *, parent: str = "main", kind: str = "logged", at: Optional[str] = None) -> str:
        await self.gnomon.query("select gnomon.create_branch(%s, %s, %s, %s)", (name, parent, kind, at))
        return name

    async def scratch(self, prefix: str = "test", parent: str = "main") -> str:
        return await self.gnomon.value("select gnomon.create_scratch(%s, %s)", (prefix, parent))

    async def drop(self, name: str) -> None:
        await self.gnomon.query("select gnomon.drop_branch(%s, true)", (name,))

    async def rebase(self, name: str, *, dry_run: bool = False) -> dict:
        return await self.gnomon.json("select gnomon.rebase(%s, null, %s)", (name, dry_run))

    async def list(self) -> list[dict]:
        return await self.gnomon.query("select * from gnomon.branches order by created_at")

    async def options(self, name: str, *, c_module: bool = False) -> str:
        return await self.gnomon.value("select gnomon.connection_options(%s, %s)", (name, c_module))
