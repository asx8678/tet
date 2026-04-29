# Implementation — Mix and Release Examples

These snippets use the final Tet names.

## Umbrella root

```elixir
defmodule Tet.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: [],
      releases: releases(),
      aliases: aliases()
    ]
  end

  defp aliases do
    [
      "ci.guards": [
        "cmd tools/check_imports.sh",
        "cmd tools/check_xref.sh",
        "cmd tools/check_release_closure.sh"
      ]
    ]
  end

  defp releases do
    [
      tet_standalone: [
        applications: [
          tet_core: :permanent,
          tet_store_sqlite: :permanent,
          tet_runtime: :permanent,
          tet_cli: :permanent
        ],
        include_executables_for: [:unix]
      ],
      tet_web: [
        applications: [
          tet_core: :permanent,
          tet_store_sqlite: :permanent,
          tet_runtime: :permanent,
          tet_cli: :permanent,
          tet_web_phoenix: :permanent
        ],
        include_executables_for: [:unix]
      ],
      tet_runtime_only: [
        applications: [
          tet_core: :permanent,
          tet_store_sqlite: :permanent,
          tet_runtime: :permanent
        ]
      ]
    ]
  end
end
```

## `tet_core`

```elixir
defmodule TetCore.MixProject do
  use Mix.Project

  def project do
    [app: :tet_core, version: "0.1.0", elixir: "~> 1.16", deps: deps()]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      {:jason, "~> 1.4"}
      # No Phoenix, no Plug, no Ecto, no runtime, no CLI, no web.
    ]
  end
end
```

## `tet_runtime`

```elixir
defmodule TetRuntime.MixProject do
  use Mix.Project

  def project do
    [app: :tet_runtime, version: "0.1.0", elixir: "~> 1.16", deps: deps()]
  end

  def application do
    [mod: {Tet.Application, []}, extra_applications: [:logger, :runtime_tools]]
  end

  defp deps do
    [
      {:tet_core, in_umbrella: true},
      {:telemetry, "~> 1.2"}
      # Optional/default store adapters are included by release profile and config.
      # No Phoenix, no Plug, no Phoenix.PubSub.
    ]
  end
end
```

## `tet_cli`

```elixir
defmodule TetCLI.MixProject do
  use Mix.Project

  def project do
    [
      app: :tet_cli,
      version: "0.1.0",
      elixir: "~> 1.16",
      escript: [main_module: Tet.CLI.Main],
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
      # Add terminal/argv libraries as needed; no web deps.
    ]
  end
end
```

## `tet_store_sqlite`

```elixir
defmodule TetStoreSQLite.MixProject do
  use Mix.Project

  def project do
    [app: :tet_store_sqlite, version: "0.1.0", elixir: "~> 1.16", deps: deps()]
  end

  def application do
    [mod: {Tet.Store.SQLite.Application, []}, extra_applications: [:logger]]
  end

  defp deps do
    [
      {:tet_core, in_umbrella: true},
      {:ecto_sql, "~> 3.11"},
      {:ecto_sqlite3, "~> 0.15"}
      # No tet_runtime, no CLI, no web.
    ]
  end
end
```

## `tet_web_phoenix` optional

```elixir
defmodule TetWebPhoenix.MixProject do
  use Mix.Project

  def project do
    [app: :tet_web_phoenix, version: "0.1.0", elixir: "~> 1.16", deps: deps()]
  end

  def application do
    [mod: {TetWebPhoenix.Application, []}, extra_applications: [:logger, :runtime_tools]]
  end

  defp deps do
    [
      {:tet_core, in_umbrella: true},
      {:tet_runtime, in_umbrella: true},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 0.20"},
      {:phoenix_html, "~> 4.0"},
      {:plug_cowboy, "~> 2.6"}
    ]
  end
end
```

## Runtime config sketch

```elixir
import Config

config :tet_runtime,
  store: System.get_env("TET_STORE", "sqlite"),
  workspace_root: System.get_env("TET_WORKSPACE", File.cwd!())

case System.get_env("TET_STORE", "sqlite") do
  "sqlite" ->
    config :tet_store_sqlite, Tet.Store.SQLite.Repo,
      database: Path.join([System.get_env("TET_WORKSPACE", "."), ".tet", "tet.sqlite"]),
      pool_size: 5

  "postgres" ->
    config :tet_store_postgres, Tet.Store.Postgres.Repo,
      url: System.fetch_env!("TET_DATABASE_URL")

  "memory" ->
    :ok
end
```

Do not configure `TetWeb.Endpoint` in standalone-only config paths. Web endpoint config belongs to the optional web release/app.
