defmodule Tet.Umbrella.MixProject do
  use Mix.Project

  @version "0.1.0"
  @standalone_applications [
    tet_core: :permanent,
    tet_store_sqlite: :permanent,
    tet_runtime: :permanent,
    tet_cli: :permanent
  ]
  @forbidden_standalone_exact [
    :cowboy,
    :cowlib,
    :plug,
    :plug_cowboy,
    :ranch,
    :tet_web,
    :tet_web_phoenix,
    :websock,
    :websock_adapter
  ]
  @forbidden_standalone_prefixes [
    "bandit",
    "cowboy",
    "live_view",
    "phoenix",
    "plug",
    "tet_web",
    "thousand_island",
    "websock"
  ]

  def project do
    [
      apps_path: "apps",
      version: @version,
      elixir: ">= 1.16.0",
      erlang: ">= 27.0",
      start_permanent: Mix.env() == :prod,
      deps: [],
      releases: releases(),
      aliases: aliases()
    ]
  end

  def cli do
    [
      preferred_envs: [
        "standalone.check": :test,
        "release.standalone": :prod
      ]
    ]
  end

  defp aliases do
    [
      "standalone.check": [
        "format --check-formatted",
        "test",
        &check_release_closure/1
      ],
      "release.standalone": ["release tet_standalone --overwrite"]
    ]
  end

  defp check_release_closure(_args) do
    script = Path.expand("tools/check_release_closure.sh", __DIR__)

    case System.cmd(script, [], cd: __DIR__, stderr_to_stdout: true) do
      {output, 0} ->
        Mix.shell().info(output)

      {output, status} ->
        Mix.shell().error(output)
        exit({:shutdown, status})
    end
  end

  defp assert_standalone_release!(%Mix.Release{} = release) do
    leaked =
      release.applications
      |> Map.keys()
      |> Enum.filter(&forbidden_standalone_application?/1)

    if leaked != [] do
      Mix.raise("tet_standalone release contains forbidden web applications: #{inspect(leaked)}")
    end

    release
  end

  defp forbidden_standalone_application?(application) do
    name = Atom.to_string(application)

    application in @forbidden_standalone_exact or
      Enum.any?(@forbidden_standalone_prefixes, &String.starts_with?(name, &1))
  end

  defp releases do
    [
      tet_standalone: [
        applications: @standalone_applications,
        include_executables_for: [:unix],
        overlays: ["rel/overlays"],
        steps: [:assemble, &assert_standalone_release!/1]
      ]
    ]
  end
end
