"""Generate the sync Python client from the async one (one source, so they cannot drift).

    python3 tools/unasync.py          writes integrations/python/gnomon/client.py
    python3 tools/unasync.py --check  fails when client.py is out of date
"""
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
src = root / "integrations/python/gnomon/aio.py"
dst = root / "integrations/python/gnomon/client.py"

RULES = [
    (r"\basync def\b", "def"), (r"\bawait\s+", ""), (r"\basync with\b", "with"), (r"\basync for\b", "for"),
    (r"\bAsync(Gnomon|Run|Requests|Request|Branches|Adapter)\b", r"\1"),
    (r"psycopg\.AsyncConnection", "psycopg.Connection"), (r"\bAsyncIterator\b", "Iterator"),
    (r"__aenter__", "__enter__"), (r"__aexit__", "__exit__"),
    (r"contextlib\.asynccontextmanager", "contextlib.contextmanager"),
    (r"asyncio\.sleep", "time.sleep"), (r"asyncio\.Lock\(\)", "threading.Lock()"), (r"^import asyncio$", "import threading\nimport time"),
    (r"The gnomon SDK, async", "The gnomon SDK, sync"), (r"``client\.py`` is generated from this file by ``tools/unasync\.py``: change this one\.",
     "Generated from ``aio.py`` by ``tools/unasync.py``: do not edit; change aio.py."),
    (r"async_with_statement", "with"),
]


def generate() -> str:
    out = src.read_text()
    for pat, rep in RULES:
        out = re.sub(pat, rep, out, flags=re.M)
    out = out.replace("    gn = Gnomon(app=", "    gn = Gnomon(app=").replace("with await gn.start_run", "with gn.start_run")
    return out


if __name__ == "__main__":
    text = generate()
    if "--check" in sys.argv:
        if dst.read_text() != text:
            sys.exit("client.py is out of date: run python3 tools/unasync.py")
        sys.exit(0)
    dst.write_text(text)
    print(f"wrote {dst.relative_to(root)}")
