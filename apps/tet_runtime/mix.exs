defmodule TetRuntime.MixProject do
  use Mix.Project

  def project do
    [
      app: :tet_runtime,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: ">= 1.16.0",
      erlang: ">= 27.0",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Tet.Application, []},
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  defp deps do
    [
      {:tet_core, in_umbrella: true},
      {:tet_store_sqlite, in_umbrella: true, only: :test},
      {:tet_store_memory, in_umbrella: true, only: :test},
      {:jason, "~> 1.0"}
    ]
  end
end
