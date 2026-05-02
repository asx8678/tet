defmodule Tet.Umbrella.MixProject do
  use Mix.Project

  @version "0.1.0"
  @standalone_applications [
    tet_core: :permanent,
    tet_store_sqlite: :permanent,
    tet_runtime: :permanent,
    tet_cli: :permanent
  ]

  @web_applications @standalone_applications ++ [tet_web_phoenix: :permanent]

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
        "web.facade_contract": :test,
        "web.removability": :test,
        "release.acceptance": :test,
        "release.standalone": :prod,
        "smoke.first_mile": :prod
      ]
    ]
  end

  defp aliases do
    [
      "standalone.check": [
        "format --check-formatted",
        "web.facade_contract",
        "test",
        &check_release_closure/1
      ],
      "web.facade_contract": [&check_web_facade_contract/1],
      "web.removability": [&check_web_removability/1],
      "release.acceptance": [&check_release_acceptance/1],
      "release.standalone": ["release tet_standalone --overwrite"],
      "smoke.first_mile": [&smoke_first_mile/1]
    ]
  end

  defp check_release_closure(_args) do
    run_script!("tools/check_release_closure.sh")
  end

  defp check_web_facade_contract(_args) do
    run_script!("tools/check_web_facade_contract.sh")
  end

  defp check_web_removability(_args) do
    run_script!("tools/check_web_removability.sh")
  end

  defp check_release_acceptance(args) do
    run_script!("tools/check_release_acceptance.sh", args)
  end

  defp smoke_first_mile(args) do
    run_script!("tools/smoke_first_mile.sh", args)
  end

  defp run_script!(path, args \\ []) do
    script = Path.expand(path, __DIR__)

    case System.cmd(script, args, cd: __DIR__, stderr_to_stdout: true) do
      {output, 0} ->
        Mix.shell().info(output)

      {output, status} ->
        Mix.shell().error(output)
        exit({:shutdown, status})
    end
  end

  defp releases do
    [
      tet_standalone: [
        applications: @standalone_applications,
        include_executables_for: [:unix],
        overlays: ["rel/overlays"],
        steps: [:assemble, &Tet.Release.assert_standalone_release!/1]
      ],
      tet_web: [
        applications: @web_applications,
        include_executables_for: [:unix],
        overlays: ["rel/overlays"]
      ]
    ]
  end
end
