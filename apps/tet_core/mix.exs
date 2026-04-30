defmodule TetCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :tet_core,
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
    [extra_applications: [:crypto, :logger]]
  end

  defp deps do
    []
  end
end
