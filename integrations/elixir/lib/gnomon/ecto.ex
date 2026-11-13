defmodule Gnomon.Ecto do
  @moduledoc """
  Ecto repos on a branch.

      # config/dev.exs: every connection of the repo's pool on a branch
      config :my_app, MyApp.Repo, Gnomon.Ecto.repo_config([database: "app"], "feature")

      # the repo: queries go to the routing schema (not needed with the C module, which routes
      # main's names itself)
      defmodule MyApp.Repo do
        use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres
        def default_options(_operation), do: [prefix: Gnomon.Ecto.prefix()]
      end

  Behind pgbouncer in transaction mode a session setting does not last; run the work in
  `Gnomon.with_branch(MyApp.Repo, "feature", fn repo -> ... end)`, which is one transaction
  that starts with gnomon.begin.
  """

  @doc "The prefix for Ecto queries: the routing schema of a user schema."
  def prefix(schema \\ "public", opts \\ []), do: Gnomon.routing_schema(schema, Keyword.get(opts, :scratch, false))

  @doc """
  Repo configuration whose connections start on a branch: an after_connect that calls
  gnomon.use (the branch's search path included), kept after any after_connect already set.
  """
  def repo_config(config, branch) do
    case Keyword.get(config, :after_connect) do
      nil -> Keyword.put(config, :after_connect, {Gnomon, :use, [branch]})
      prev -> Keyword.put(config, :after_connect, {__MODULE__, :after_connect, [prev, branch]})
    end
  end

  @doc false
  def after_connect(conn, prev, branch) do
    case prev do
      {m, f, a} -> apply(m, f, [conn | a])
      fun when is_function(fun, 1) -> fun.(conn)
    end

    Gnomon.use(conn, branch)
  end
end
