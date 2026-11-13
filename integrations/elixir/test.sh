#!/bin/sh
# The Elixir binding's tests with a fake query module (no Postgrex or database needed);
# mix test (after mix deps.get) runs it too, and with GNOMON_TEST_URL the Postgrex and Ecto
# tests against a real database (test/gnomon_db_test.exs).
set -e
cd "$(dirname "$0")"
elixir -r lib/gnomon.ex -r lib/gnomon/ecto.ex -r lib/gnomon/case.ex -r test/test_helper.exs test/gnomon_test.exs
