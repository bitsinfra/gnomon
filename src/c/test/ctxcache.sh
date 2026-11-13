#!/usr/bin/env bash
# Cross-session invalidation of the C module's cached read context (see ctxcache.py).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
PY=$ROOT/build/venv/bin/python
[ -x "$PY" ] && "$PY" -c "import psycopg" 2>/dev/null || { echo "skip: needs build/venv with psycopg"; exit 0; }
"$PY" "$ROOT/src/c/test/ctxcache.py" "${PGHOST:-$ROOT/build}" "${PGPORT:-54330}"
