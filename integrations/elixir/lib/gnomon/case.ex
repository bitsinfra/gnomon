defmodule Gnomon.Case do
  @moduledoc """
  ExUnit: each test gets a connection on its own scratch branch of one seeded database, dropped
  when the test ends (GNOMON_KEEP=1 keeps it).

      defmodule SignupTest do
        use Gnomon.Case, connect: fn -> Postgrex.start_link(database: "app_test") end
        test "signup", %{conn: conn, branch: branch} do
          Postgrex.query!(conn, "insert into users(email) values ('a@example.com')", [])
        end
      end

  The connection is a single Postgrex process (not a pool), so every query of the test is on the
  branch. Tests may be async: branches do not see each other.

  With Ecto, `use Gnomon.Case, repo: MyApp.Repo` takes the place of the SQL sandbox: the test
  checks a connection out of the sandbox pool without its transaction (`sandbox: false`), puts it
  on a fresh scratch branch, and its code may commit, open transactions and share the connection
  with processes it allows (`Ecto.Adapters.SQL.Sandbox.allow/3`). The repo's pool must be the
  sandbox pool (`pool: Ecto.Adapters.SQL.Sandbox`), as for the sandbox itself.
  """

  defmacro __using__(opts) do
    quote do
      use ExUnit.Case, async: Keyword.get(unquote(opts), :async, true)

      setup do
        o = unquote(opts)
        parent = Keyword.get(o, :parent, "main")

        case Keyword.fetch(o, :repo) do
          {:ok, repo} -> Gnomon.Case.setup_repo(repo, parent)
          :error -> Gnomon.Case.setup_branch(Keyword.fetch!(o, :connect), parent)
        end
      end
    end
  end

  @doc false
  def setup_repo(repo, parent) do
    sandbox = Ecto.Adapters.SQL.Sandbox
    :ok = apply(sandbox, :checkout, [repo, [sandbox: false]])
    branch = Gnomon.create_scratch(repo, "exunit", parent)
    Gnomon.use(repo, branch)

    ExUnit.Callbacks.on_exit(fn ->
      # the test's connection went back to the pool still on the branch: whichever connection
      # this process gets is put back on main before the branch goes
      :ok = apply(sandbox, :checkout, [repo, [sandbox: false]])
      Gnomon.use(repo, "main")
      if System.get_env("GNOMON_KEEP") != "1", do: Gnomon.drop_branch(repo, branch)
      apply(sandbox, :checkin, [repo])
    end)

    {:ok, repo: repo, branch: branch}
  end

  @doc false
  def setup_branch(connect, parent) do
    {:ok, conn} = connect.()
    branch = Gnomon.create_scratch(conn, "exunit", parent)
    Gnomon.use(conn, branch)

    ExUnit.Callbacks.on_exit(fn ->
      if System.get_env("GNOMON_KEEP") != "1" do
        {:ok, c} = connect.()
        Gnomon.drop_branch(c, branch)
      end
    end)

    {:ok, conn: conn, branch: branch}
  end
end
