defmodule Tet.Removability do
  @moduledoc """
  Guards and queries for keeping the standalone CLI release free of web/Phoenix
  dependencies.

  The standalone release (`tet_standalone`) must never pull in web framework
  dependencies such as Phoenix, Plug, Cowboy or Bandit. This module provides
  pure functions to programmatically verify that no standalone umbrella app
  depends on those packages.

  > ⚠️ **Compile‑safe in production.** All `MixProject` lookups use
  > `Code.ensure_loaded?/1` + `apply/3` so calling `deps_for_app/1` from a
  > release (where Mix modules are absent) returns `[]` rather than raising.
  """

  @web_deps [
    :bandit,
    :cowboy,
    :cowlib,
    :phoenix,
    :phoenix_ecto,
    :phoenix_html,
    :phoenix_live_dashboard,
    :phoenix_live_view,
    :phoenix_pubsub,
    :plug,
    :plug_cowboy,
    :ranch,
    :thousand_island,
    :websock,
    :websock_adapter
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
    do: [:tet_core, :tet_runtime, :tet_cli, :tet_store_sqlite]

  @doc """
  Returns the list of web app names that are **allowed** to depend on web/Phoenix
  packages.

  At present the only web application is `:tet_web_phoenix`.
  """
  @spec web_apps() :: [atom()]
  def web_apps, do: [:tet_web_phoenix]

  @doc """
  Checks a keyword-like list of dependencies (as returned by Mix) for any
  web/Phoenix entries.

  Accepts both 2‑tuples `{app, opts}` and 3‑tuples `{app, version, opts}`.

  Returns `{:ok, []}` when no web deps are present, or
  `{:error, violations}` with a list of violating dependency atoms.

  ## Examples

      iex> Tet.Removability.check_standalone_deps([])
      {:ok, []}

      iex> Tet.Removability.check_standalone_deps([{:jason, "~> 1.0"}, {:phoenix, "~> 1.7"}])
      {:error, [:phoenix]}

      iex> Tet.Removability.check_standalone_deps([{:phoenix, "~> 1.7", only: :dev}])
      {:error, [:phoenix]}

  """
  @spec check_standalone_deps([tuple()]) :: {:ok, []} | {:error, [atom()]}
  def check_standalone_deps(deps_list) when is_list(deps_list) do
    violations =
      deps_list
      |> Enum.filter(fn
        {app, _} when is_atom(app) -> app in @web_deps
        {app, _, _} when is_atom(app) -> app in @web_deps
        _ -> false
      end)
      |> Enum.map(&elem(&1, 0))

    if violations == [], do: {:ok, []}, else: {:error, violations}
  end

  @doc """
  Checks that `app` does **not** have a compile-time dependency on `target_app`.

  Reads the app's `MixProject` module configuration (loaded at compile time
  in the umbrella) to inspect its dependency list. Returns `true` when
  `target_app` is absent from the deps, `false` otherwise.

  Uses `Code.ensure_loaded?/1` so it never crashes when MixProject modules
  are unavailable (e.g. in a release or after deleting an optional web app).

  ## Examples

      iex> Tet.Removability.check_no_compile_dependency(:tet_core, :phoenix)
      true

      iex> Tet.Removability.check_no_compile_dependency(:tet_core, :tet_runtime)
      true

  """
  @spec check_no_compile_dependency(atom(), atom()) :: boolean()
  def check_no_compile_dependency(app, target_app) when is_atom(app) and is_atom(target_app) do
    deps = deps_for_app(app)
    not Enum.any?(deps, &dep_matches?(&1, target_app))
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @doc false
  def deps_for_app(:tet_core),
    do: safe_mix_project_deps(TetCore.MixProject)

  @doc false
  def deps_for_app(:tet_cli),
    do: safe_mix_project_deps(TetCLI.MixProject)

  @doc false
  def deps_for_app(:tet_runtime),
    do: safe_mix_project_deps(TetRuntime.MixProject)

  @doc false
  def deps_for_app(:tet_store_memory),
    do: safe_mix_project_deps(TetStoreMemory.MixProject)

  @doc false
  def deps_for_app(:tet_store_sqlite),
    do: safe_mix_project_deps(TetStoreSQLite.MixProject)

  @doc false
  def deps_for_app(:tet_web_phoenix),
    do: safe_mix_project_deps(TetWebPhoenix.MixProject)

  @doc false
  def deps_for_app(_unknown), do: []

  # Dynamically load a MixProject module and return its :deps (or []).
  # Never raises — returns [] when the module is absent or doesn't export
  # `project/0`.
  defp safe_mix_project_deps(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :project, 0) do
      apply(module, :project, [])[:deps] || []
    else
      []
    end
  end

  # Matches a dependency tuple against a target atom.
  defp dep_matches?({name, _opts}, target), do: name == target
  defp dep_matches?({name, _, _opts}, target), do: name == target
end
