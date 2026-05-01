defmodule TetStoreMemory.MixProject do
  use Mix.Project

  def project do
    [
      app: :tet_store_memory,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: ">= 1.16.0",
      erlang: ">= 27.0",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def application do
    [
      mod: {Tet.Store.Memory.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:tet_core, in_umbrella: true}
    ]
  end
end
