defmodule FakeQuery do
  # answers queries from a function and records them (no database needed)
  def start(answer), do: Agent.start_link(fn -> {answer, []} end, name: __MODULE__)
  def log, do: Agent.get(__MODULE__, fn {_, l} -> Enum.reverse(l) end)
  def clear, do: Agent.update(__MODULE__, fn {a, _} -> {a, []} end)

  def query!(_conn, sql, params) do
    Agent.get_and_update(__MODULE__, fn {a, l} -> {%{rows: [[a.(sql, params)]]}, {a, [{sql, params} | l]}} end)
  end

  def transaction(conn, fun) do
    Agent.update(__MODULE__, fn {a, l} -> {a, [:begin | l]} end)
    r = fun.(conn)
    Agent.update(__MODULE__, fn {a, l} -> {a, [:commit | l]} end)
    {:ok, r}
  end
end

defmodule GnomonTest do
  use ExUnit.Case

  setup_all do
    Application.put_env(:gnomon, :query, FakeQuery)

    FakeQuery.start(fn
      "select $1 || '/'" <> _, [p] -> p <> "/abc"
      "select gnomon.merge" <> _, _ -> "42"
      "select status" <> _, _ -> "merged"
      _, _ -> "ok"
    end)

    :ok
  end

  setup do
    FakeQuery.clear()
  end

  test "parameters" do
    assert Gnomon.branch_parameters("f", c_module: true) == ["gnomon.branch": "f"]
    assert Gnomon.branch_parameters("f") == ["gnomon.branch": "f", search_path: "gnomon_r_public,public"]
    assert Gnomon.branch_parameters("f", schemas: ["app", "public"])[:search_path] == "gnomon_r_app,app,gnomon_r_public,public"
    assert Gnomon.connect_opts([database: "app", parameters: [application_name: "x"]], "f", c_module: true) ==
             [database: "app", parameters: [application_name: "x", "gnomon.branch": "f"]]
    assert Gnomon.routing_schema("app", true) == "gnomon_r_app__s"
  end

  test "codes" do
    assert Gnomon.code(%{postgres: %{message: "refused [gnomon:ddl_on_branch]"}}) == "ddl_on_branch"
    assert Gnomon.code("plain") == nil
  end

  test "calls" do
    assert Gnomon.use(:c, "feature") == "ok"
    assert Gnomon.merge(:c, "feature") == "merged"

    assert FakeQuery.log() == [
             {"select gnomon.use($1)", ["feature"]},
             {"select gnomon.merge($1, $2)::text", ["feature", nil]},
             {"select status from gnomon.merge where id = $1::bigint", ["42"]}
           ]
  end

  test "with_branch" do
    assert Gnomon.with_branch(:c, "feature", fn _ -> 7 end) == {:ok, 7}
    assert FakeQuery.log() == [:begin, {"select gnomon.begin($1)", ["feature"]}, :commit]
  end

  test "Ecto helpers" do
    assert Gnomon.Ecto.prefix() == "gnomon_r_public"
    assert Gnomon.Ecto.repo_config([database: "app"], "f")[:after_connect] == {Gnomon, :use, ["f"]}
    cfg = Gnomon.Ecto.repo_config([after_connect: {Kernel, :send, [:x]}], "f")
    assert cfg[:after_connect] == {Gnomon.Ecto, :after_connect, [{Kernel, :send, [:x]}, "f"]}
    send(self(), :ignored)
    Gnomon.Ecto.after_connect(self(), fn _ -> :ok end, "f")
    assert FakeQuery.log() == [{"select gnomon.use($1)", ["f"]}]
  end

  test "Gnomon.Case's setup" do
    {:ok, conn: :c, branch: "exunit/abc"} = Gnomon.Case.setup_branch(fn -> {:ok, :c} end, "main")

    assert FakeQuery.log() == [
             {"select $1 || '/' || substr(md5(random()::text), 1, 10)", ["exunit"]},
             {"select gnomon.create_branch($1, $2, $3)::text", ["exunit/abc", "main", "scratch"]},
             {"select gnomon.use($1)", ["exunit/abc"]}
           ]
  end
end
