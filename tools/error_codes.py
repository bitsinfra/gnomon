"""Print the table of error codes in docs/errors.md from src/sql: each
[gnomon:<slug>] with the SQLSTATE and message of its first raise, "…" for values filled in at run
time. `python3 tools/error_codes.py --write` replaces the table in docs/errors.md, keeping the
hand-written rows for codes no raise in src/sql spells out (explain_error's, the C module's,
hints built with format()) while something in src/, cli/ or sdk/ still names them, and dropping
the rows of codes nothing names any more."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RAISE = re.compile(r"raise\s+exception\s+'((?:[^']|'')*)'((?:'(?:[^']|'')*'|[^;'])*);", re.S | re.I)
ERRCODE = re.compile(r"errcode\s*=\s*'([0-9A-Z]{5})'", re.I)
SLUG = re.compile(r"\[gnomon:([a-z_0-9]+)\]")


def rows():
    seen = {}
    for f in sorted((ROOT / "src" / "sql").glob("*.sql")):
        text = f.read_text()
        for m in RAISE.finditer(text):
            rest = m.group(2)
            s = SLUG.search(rest)
            if not s or s.group(1) in seen:
                continue
            msg = m.group(1).replace("''", "'")
            msg = re.sub(r"%[sIL]?", "…", msg).replace("%%", "%")
            msg = re.sub(r"\s+", " ", msg).strip().replace("|", "\\|")
            code = ERRCODE.search(rest)
            passed = re.search(r"errcode\s*=\s*sqlstate", rest, re.I)
            seen[s.group(1)] = (code.group(1) if code else "(the cause's)" if passed else "P0001", msg)
    return sorted(seen.items())


def named_elsewhere(slug):
    for d in ("src", "cli", "sdk"):
        for f in (ROOT / d).rglob("*"):
            if f.is_file() and f.suffix in (".sql", ".c", ".go", ".ts", ".py") and f"gnomon:{slug}]" in f.read_text(errors="ignore"):
                return True
    return False


def table(old=""):
    found = dict(rows())
    lines = {slug: f"| `{slug}` | {state} | {msg} |" for slug, (state, msg) in found.items()}
    for line in old.splitlines():
        m = re.match(r"\| `([a-z_0-9]+)` \|", line)
        if m and m.group(1) not in lines and named_elsewhere(m.group(1)):
            lines[m.group(1)] = line
    out = ["| Code | SQLSTATE | Message |", "|---|---|---|"] + [lines[k] for k in sorted(lines)]
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    if "--write" in sys.argv:
        p = ROOT / "docs" / "errors.md"
        doc = p.read_text()
        start = doc.index("| Code | SQLSTATE | Message |")
        end = doc.find("\n\n", start)
        end = len(doc) if end < 0 else end + 1
        p.write_text(doc[:start] + table(doc[start:end]) + doc[end:])
    else:
        sys.stdout.write(table())
