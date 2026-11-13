#!/usr/bin/env bash
# The coordinate each statement read, reported to the client (see coordreport.py).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
PY=$ROOT/build/venv/bin/python
[ -x "$PY" ] && "$PY" -c "import psycopg" 2>/dev/null || { echo "skip: needs build/venv with psycopg"; exit 0; }
"$PY" "$ROOT/src/c/test/coordreport.py" "${PGHOST:-$ROOT/build}" "${PGPORT:-54330}"
