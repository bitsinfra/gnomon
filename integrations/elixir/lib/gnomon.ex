defmodule Gnomon do
  @moduledoc """
  Branches of a PostgreSQL database with gnomon, from Elixir (Postgrex and Ecto).

      # connections that start on a branch (Postgrex sends these as startup parameters)
      Postgrex.start_link(Gnomon.connect_opts([database: "app"], "feature"))

      # or put each new connection of a pool on a branch
      Postgrex.start_link(database: "app", after_connect: {Gnomon, :use, ["feature"]})

      # one transaction on a branch (behind pgbouncer in transaction mode)
      Gnomon.with_branch(conn, "feature", fn conn -> Postgrex.query!(conn, "...", []) end)

  The query module is Postgrex unless `config :gnomon, query: Mod` names another with the same
  `query!/3` and `transaction/2` (tests use a fake one).
  """

  defp q, do: Application.get_env(:gnomon, :query, Postgrex)

  @doc "The routing schema of a user schema (scratch branches have their own)."
  def routing_schema(schema, scratch \\ false), do: "gnomon_r_" <> schema <> if(scratch, do: "__s", else: "")

  @doc """
  The startup parameters that put sessions on a branch: gnomon.branch, and without the C module
  a search path with the routing schemas first.
  """
  def branch_parameters(branch, opts \\ []) do
    params = ["gnomon.branch": branch]

    if Keyword.get(opts, :c_module, false) do
      params
    else
      path =
        opts
        |> Keyword.get(:schemas, ["public"])
        |> Enum.flat_map(&[routing_schema(&1), &1])
        |> Enum.join(",")

      params ++ [search_path: path]
    end
  end

  @doc "Postgrex connection options with sessions starting on a branch."
  def connect_opts(opts, branch, gopts \\ []) do
    Keyword.update(opts, :parameters, branch_parameters(branch, gopts), &(&1 ++ branch_parameters(branch, gopts)))
  end

  @doc "What the database says a branch's sessions need, as libpq options (schema versions, masks)."
  def connection_options(conn, branch, c_module \\ false),
    do: value(conn, "select gnomon.connection_options($1, $2)", [branch, c_module])

  @doc "Put a session on a branch (\"main\" leaves it). Usable as Postgrex's after_connect."
  def use(conn, branch), do: value(conn, "select gnomon.use($1)", [branch])

  @doc "Put the current transaction on a branch."
  def begin(conn, branch), do: value(conn, "select gnomon.begin($1)", [branch])

  @doc "Run fun in one transaction on a branch."
  def with_branch(conn, branch, fun) when is_atom(conn) and conn not in [nil, true, false] do
    if Code.ensure_loaded?(conn) and function_exported?(conn, :transaction, 2) do
      conn.transaction(fn ->
        begin(conn, branch)
        fun.(conn)
      end)
    else
      with_conn(conn, branch, fun)
    end
  end

  def with_branch(conn, branch, fun), do: with_conn(conn, branch, fun)

  defp with_conn(conn, branch, fun) do
    q().transaction(conn, fn tx ->
      begin(tx, branch)
      fun.(tx)
    end)
  end

  def create_branch(conn, name, parent \\ "main", kind \\ "logged"),
    do: value(conn, "select gnomon.create_branch($1, $2, $3)::text", [name, parent, kind])

  @doc "A scratch branch with a fresh name."
  def create_scratch(conn, prefix \\ "test", parent \\ "main") do
    name = value(conn, "select $1 || '/' || substr(md5(random()::text), 1, 10)", [prefix])
    create_branch(conn, name, parent, "scratch")
    name
  end

  def drop_branch(conn, name), do: value(conn, "select gnomon.drop_branch($1, true)::text", [name])

  @doc "Merge a branch into its parent (or target); returns the merge's status."
  def merge(conn, source, target \\ nil) do
    id = value(conn, "select gnomon.merge($1, $2)::text", [source, target])
    value(conn, "select status from gnomon.merge where id = $1::bigint", [id])
  end

  @doc "The stable [gnomon:<slug>] of an error (Postgrex puts it in the hint), or nil."
  def code(%{postgres: pg}) when is_map(pg),
    do: [pg[:message], pg[:hint], pg[:detail]] |> Enum.reject(&is_nil/1) |> Enum.join(" ") |> code()
  def code(%{message: m}) when is_binary(m), do: code(m)

  def code(m) when is_binary(m) do
    case Regex.run(~r/\[gnomon:([a-z_0-9]+)\]/, m) do
      [_, slug] -> slug
      _ -> nil
    end
  end

  def code(_), do: nil

  # an Ecto repo is queried through Ecto.Adapters.SQL; anything else through the query module
  defp run(conn, sql, params) when is_atom(conn) and conn not in [nil, true, false] do
    if Code.ensure_loaded?(conn) and function_exported?(conn, :__adapter__, 0),
      do: apply(Ecto.Adapters.SQL, :query!, [conn, sql, params]),
      else: q().query!(conn, sql, params)
  end

  defp run(conn, sql, params), do: q().query!(conn, sql, params)

  defp value(conn, sql, params) do
    case run(conn, sql, params) do
      %{rows: [[v | _] | _]} -> v
      _ -> nil
    end
  end
end
