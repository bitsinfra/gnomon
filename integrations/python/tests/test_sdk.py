"""The SDK: the shared conformance scenarios through the sync and the async
client, the snapshot golden files, the tool descriptions, and a run driven by a scripted model."""
from __future__ import annotations

import asyncio
import contextlib
import re
import json
import os
import subprocess
import sys
from decimal import Decimal
from pathlib import Path

import psycopg
import pytest

from gnomon import errors
from gnomon._util import parse_json, split_sql
from gnomon.aio import AsyncGnomon
from gnomon.client import Gnomon
from gnomon.testing import normalize_diff
from gnomon.tools import TOOL_SPECS, handle_tool_use, mcp_handler, tool_definitions

ROOT = Path(__file__).resolve().parents[3]
SPEC = ROOT / "sdk" / "spec"
HOST = os.environ.get("GNOMON_SDK_HOST", str(ROOT / "build"))
PORT = int(os.environ.get("GNOMON_SDK_PORT", "54329"))


def dsn(user="postgres", db="postgres"):
    return f"host={HOST} port={PORT} user={user} dbname={db}"


class Fixture:
    def __init__(self, name: str, setup: list[str]):
        sfx = f"{os.getpid()}_{name}"[:40]
        self.db, self.app, self.runs = f"sdk_py_{name}"[:60], f"sdkpy_app_{sfx}", f"sdkpy_runs_{sfx}"
        with psycopg.connect(dsn(), autocommit=True) as c:
            c.execute(f"drop database if exists {self.db} with (force)")
            c.execute(f"create database {self.db}")
            for r in (self.app, self.runs):
                c.execute(f"drop role if exists {r}")
                c.execute(f"create role {r} login")
        with psycopg.connect(dsn(db=self.db), autocommit=True) as c:
            c.execute("set client_min_messages = warning; create extension gnomon")
            for s in setup:
                c.execute(s)
            c.execute(f"grant gnomon_runner, gnomon_merger to {self.app}")
            c.execute(f"grant select, insert, update, delete on all tables in schema public to {self.app}")
            c.execute(f"grant usage on all sequences in schema public to {self.app}")
            c.execute(f"select gnomon.confine('{self.runs}', array[]::text[], false)")
            c.execute(f"select gnomon.set('runs_role', '{self.runs}')")
            self.cmod = c.execute("select coalesce(current_setting('gnomon.c_module', true), '') = 'on'").fetchone()[0]

    def cleanup(self):
        with psycopg.connect(dsn(), autocommit=True) as c:
            c.execute(f"drop database if exists {self.db} with (force)")
            for r in (self.app, self.runs):
                c.execute(f"drop role if exists {r}")


def _server():
    try:
        psycopg.connect(dsn(), connect_timeout=2).close()
        return True
    except psycopg.Error:
        return False


needs_server = pytest.mark.skipif(not _server(), reason="no test server (the dev cluster on port 54329)")
SCENARIOS = sorted(SPEC.glob("conformance/*.json"))


def _get(o, path):
    for k in path.split("."):
        o = None if o is None else o.get(k) if isinstance(o, dict) else None
    return o


def _check(where, exp, out):
    if "rowCount" in exp:
        assert out["row_count"] == exp["rowCount"], where
    if "rows" in exp:
        assert [dict(r) for r in out["rows"]] == exp["rows"], where
    if "length" in exp:
        assert len(out) == exp["length"], where
    for k, v in exp.items():
        if "." in k:
            assert _get(out, k) == v, where


def _expect_error(where, exp, e):
    assert exp.get("error"), f"{where}: {e!r}"
    cls = getattr(errors, exp["error"])
    assert isinstance(e, cls), f"{where}: expected {exp['error']}, got {type(e).__name__}: {e}"


@needs_server
@pytest.mark.parametrize("path", SCENARIOS, ids=lambda p: p.stem)
def test_conformance_sync(path):
    sc = json.loads(path.read_text())
    fx = Fixture("s_" + path.stem, sc["setup"])
    try:
        g = Gnomon(app=dsn(fx.app, fx.db), runs=dsn(fx.runs, fx.db))
        runs = {}
        for i, st in enumerate(sc["steps"]):
            where = f"{path.name} step {i + 1} ({st['call']})"
            exp, run = st.get("expect", {}), runs.get(st.get("on", "default"))
            if exp.get("sqlOnly") and fx.cmod:
                continue
            try:
                c = st["call"]
                if c == "startRun":
                    runs[st.get("as", "default")] = g.start_run(st["args"].get("task"), actor=st["args"].get("actor"))
                    continue
                out = {"run.sql": lambda: run.sql(st["args"]["statement"], timeout_ms=(st.get("options") or {}).get("timeoutMs")),
                       "app.sql": lambda: {"rows": g.query(st["args"]["statement"])},
                       "run.diff": lambda: run.diff(), "run.summary": lambda: run.summary(),
                       "run.merge": lambda: run.merge(), "run.discard": lambda: run.discard()}[c]()
            except errors.GnomonError as e:
                _expect_error(where, exp, e)
                continue
            assert not exp.get("error"), f"{where}: expected {exp.get('error')}"
            _check(where, exp, out)
    finally:
        fx.cleanup()


@needs_server
@pytest.mark.parametrize("path", SCENARIOS, ids=lambda p: p.stem)
def test_conformance_async(path):
    sc = json.loads(path.read_text())
    fx = Fixture("a_" + path.stem, sc["setup"])

    async def go():
        g = AsyncGnomon(app=dsn(fx.app, fx.db), runs=dsn(fx.runs, fx.db))
        runs = {}
        for i, st in enumerate(sc["steps"]):
            where = f"{path.name} step {i + 1} ({st['call']})"
            exp, run = st.get("expect", {}), runs.get(st.get("on", "default"))
            if exp.get("sqlOnly") and fx.cmod:
                continue
            try:
                c = st["call"]
                if c == "startRun":
                    runs[st.get("as", "default")] = await g.start_run(st["args"].get("task"), actor=st["args"].get("actor"))
                    continue
                if c == "run.sql":
                    out = await run.sql(st["args"]["statement"], timeout_ms=(st.get("options") or {}).get("timeoutMs"))
                elif c == "app.sql":
                    out = {"rows": await g.query(st["args"]["statement"])}
                else:
                    out = await getattr(run, c.split(".")[1])()
            except errors.GnomonError as e:
                _expect_error(where, exp, e)
                continue
            assert not exp.get("error"), f"{where}: expected {exp.get('error')}"
            _check(where, exp, out)
    try:
        asyncio.run(go())
    finally:
        fx.cleanup()


class _FakeRecord:
    """asyncpg's Record: by name and by position."""

    def __init__(self, names, values):
        self._n, self._v = names, values

    def keys(self):
        return self._n

    def __getitem__(self, k):
        return self._v[k] if isinstance(k, int) else self._v[self._n.index(k)]

    def __iter__(self):
        return iter(self._v)


class _FakePgError(Exception):
    def __init__(self, e):
        super().__init__(str(e))
        self.sqlstate, self.message = e.sqlstate, e.diag.message_primary
        self.hint, self.detail = e.diag.message_hint, e.diag.message_detail


class _FakeAsyncpgConn:
    """The part of asyncpg's Connection the gnomon.asyncpg source uses, over psycopg (asyncpg is
    not a dependency): prepare/fetch/get_attributes/get_statusmsg, transaction, is_in_transaction."""

    def __init__(self, conn):
        self.c = conn

    def is_in_transaction(self):
        return self.c.info.transaction_status != psycopg.pq.TransactionStatus.IDLE

    def transaction(self):
        return self.c.transaction()

    async def prepare(self, q):
        c, order = self.c, [int(x) - 1 for x in re.findall(r"\$(\d+)", q)]
        pq = re.sub(r"\$\d+", "%s", q.replace("%", "%%")) if order else q

        class PS:
            async def fetch(self, *args):
                try:
                    async with c.cursor() as cur:
                        await cur.execute(pq, [args[i] for i in order] if order else None, prepare=False)
                        self.attrs = [type("A", (), {"name": d.name})() for d in (cur.description or [])]
                        self.status = cur.statusmessage
                        rows = await cur.fetchall() if cur.description else []
                except psycopg.Error as e:
                    raise _FakePgError(e) from e
                return [_FakeRecord([a.name for a in self.attrs], list(r)) for r in rows]

            def get_attributes(self):
                return self.attrs

            def get_statusmsg(self):
                return self.status
        return PS()


class _FakeAsyncpgPool:
    def __init__(self, conninfo):
        self.conninfo = conninfo

    @contextlib.asynccontextmanager
    async def acquire(self):
        c = await psycopg.AsyncConnection.connect(self.conninfo, autocommit=True)
        try:
            yield _FakeAsyncpgConn(c)
        finally:
            await c.close()


def test_asyncpg_placeholders():
    from gnomon.asyncpg import to_dollar
    assert to_dollar("select %s, '%s', \"%s\", $$%s$$, %s -- %s\n") == "select $1, '%s', \"%s\", $$%s$$, $2 -- %s\n"
    assert to_dollar("select 100%% and %s /* %s */") == "select 100% and $1 /* %s */"


@needs_server
@pytest.mark.parametrize("path", SCENARIOS, ids=lambda p: p.stem)
def test_conformance_asyncpg(path):
    """The conformance scenarios through the asyncpg source (an asyncpg-shaped connection here)."""
    from gnomon.asyncpg import asyncpg_source
    sc = json.loads(path.read_text())
    fx = Fixture("p_" + path.stem, sc["setup"])

    async def go():
        g = AsyncGnomon(app=asyncpg_source(_FakeAsyncpgPool(dsn(fx.app, fx.db))), runs=asyncpg_source(_FakeAsyncpgPool(dsn(fx.runs, fx.db))))
        runs = {}
        for i, st in enumerate(sc["steps"]):
            where = f"{path.name} step {i + 1} ({st['call']})"
            exp, run = st.get("expect", {}), runs.get(st.get("on", "default"))
            if exp.get("sqlOnly") and fx.cmod:
                continue
            try:
                c = st["call"]
                if c == "startRun":
                    runs[st.get("as", "default")] = await g.start_run(st["args"].get("task"), actor=st["args"].get("actor"))
                    continue
                if c == "run.sql":
                    out = await run.sql(st["args"]["statement"], timeout_ms=(st.get("options") or {}).get("timeoutMs"))
                elif c == "app.sql":
                    out = {"rows": await g.query(st["args"]["statement"])}
                else:
                    out = await getattr(run, c.split(".")[1])()
            except errors.GnomonError as e:
                _expect_error(where, exp, e)
                continue
            assert not exp.get("error"), f"{where}: expected {exp.get('error')}"
            _check(where, exp, out)
    try:
        asyncio.run(go())
    finally:
        fx.cleanup()


@needs_server
@pytest.mark.parametrize("path", SCENARIOS, ids=lambda p: p.stem)
def test_conformance_asyncpg_real(path):
    """The same scenarios through real asyncpg pools (skipped when asyncpg is not installed)."""
    asyncpg = pytest.importorskip("asyncpg")
    from gnomon.asyncpg import asyncpg_source
    sc = json.loads(path.read_text())
    fx = Fixture("r_" + path.stem, sc["setup"])

    async def go():
        pools = [await asyncpg.create_pool(host=HOST, port=PORT, user=u, database=fx.db, min_size=1, max_size=2) for u in (fx.app, fx.runs)]
        try:
            g = AsyncGnomon(app=asyncpg_source(pools[0]), runs=asyncpg_source(pools[1]))
            runs = {}
            for i, st in enumerate(sc["steps"]):
                where = f"{path.name} step {i + 1} ({st['call']})"
                exp, run = st.get("expect", {}), runs.get(st.get("on", "default"))
                if exp.get("sqlOnly") and fx.cmod:
                    continue
                try:
                    c = st["call"]
                    if c == "startRun":
                        runs[st.get("as", "default")] = await g.start_run(st["args"].get("task"), actor=st["args"].get("actor"))
                        continue
                    if c == "run.sql":
                        out = await run.sql(st["args"]["statement"], timeout_ms=(st.get("options") or {}).get("timeoutMs"))
                    elif c == "app.sql":
                        out = {"rows": await g.query(st["args"]["statement"])}
                    else:
                        out = await getattr(run, c.split(".")[1])()
                except errors.GnomonError as e:
                    _expect_error(where, exp, e)
                    continue
                assert not exp.get("error"), f"{where}: expected {exp.get('error')}"
                _check(where, exp, out)
        finally:
            for p in pools:
                await p.close()
    try:
        asyncio.run(go())
    finally:
        fx.cleanup()


def test_snapshot_golden_files():
    for f in sorted(SPEC.glob("snapshot/*.json")):
        g = json.loads(f.read_text())
        assert normalize_diff(g["diff"], ignore=g["ignore"], foreign_keys=g["foreign_keys"]) == g["expected"], f.name


def test_tool_descriptions_are_the_specification():
    assert TOOL_SPECS == json.loads((SPEC / "tools.json").read_text())["tools"]


def test_anthropic_tools_carry_the_input_schemas(monkeypatch):
    # beta_tool infers a schema from the function's signature, and the tools' functions take
    # **kw: without the specification's schemas the model would see tools without parameters
    import types
    from gnomon.tools import anthropic_tools
    fake = types.ModuleType("anthropic")
    fake.beta_tool = lambda fn, **kw: {"fn": fn, **kw}
    monkeypatch.setitem(sys.modules, "anthropic", fake)
    tools = anthropic_tools(object())
    assert [t["name"] for t in tools] == [f"gnomon_{t['name']}" for t in TOOL_SPECS]
    assert [t["description"] for t in tools] == [t["description"] for t in TOOL_SPECS]
    assert [t["input_schema"] for t in tools] == [t["input"] for t in TOOL_SPECS]


def test_sync_client_is_generated():
    r = subprocess.run([sys.executable, str(ROOT / "tools/unasync.py"), "--check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_values_and_statements():
    v = parse_json('{"a": 9007199254740993, "b": 1.50, "c": 2}')
    assert v["a"] == 9007199254740993 and v["b"] == Decimal("1.50") and v["c"] == 2
    assert len(split_sql("select ';'; -- x")) == 1
    assert len(split_sql("select $$a;b$$; select 2")) == 2


@needs_server
def test_run_with_scripted_model():
    fx = Fixture("e2e", [
        "create table customers (id int generated by default as identity primary key, email text not null)",
        "create table orders (id int generated by default as identity primary key, customer int not null references customers(id), total numeric not null)",
        "create index on orders (customer)",
        "insert into customers (email) values ('a@x.io')",
        "insert into orders (customer, total) values (1, 10.50)",
        "select gnomon.track('customers')", "select gnomon.track('orders')",
    ])
    try:
        events = []
        g = Gnomon(app=dsn(fx.app, fx.db), runs=dsn(fx.runs, fx.db), on_statement=events.append)
        with g.start_run("add an order", actor="scripted") as run:
            defs = tool_definitions()
            assert {d["name"] for d in defs} >= {"gnomon_sql", "gnomon_done"}
            script = [("gnomon_checkpoint", {"name": "start"}),
                      ("gnomon_sql", {"statement": "insert into customers (email) values ('b@x.io')", "reason": "new customer"}),
                      ("gnomon_sql", {"statement": "insert into orders (customer, total) select max(id), 5.25 from customers"}),
                      ("gnomon_sql", {"statement": "update orders set total = total + 1 where id = 1; delete from orders"})]
            res = [handle_tool_use(run, {"id": f"t{i}", "name": n, "input": a}) for i, (n, a) in enumerate(script)]
            assert not res[1]["is_error"] and not res[2]["is_error"]
            assert res[3]["is_error"], "two statements in one call are refused"
            d = run.diff()
            assert any(x["table"] == "orders" and x["new"]["total"] == Decimal("5.25") for x in d), d
            blame = g.blame("customers", {"id": 2}, branch=run.branch)
            assert {b["actor"] for b in blame} == {"scripted"} and "new customer" in {b["reason"] for b in blame}
            h = mcp_handler(run)({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
            assert len(h["result"]["tools"]) == 7
            handle_tool_use(run, {"id": "rw", "name": "gnomon_rewind", "input": {"name": "start"}})
            assert run.diff() == []
            if not fx.cmod:   # (with the C module a qualified name is routed to the branch)
                with pytest.raises(errors.PermissionError):
                    run.sql("update public.orders set total = 0")
        # leaving the scope discarded it
        assert g.value("select count(*) from gnomon.branch where name like 'run-%%' and status = 'open'") == 0
        # a connection pinned to a run: a login of the run's own, gone with the run
        with g.start_run("a tool with its own connection", actor="tool") as run3:
            with run3.connection() as tc:
                tc.execute("update orders set total = 77 where id = 1")
                tc.commit()
                assert tc.execute("select total from orders where id = 1").fetchone()[0] == 77
            assert len(run3.diff()) == 1
            assert g.value("select total from orders where id = 1") != 77
            login = g.value("select login from gnomon.run r join gnomon.branch b on b.id = r.branch where b.name = %s", (run3.branch,))
        assert g.value("select count(*) from pg_roles where rolname = %s", (login,)) == 0
        # review: a request, its status, merge
        run2 = g.start_run("rename", actor="bot")
        run2.sql("update customers set email = 'A@x.io' where id = 1")
        req = run2.submit("fix the case")
        assert req.status()["title"] == "fix the case"
        with pytest.raises(errors.PermissionError):
            req.approve()  # the login that opened it cannot approve it
        reviewer = Gnomon(app=dsn("postgres", fx.db))
        reviewer.requests.get(req.id).approve("ok")
        req.merge()
        assert g.value("select email from customers where id = 1") == "A@x.io"
        assert any(e["login"] == "runs" and e["ok"] for e in events)
    finally:
        fx.cleanup()
