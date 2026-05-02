defmodule Tet.Removability do
  @moduledoc """
  Guards and queries for keeping the standalone CLI release free of web/Phoenix
  dependencies.

  The standalone release (`tet_standalone`) must never pull in web framework
  dependencies such as Phoenix, Plug, Cowboy or Bandit. This module provides
  pure functions to programmatically verify that no standalone umbrella app
  depends on those packages.
  """

  @web_deps [
    :phoenix,
    :phoenix_html,
    :phoenix_live_view,
    :phoenix_live_dashboard,
    :phoenix_ecto,
    :plug_cowboy,
    :bandit
  ]

  @doc """
  Returns the list of web/Phoenix dependency names that must never appear
  in standalone (non-web) apps.
  """
  @spec web_deps() :: [atom()]
  def web_deps, do: @web_deps

  @doc """
  Returns the list of app names that belong to the standalone (non-web) release.

  These apps must never declare a dependency on any of the `web_deps/0` packages.
  """
  @spec standalone_apps() :: [atom()]
  def standalone_apps,
    do: [:tet_core, :tet_runtime, :tet_cli, :tet_store_memory, :tet_store_sqlite]

  @doc """
  Returns the list of web app names that are **allowed** to depend on web/Phoenix
  packages.

  At present the only web application is `:tet_web_phoenix`.
  """
  @spec web_apps() :: [atom()]
  def web_apps, do: [:tet_web_phoenix]

  @doc """
  Checks a keyword list of dependencies (as returned by Mix) for any
  web/Phoenix entries.

  Returns `{:ok, []}` when no web deps are present, or
  `{:error, violations}` with a list of violating dependency atoms.

  ## Examples

      iex> Tet.Removability.check_standalone_deps([])
      {:ok, []}

      iex> Tet.Removability.check_standalone_deps([{:jason, "~> 1.0"}, {:phoenix, "~> 1.7"}])
      {:error, [:phoenix]}

  """
  @spec check_standalone_deps([{atom(), keyword()}]) :: {:ok, []} | {:error, [atom()]}
  def check_standalone_deps(deps_list) when is_list(deps_list) do
    violations =
      deps_list
      |> Enum.filter(fn
        {app, _opts} when is_atom(app) -> app in @web_deps
        _ -> false
      end)
      |> Enum.map(fn {app, _opts} -> app end)

    if violations == [], do: {:ok, []}, else: {:error, violations}
  end

  @doc """
  Checks that `app` does **not** have a compile-time dependency on `target_app`.

  Reads the app's `MixProject` module configuration (loaded at compile time
  in the umbrella) to inspect its dependency list. Returns `true` when
  `target_app` is absent from the deps, `false` otherwise.

  ## Examples

      iex> Tet.Removability.check_no_compile_dependency(:tet_core, :phoenix)
      true

      iex> Tet.Removability.check_no_compile_dependency(:tet_core, :tet_runtime)
      true

  """
  @spec check_no_compile_dependency(atom(), atom()) :: boolean()
  def check_no_compile_dependency(app, target_app) when is_atom(app) and is_atom(target_app) do
    deps = deps_for_app(app)
    not Enum.any?(deps, fn {dep_name, _opts} -> dep_name == target_app end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @doc false
  def deps_for_app(:tet_core), do: TetCore.MixProject.project()[:deps] || []

  @doc false
  def deps_for_app(:tet_cli), do: TetCLI.MixProject.project()[:deps] || []

  @doc false
  def deps_for_app(:tet_runtime), do: TetRuntime.MixProject.project()[:deps] || []

  @doc false
  def deps_for_app(:tet_store_memory), do: TetStoreMemory.MixProject.project()[:deps] || []

  @doc false
  def deps_for_app(:tet_store_sqlite), do: TetStoreSQLite.MixProject.project()[:deps] || []

  @doc false
  def deps_for_app(:tet_web_phoenix), do: TetWebPhoenix.MixProject.project()[:deps] || []

  @doc false
  def deps_for_app(_unknown), do: []
end
