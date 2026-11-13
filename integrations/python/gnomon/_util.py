"""Lossless JSON and the statement splitter (shared by the sync and async clients)."""
from __future__ import annotations

import json
import re
from decimal import Decimal
from typing import Any


def parse_json(text: Any) -> Any:
    """JSON text to Python: integers stay exact (int), decimals become Decimal (spec: Values)."""
    if text is None:
        return None
    if not isinstance(text, str):
        return text
    return json.loads(text, parse_float=Decimal)


def stable_json(v: Any) -> str:
    """JSON text with object keys sorted, compact, as the TypeScript SDK writes it (snapshots, digests)."""
    def default(x):
        return str(x)
    return json.dumps(_num(v), sort_keys=True, separators=(",", ":"), default=default, ensure_ascii=False)


def _num(v):
    if isinstance(v, Decimal):
        return int(v) if v == v.to_integral_value() else float(v) if str(float(v)) == str(v) else str(v)
    if isinstance(v, dict):
        return {k: _num(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_num(x) for x in v]
    return v


_DOLLAR = re.compile(r"\$([A-Za-z_][A-Za-z_0-9]*)?\$")


def split_sql(sql: str) -> list[str]:
    """Top-level statements of a script (the port of tools/sqlsplit.py)."""
    out, buf, i, n = [], [], 0, len(sql)
    while i < n:
        c = sql[i]
        if c == "-" and sql.startswith("--", i):
            j = sql.find("\n", i)
            j = n if j < 0 else j
            buf.append(sql[i:j]); i = j; continue
        if c == "/" and sql.startswith("/*", i):
            j = sql.find("*/", i + 2)
            j = n if j < 0 else j + 2
            buf.append(sql[i:j]); i = j; continue
        if c == "'":
            j = i + 1
            while j < n:
                if sql[j] == "'" and j + 1 < n and sql[j + 1] == "'":
                    j += 2; continue
                if sql[j] == "'":
                    break
                j += 1
            buf.append(sql[i:j + 1]); i = j + 1; continue
        if c == '"':
            j = sql.find('"', i + 1)
            j = n - 1 if j < 0 else j
            buf.append(sql[i:j + 1]); i = j + 1; continue
        if c == "$":
            m = _DOLLAR.match(sql, i)
            if m:
                tag = m.group(0)
                j = sql.find(tag, i + len(tag))
                j = n if j < 0 else j + len(tag)
                buf.append(sql[i:j]); i = j; continue
        if c == ";":
            buf.append(";"); out.append("".join(buf)); buf = []; i += 1; continue
        buf.append(c); i += 1
    rest = "".join(buf)
    if rest.strip():
        out.append(rest)
    def empty(s):
        s = re.sub(r"--[^\n]*", "", s)
        s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
        return s.replace(";", "").strip() == ""
    return [s for s in out if not empty(s)]
