defmodule GnomonDbTest.Repo do
  use Ecto.Repo, otp_app: :gnomon, adapter: Ecto.Adapters.Postgres
end

defmodule GnomonDbTest do
  # Against a real database (GNOMON_TEST_URL, postgres://user@host:port/db): Postgrex and Ecto.
  use ExUnit.Case
  @url System.get_env("GNOMON_TEST_URL")
  if is_nil(@url), do: @moduletag(skip: "GNOMON_TEST_URL is not set")

  def opts do
    u = URI.parse(@url)
    [hostname: u.host, port: u.port, username: u.userinfo, database: String.trim_leading(u.path, "/")]
  end

  def count(c), do: Postgrex.query!(c, "select count(*) from ex_item", []).rows |> hd() |> hd()

  setup_all do
    Application.put_env(:gnomon, :query, Postgrex)
    {:ok, a} = Postgrex.start_link(opts())
    for q <- ["drop table if exists ex_item", "create table ex_item (id int primary key, name text)", "select gnomon.track('ex_item')"],
        do: Postgrex.query!(a, q, [])

    on_exit(fn ->
      {:ok, c} = Postgrex.start_link(opts())
      Postgrex.query!(c, "select gnomon.drop_branch(name, true) from gnomon.branch where name like 'ex-%'", [])
      Postgrex.query!(c, "select gnomon.untrack('ex_item')", [])
      Postgrex.query!(c, "drop table ex_item", [])
    end)

    # the repo runs for the whole module, as an application's does (Gnomon.Case's cleanup uses it)
    Application.put_env(:gnomon, GnomonDbTest.Repo, Gnomon.Ecto.repo_config(opts() ++ [pool: Ecto.Adapters.SQL.Sandbox, pool_size: 2], "main"))
    start_supervised!(GnomonDbTest.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(GnomonDbTest.Repo, :manual)
    {:ok, admin: a}
  end

  test "sessions that start on a branch, after_connect, with_branch", %{admin: a} do
    Gnomon.create_branch(a, "ex-a")
    {:ok, c} = Postgrex.start_link(Gnomon.connect_opts(opts(), "ex-a"))
    Postgrex.query!(c, "insert into ex_item values (1, 'startup parameters')", [])
    assert count(c) == 1
    assert count(a) == 0

    {:ok, c2} = Postgrex.start_link(opts() ++ [after_connect: {Gnomon, :use, ["ex-a"]}])
    Postgrex.query!(c2, "insert into ex_item values (2, 'after_connect')", [])
    {:ok, c3} = Postgrex.start_link(opts())
    {:ok, n} = Gnomon.with_branch(c3, "ex-a", fn tx -> count(tx) end)
    assert n == 2
    assert count(c3) == 0

    e = assert_raise Postgrex.Error, fn -> Postgrex.query!(c, "alter table ex_item add column z int", []) end
    assert Gnomon.code(e) == "ddl_on_branch"
  end

  test "Gnomon.Case with a connection" do
    {:ok, conn: c, branch: b} = Gnomon.Case.setup_branch(fn -> Postgrex.start_link(opts()) end, "main")
    assert String.starts_with?(b, "exunit/")
    Postgrex.query!(c, "insert into ex_item values (3, 'scratch')", [])
    assert count(c) == 1
  end

  test "Ecto: repo_config, with_branch, and Gnomon.Case in place of the sandbox" do
    # what `use Gnomon.Case, repo: ...` does in its setup: a sandbox connection without the
    # sandbox's transaction, on a scratch branch of its own
    {:ok, repo: repo, branch: b} = Gnomon.Case.setup_repo(GnomonDbTest.Repo, "main")
    assert String.starts_with?(b, "exunit/")
    repo.query!("insert into ex_item values (5, 'committed on the scratch branch')")
    assert repo.query!("select count(*) from ex_item").rows == [[1]]

    # one transaction on another branch, through the repo
    Gnomon.create_branch(repo, "ex-e")
    {:ok, _} = Gnomon.with_branch(repo, "ex-e", fn r -> r.query!("insert into ex_item values (4, 'ecto')") end)
    {:ok, rows} = Gnomon.with_branch(repo, "ex-e", fn r -> r.query!("select id from ex_item").rows end)
    assert rows == [[4]]
  end
end
