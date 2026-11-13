defmodule Gnomon.MixProject do
  use Mix.Project

  def project do
    [
      app: :gnomon,
      version: "1.0.1",
      elixir: "~> 1.14",
      description: "Branches of a PostgreSQL database with gnomon; an ExUnit case with a scratch branch per test",
      deps: [{:postgrex, ">= 0.17.0", optional: true}, {:ecto_sql, "~> 3.10", optional: true}],
      package: [licenses: ["PostgreSQL"], links: %{"GitHub" => "https://github.com/bitsinfra/gnomon"}],
      source_url: "https://github.com/bitsinfra/gnomon"
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
