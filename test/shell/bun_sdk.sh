#!/usr/bin/env bash
# The SDK's conformance scenarios through Bun's built-in client (import { SQL } from
# "bun"). Bun reaches PostgreSQL over TCP only, so this starts a cluster of its own listening on
# 127.0.0.1. Skipped without Bun.
source "$(dirname "$0")/_cluster.sh"
command -v bun >/dev/null || { echo "skip: no bun"; exit 0; }
[ -e "$ROOT/sdk/ts/node_modules/pg" ] || { echo "skip: the TypeScript SDK's dependencies are not installed"; exit 0; }
P=${BUN_SDK_PORT:-54392}
tc_init bun-sdk $P "" "listen_addresses = '127.0.0.1'"
mkdir -p "$ROOT/build/test-out"
(cd "$ROOT/sdk/ts" && GNOMON_SDK_HOST=127.0.0.1 GNOMON_SDK_PORT=$P bun test test/bun/conformance.test.ts) >"$ROOT/build/test-out/bun_sdk.out" 2>&1 \
  || { tail -30 "$ROOT/build/test-out/bun_sdk.out"; fail "the TypeScript SDK through Bun's client"; }
grep -E '^ *[0-9]+ pass' "$ROOT/build/test-out/bun_sdk.out"
echo ok
