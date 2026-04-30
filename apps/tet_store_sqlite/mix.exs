defmodule TetStoreSQLite.MixProject do
  use Mix.Project

  def project do
    [
      app: :tet_store_sqlite,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: ">= 1.16.0",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Tet.Store.SQLite.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:tet_core, in_umbrella: true}
    ]
  end
end
