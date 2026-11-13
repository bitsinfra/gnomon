"""SQLAlchemy integration.

``branch_engine(url, "feature")`` returns an engine whose connections start on a branch.
``attach_branch(engine, lambda: current_branch)`` puts every transaction on whatever branch the
callable returns (``None`` or ``"main"`` for main), using gnomon.begin(), which is safe behind
transaction poolers.
"""
from __future__ import annotations

from typing import Callable, Optional

from sqlalchemy import create_engine, event, text

from . import branch_options


def branch_engine(url: str, branch: str, *, c_module: bool = False, schemas=("public",), scratch: bool = False, **kw):
    connect_args = dict(kw.pop("connect_args", {}))
    connect_args["options"] = branch_options(branch, c_module=c_module, schemas=tuple(schemas), scratch=scratch)
    return create_engine(url, connect_args=connect_args, **kw)


def attach_branch(engine, get_branch: Callable[[], Optional[str]]) -> None:
    @event.listens_for(engine, "begin")
    def _begin(conn):  # pragma: no cover - exercised in tests
        b = get_branch()
        if b and b != "main":
            conn.exec_driver_sql("select gnomon.begin(%(b)s)", {"b": b})


def use(conn, branch: str = "main") -> None:
    conn.execute(text("select gnomon.use(:b)"), {"b": branch})
