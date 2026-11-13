#!/usr/bin/env bash
# Use the release files as a consumer would, with no source checkout on the import path.
set -euo pipefail
out=$(cd "${1:?release directory}" && pwd)
scratch=$(mktemp -d); trap 'rm -rf "$scratch"' EXIT
(cd "$out" && shasum -a 256 -c checksums.txt)
cd "$scratch"
os=$(uname -s | tr '[:upper:]' '[:lower:]'); arch=$(uname -m)
case "$arch" in arm64|aarch64) arch=arm64;; x86_64) arch=amd64;; esac
tar -xzf "$out"/gnomon_*_"${os}_${arch}".tar.gz
v=$(./gnomon version); test -f "$out/gnomon_${v#gnomon }_${os}_${arch}.tar.gz"
npm init -y >/dev/null
npm install --no-audit --no-fund "$out"/*.tgz
node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { Gnomon } from '@bitsinfra/gnomon';
import { nodePostgres } from '@bitsinfra/gnomon/pg';
import { claudeAgentServer } from '@bitsinfra/gnomon/claude-agent';
import { createRequire } from 'node:module';
const binding = createRequire(import.meta.url)('@bitsinfra/gnomon-postgres');
for (const fn of [Gnomon, nodePostgres, claudeAgentServer, binding.branchOptions]) assert.equal(typeof fn, 'function');
JS
python3 -m venv venv
venv/bin/python -m pip install --disable-pip-version-check 'psycopg[binary]' "$out"/*.whl
venv/bin/python -I -c 'from gnomon import Gnomon; from gnomon.tools import TOOL_SPECS; assert any(t["name"] == "diff" for t in TOOL_SPECS)'
