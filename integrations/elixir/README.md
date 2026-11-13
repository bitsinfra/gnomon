# gnomon for Elixir

Branches of a PostgreSQL database with gnomon from Postgrex and Ecto, and an ExUnit case that
gives each test its own scratch branch in place of the SQL sandbox.

## Install

```elixir
# mix.exs
defp deps do
  [
    {:gnomon, git: "https://github.com/bitsinfra/gnomon.git", tag: "v1.0.2", sparse: "integrations/elixir"},
    {:postgrex, ">= 0.17.0"}          # and {:ecto_sql, "~> 3.10"} for Ecto
  ]
end
```

Then `mix deps.get`. Elixir 1.14 or later. Postgrex and Ecto are optional dependencies of gnomon,
so list the ones your application uses.

## On a branch

```elixir
# Postgrex: sessions that start on a branch (startup parameters)
Postgrex.start_link(Gnomon.connect_opts([database: "app"], "feature"))       # c_module: true with the C module

# or each new connection on a branch
Postgrex.start_link(database: "app", after_connect: {Gnomon, :use, ["feature"]})

# Ecto: the repo's pool on a branch, queries prefixed with the routing schema
config :my_app, MyApp.Repo, Gnomon.Ecto.repo_config([database: "app"], "feature")
def default_options(_op), do: [prefix: Gnomon.Ecto.prefix()]                 # in MyApp.Repo

# one transaction on a branch (behind pgbouncer in transaction mode)
Gnomon.with_branch(MyApp.Repo, "feature", fn repo -> repo.insert!(%Order{}) end)

# errors: the stable slug
rescue e in Postgrex.Error -> Gnomon.code(e)                                  # "ddl_on_branch"
```

`Gnomon.connection_options(conn, branch)` returns what the database computes for a branch (its
schema version and mask included), for tools that take libpq options.

## ExUnit

```elixir
defmodule MyApp.SignupTest do
  use Gnomon.Case, repo: MyApp.Repo        # or connect: fn -> Postgrex.start_link(...) end
  test "signup", %{repo: repo, branch: branch} do
    repo.insert!(%User{email: "a@example.com"})   # committed, on the test's own branch
  end
end
```

With `repo:`, the test checks a connection out of the sandbox pool without the sandbox's
transaction, so the code under test may commit and use transactions of its own. The repo's pool
must be `Ecto.Adapters.SQL.Sandbox` as for the sandbox. Each branch is dropped when its test ends
(`GNOMON_KEEP=1` keeps them).

## Tests

`./test.sh` runs the tests with a fake query module: no Postgrex, Ecto or database is needed.
