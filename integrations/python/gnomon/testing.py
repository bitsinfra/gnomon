"""The testing layer: snapshot assertions on a branch's diff, normalized as the
specification says (sdk/spec/SPEC.md, Snapshots), with the golden files the TypeScript SDK checks.

    def test_signup(gnomon_conn, gnomon_snapshot):
        ...
        gnomon_snapshot.assert_match(gnomon_conn)     # pytest --gnomon-update-snapshots to record
"""
from __future__ import annotations

import os
from decimal import Decimal
from pathlib import Path
from typing import Any, Iterable, Optional

from ._util import parse_json, stable_json


def _short(t: str) -> str:
    return t.split(".")[-1]


def _sort_key(k: dict):
    out = []
    for name in sorted(k):
        v = k[name]
        out.append((0, v, "") if isinstance(v, (int, float, Decimal)) and not isinstance(v, bool) else (1, 0, str(v)))
    return out


def normalize_diff(diff: Iterable[dict], *, ignore: Iterable[str] = (), foreign_keys: Iterable[dict] = ()) -> list[str]:
    rows = [{"table": str(d["table"]), "key": d["key"], "kind": d["kind"],
             "col": d.get("column", d.get("col")), "old": d.get("old"), "new": d.get("new")} for d in diff]
    ignore = set(ignore)
    by_table: dict[str, list[dict]] = {}
    for r in rows:
        ks = by_table.setdefault(r["table"], [])
        if not any(stable_json(k) == stable_json(r["key"]) for k in ks):
            ks.append(r["key"])
    ph: dict[str, str] = {}
    idx: dict[str, int] = {}
    for t, ks in by_table.items():
        for i, k in enumerate(sorted(ks, key=_sort_key)):
            ph[f"{t}|{stable_json(k)}"] = f"<{_short(t)}:{i + 1}>"
            idx[f"{t}|{stable_json(k)}"] = i + 1
    fks = list(foreign_keys)

    def value(table: str, key: dict, col: str, v: Any) -> str:
        if len(key) == 1 and col in key:
            return ph.get(f"{table}|{stable_json(key)}", stable_json(v))
        for f in fks:
            if f["table"] == table and f["columns"] == [col]:
                p = ph.get(f"{f['references']}|{stable_json({f['referenced_columns'][0]: v})}")
                if p:
                    return p
        return stable_json(v)

    lines: dict[str, tuple] = {}
    for r in rows:
        ident = f"{r['table']}|{stable_json(r['key'])}"
        p, i = ph[ident], idx[ident]
        if r["kind"] == "delete":
            s = f"{r['table']} {p} delete"
            lines[s] = (r["table"], i, s)
        elif r["kind"] == "insert":
            for c, v in (r["new"] or {}).items():
                if c in ignore:
                    continue
                s = f"{r['table']} {p} insert {c} = {value(r['table'], r['key'], c, v)}"
                lines[s] = (r["table"], i, s)
        elif r["col"] is not None and r["col"] not in ignore:
            s = f"{r['table']} {p} update {r['col']}: {value(r['table'], r['key'], r['col'], r['old'])} -> {value(r['table'], r['key'], r['col'], r['new'])}"
            lines[s] = (r["table"], i, s)
    return [x[2] for x in sorted(lines.values())]


def branch_snapshot(conn, branch: str, *, ignore: Iterable[str] = ()) -> str:
    """A branch's diff as snapshot text, through a psycopg connection."""
    with conn.cursor() as cur:
        cur.execute("select tbl::text, key::text, kind, col, old::text, new::text from gnomon.diff(%s)", (branch,))
        diff = [{"table": t if "." in t else f"public.{t}", "key": parse_json(k), "kind": kind, "col": col, "old": parse_json(o), "new": parse_json(n)}
                for t, k, kind, col, o, n in cur.fetchall()]
        cur.execute("""select format('%%I.%%I', n.nspname, c.relname), (select array_agg(a.attname::text order by k.o) from unnest(f.conkey) with ordinality k(n, o) join pg_attribute a on a.attrelid = f.conrelid and a.attnum = k.n),
                              format('%%I.%%I', pn.nspname, p.relname), (select array_agg(a.attname::text order by k.o) from unnest(f.confkey) with ordinality k(n, o) join pg_attribute a on a.attrelid = f.confrelid and a.attnum = k.n)
                         from pg_constraint f join pg_class c on c.oid = f.conrelid join pg_namespace n on n.oid = c.relnamespace
                         join pg_class p on p.oid = f.confrelid join pg_namespace pn on pn.oid = p.relnamespace where f.contype = 'f'""")
        fks = [{"table": a, "columns": b, "references": c, "referenced_columns": d} for a, b, c, d in cur.fetchall()]
    return "\n".join(normalize_diff(diff, ignore=ignore, foreign_keys=fks)) + "\n"


class Snapshot:
    """``assert_match`` compares a branch's diff with a stored file (recorded with --gnomon-update-snapshots)."""

    def __init__(self, path: Path, update: bool):
        self.path, self.update = path, update

    def assert_match(self, conn, branch: Optional[str] = None, *, ignore: Iterable[str] = ()) -> None:
        if branch is None:
            with conn.cursor() as cur:
                cur.execute("select gnomon.current_branch()")
                branch = cur.fetchone()[0]
        got = branch_snapshot(conn, branch, ignore=ignore)
        if self.update or not self.path.exists():
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(got)
            return
        want = self.path.read_text()
        assert got == want, f"the branch's changes differ from {self.path}:\n--- stored\n{want}--- now\n{got}"


def assert_no_changes(conn, branch: str, tables: Optional[Iterable[str]] = None) -> None:
    with conn.cursor() as cur:
        cur.execute("select tbl::text, key from gnomon.diff(%s)", (branch,))
        hit = [(t, k) for t, k in cur.fetchall() if tables is None or any(t == x or t.endswith("." + x) for x in tables)]
    assert not hit, f"expected no changes, found {len(hit)}: {hit[:5]}"


def assert_changed(conn, branch: str, table: str, key: dict, column: str, value: Any) -> None:
    with conn.cursor() as cur:
        cur.execute("select kind, col, new::text from gnomon.diff(%s, null, array[%s::regclass], %s::jsonb)", (branch, table, stable_json([key])))
        for kind, col, new in cur.fetchall():
            n = parse_json(new)
            if (kind == "update" and col == column and n == value) or (kind == "insert" and (n or {}).get(column) == value):
                return
    raise AssertionError(f"expected {table} {key}.{column} = {value!r} on {branch}")


def snapshot_dir(request) -> Path:
    base = Path(request.config.getoption("--gnomon-snapshot-dir") or os.path.join(os.path.dirname(str(request.fspath)), "__gnomon_snapshots__"))
    return base / (request.node.name.replace("/", "_") + ".txt")
