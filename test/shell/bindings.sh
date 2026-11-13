#!/usr/bin/env bash
# Each language binding against a real gnomon database, on a cluster of its own
# listening on 127.0.0.1 (JDBC reaches PostgreSQL over TCP only): Java (pgjdbc, mvn), Elixir
# (Postgrex and Ecto, mix), .NET (Npgsql and EF Core, dotnet) and PHP (PDO and Laravel, composer).
# A binding whose toolchain is not installed is skipped.
source "$(dirname "$0")/_cluster.sh"
[ -n "${GNOMON_SKIP_EXTERNAL:-}" ] && { echo "skip: GNOMON_SKIP_EXTERNAL"; exit 0; }
P=${BINDINGS_PORT:-54396}
tc_init bindings $P "" "listen_addresses = '127.0.0.1'"
mkdir -p "$ROOT/build/test-out"
db() { psql -X -q -h 127.0.0.1 -p $P -U postgres -d postgres -c "create database $1" >/dev/null &&
       psql -X -q -h 127.0.0.1 -p $P -U postgres -d $1 -c "set client_min_messages = warning" -c "create extension gnomon cascade" >/dev/null; }
ran=0
if command -v mvn >/dev/null && command -v java >/dev/null; then
  db gn_java
  (cd "$ROOT/integrations/java" && mvn -q -B test -Dgnomon.test.url="jdbc:postgresql://127.0.0.1:$P/gn_java?user=postgres") >"$ROOT/build/test-out/bindings_java.out" 2>&1 \
    || { tail -40 "$ROOT/build/test-out/bindings_java.out"; fail "the Java binding"; }
  echo "java: ok"; ran=$((ran + 1))
else echo "skip java: no mvn"; fi
if command -v mix >/dev/null && [ -d "$ROOT/integrations/elixir/deps/postgrex" ]; then
  db gn_elixir
  (cd "$ROOT/integrations/elixir" && GNOMON_TEST_URL="postgres://postgres@127.0.0.1:$P/gn_elixir" mix test) >"$ROOT/build/test-out/bindings_elixir.out" 2>&1 \
    || { tail -40 "$ROOT/build/test-out/bindings_elixir.out"; fail "the Elixir binding"; }
  echo "elixir: $(grep -E '[0-9]+ tests?, [0-9]+ failures?' "$ROOT/build/test-out/bindings_elixir.out" | tail -1)"; ran=$((ran + 1))
else echo "skip elixir: no mix or no deps (mix deps.get)"; fi
DOTNET=$(command -v dotnet || ls /opt/homebrew/opt/dotnet@8/bin/dotnet 2>/dev/null || true)
if [ -n "$DOTNET" ]; then
  db gn_dotnet
  GNOMON_TEST_CONNECTION="Host=127.0.0.1;Port=$P;Username=postgres;Database=gn_dotnet" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
    "$DOTNET" test "$ROOT/integrations/dotnet/test/Gnomon.Tests" >"$ROOT/build/test-out/bindings_dotnet.out" 2>&1 \
    || { tail -40 "$ROOT/build/test-out/bindings_dotnet.out"; fail "the .NET binding"; }
  echo ".NET: $(grep -E 'Passed!|Failed!' "$ROOT/build/test-out/bindings_dotnet.out" | tail -1 | sed 's/ - Gnomon.*//')"; ran=$((ran + 1))
else echo "skip .NET: no dotnet"; fi
if command -v php >/dev/null && [ -x "$ROOT/integrations/laravel/vendor/bin/phpunit" ]; then
  db gn_php
  (cd "$ROOT/integrations/laravel" && GNOMON_TEST_DSN="pgsql:host=127.0.0.1;port=$P;dbname=gn_php;user=postgres" vendor/bin/phpunit) >"$ROOT/build/test-out/bindings_php.out" 2>&1 \
    || { tail -40 "$ROOT/build/test-out/bindings_php.out"; fail "the PHP binding"; }
  echo "php: $(grep -E 'OK \(|Tests:' "$ROOT/build/test-out/bindings_php.out" | tail -1 | sed 's/\x1b\[[0-9;]*m//g')"; ran=$((ran + 1))
else echo "skip php: no php or no vendor (composer install)"; fi
echo "ok ($ran bindings)"
