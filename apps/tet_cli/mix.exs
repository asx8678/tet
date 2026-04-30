defmodule TetCLI.MixProject do
  use Mix.Project

  def project do
    [
      app: :tet_cli,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: ">= 1.16.0",
      erlang: ">= 27.0",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Tet.CLI],
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:tet_core, in_umbrella: true},
      {:tet_runtime, in_umbrella: true}
    ]
  end
end
