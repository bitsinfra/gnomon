#!/usr/bin/env bash
# The gnomon GitHub Action's logic. Testable locally: see action/test.sh.
set -euo pipefail
BIN=${GNOMON_BIN:-gnomon}
BRANCH=${GNOMON_BRANCH:-}
[ -z "$BRANCH" ] && BRANCH="pr-${PR_NUMBER:?set inputs.branch or run on a pull_request event}"
MODE=${GNOMON_MODE:-auto}
if [ "$MODE" = "auto" ]; then
  if [ "${PR_ACTION:-}" = "closed" ]; then MODE=drop; else MODE=create; fi
fi
out() { echo "$1=$2" >> "${GITHUB_OUTPUT:-/dev/stdout}"; }
out branch "$BRANCH"

case "$MODE" in
  create)
    if "$BIN" --json branch list | grep -q "\"name\": \"$BRANCH\""; then
      echo "branch $BRANCH exists"
    else
      "$BIN" branch create "$BRANCH" --parent "${GNOMON_PARENT:-main}" --note "pull request ${PR_NUMBER:-}" >/dev/null
      echo "created branch $BRANCH from ${GNOMON_PARENT:-main}"
    fi
    # migrations: schema changes on the branch, before its URL (which names the
    # branch's schema version) is computed
    if [ -n "${GNOMON_MIGRATIONS:-}" ]; then
      # shellcheck disable=SC2086
      files=$(ls -1 $GNOMON_MIGRATIONS 2>/dev/null | sort)
      if [ -n "$files" ]; then
        # shellcheck disable=SC2086
        "$BIN" migrate "$BRANCH" -- $files
      fi
    fi
    if [ "${GNOMON_C_MODULE:-false}" = "true" ]; then
      urls=$("$BIN" branch url "$BRANCH" --c-module)
    else
      urls=$("$BIN" branch url "$BRANCH")
    fi
    opts=$(echo "$urls" | sed -n 's/^options=//p')
    out options "$opts"
    enc=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$opts")
    case "$GNOMON_DSN" in
      *\?*) url="$GNOMON_DSN&options=$enc" ;;
      *://*) url="$GNOMON_DSN?options=$enc" ;;
      *) url="$GNOMON_DSN options='$opts'" ;;
    esac
    [ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$url"
    out database-url "$url"
    ;;
  comment)
    summary=$("$BIN" --json diff "$BRANCH" --summary)
    schema=$("$BIN" --json schema "$BRANCH" 2>/dev/null || echo "[]")
    body=$(python3 - "$BRANCH" "$summary" "$schema" <<'PY'
import json, sys
branch, rows = sys.argv[1], json.loads(sys.argv[2] or "[]")
try:
    schema = json.loads(sys.argv[3] or "[]") or []
except ValueError:
    schema = []
lines = []
if schema:
    lines += [f"### Schema changes on gnomon branch `{branch}`", "", "| operation | table | object | type |", "|---|---|---|---|"]
    lines += [f"| {c['op']} | {c['table'] or ''} | `{c['object']}` | {c['type']} |" for c in schema]
    lines += ["", "They reach main when the branch is merged.", ""]
lines += [f"### Data changes on gnomon branch `{branch}`", ""]
if not rows:
    lines.append("No data changes against the branch's base.")
else:
    lines += ["| table | inserts | updates | deletes |", "|---|---:|---:|---:|"]
    lines += [f"| {r['table']} | {r['inserts']} | {r['updates']} | {r['deletes']} |" for r in rows]
    lines += ["", f"Inspect with `gnomon diff {branch}` or `gnomon merge {branch} --preview`."]
print("\n".join(lines))
PY
)
    if [ -n "${PR_NUMBER:-}" ] && command -v gh >/dev/null && [ -n "${GH_TOKEN:-}" ]; then
      gh pr comment "$PR_NUMBER" --body "$body"
    else
      echo "$body"
    fi
    ;;
  drop)
    # a branch already gone is fine (closing a PR twice); any other failure is the job's
    if out=$("$BIN" branch drop "$BRANCH" --cascade 2>&1); then
      echo "dropped branch $BRANCH"
    elif echo "$out" | grep -q 'SQLSTATE 42704'; then   # (unknown branch)
      echo "branch $BRANCH was already dropped"
    else
      echo "$out" >&2
      exit 1
    fi
    ;;
  *) echo "unknown mode $MODE" >&2; exit 2 ;;
esac
