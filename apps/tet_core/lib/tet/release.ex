defmodule Tet.Release do
  @moduledoc """
  Release configuration for standalone and optional web packages.

  Defines three release modes:

    * `:standalone` — CLI-only, no web dependencies
    * `:web`        — includes web app alongside CLI
    * `:full`       — everything including optional stores

  The umbrella app dependency graph (internal apps only):

      tet_core          → (none)
      tet_runtime       → tet_core
      tet_cli           → tet_core, tet_runtime
      tet_store_sqlite  → tet_core
      tet_store_memory  → tet_core
      tet_web_phoenix   → tet_core, tet_runtime
  """

  alias Tet.Release.DependencyClosure

  @standalone_apps [:tet_core, :tet_runtime, :tet_cli, :tet_store_sqlite]
  @web_apps [:tet_web_phoenix]
  @optional_apps [:tet_store_memory]

  @umbrella_dep_graph %{
    tet_core: [],
    tet_runtime: [:tet_core],
    tet_cli: [:tet_core, :tet_runtime],
    tet_store_sqlite: [:tet_core],
    tet_store_memory: [:tet_core],
    tet_web_phoenix: [:tet_core, :tet_runtime]
  }

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

  defstruct [
    :name,
    mode: :standalone,
    apps: [],
    excluded_deps: [],
    config_overrides: %{}
  ]

  # ── Type ────────────────────────────────────────────────────────────────

  @type mode :: :standalone | :web | :full
  @type t :: %__MODULE__{
          name: atom(),
          mode: mode(),
          apps: [atom()],
          excluded_deps: [atom()],
          config_overrides: map()
        }

  # ── Accessors ───────────────────────────────────────────────────────────

  @doc "Returns the list of standalone umbrella apps."
  def standalone_apps, do: @standalone_apps

  @doc "Returns the list of web umbrella apps."
  def web_apps, do: @web_apps

  @doc "Returns the list of optional umbrella apps."
  def optional_apps, do: @optional_apps

  @doc "Returns the internal umbrella dependency graph."
  def umbrella_dep_graph, do: @umbrella_dep_graph

  @doc "Returns the exact-forbidden list for standalone releases."
  def forbidden_standalone_exact, do: @forbidden_standalone_exact

  @doc "Returns the prefix-forbidden list for standalone releases."
  def forbidden_standalone_prefixes, do: @forbidden_standalone_prefixes

  # ── Constructors ────────────────────────────────────────────────────────

  @doc "Returns a standalone (CLI-only) release configuration."
  @spec standalone() :: t()
  def standalone do
    apps = apps_for(:standalone)

    %__MODULE__{
      name: :tet_standalone,
      mode: :standalone,
      apps: apps,
      excluded_deps: @web_apps ++ @optional_apps,
      config_overrides: %{}
    }
  end

  @doc "Returns a web-included release configuration."
  @spec web() :: t()
  def web do
    apps = apps_for(:web)

    %__MODULE__{
      name: :tet_web,
      mode: :web,
      apps: apps,
      excluded_deps: @optional_apps,
      config_overrides: %{}
    }
  end

  @doc "Returns a full (everything) release configuration."
  @spec full() :: t()
  def full do
    apps = apps_for(:full)

    %__MODULE__{
      name: :tet_full,
      mode: :full,
      apps: apps,
      excluded_deps: [],
      config_overrides: %{}
    }
  end

  # ── App lists per mode ──────────────────────────────────────────────────

  @doc "Returns the umbrella apps included in a given release mode."
  @spec apps_for(mode()) :: [atom()]
  def apps_for(:standalone), do: @standalone_apps
  def apps_for(:web), do: @standalone_apps ++ @web_apps
  def apps_for(:full), do: @standalone_apps ++ @web_apps ++ @optional_apps

  # ── Dependency closure ──────────────────────────────────────────────────

  @doc "Returns the full transitive dependency closure for a release mode."
  @spec deps_for(mode()) :: [atom()]
  def deps_for(mode) do
    mode
    |> apps_for()
    |> DependencyClosure.compute()
  end

  # ── Validation ──────────────────────────────────────────────────────────

  @doc "Validates a release configuration struct."
  @spec validate(t()) :: :ok | {:error, [String.t()]}
  def validate(%__MODULE__{} = config) do
    errors =
      []
      |> validate_name(config)
      |> validate_mode(config)
      |> validate_apps(config)
      |> validate_no_forbidden_in_standalone(config)

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  defp validate_name(errors, %{name: name}) when is_atom(name) and not is_nil(name), do: errors
  defp validate_name(errors, _), do: ["name must be a non-nil atom" | errors]

  defp validate_mode(errors, %{mode: mode}) when mode in [:standalone, :web, :full], do: errors
  defp validate_mode(errors, _), do: ["mode must be :standalone, :web, or :full" | errors]

  defp validate_apps(errors, %{apps: apps}) when is_list(apps) and length(apps) > 0, do: errors
  defp validate_apps(errors, _), do: ["apps must be a non-empty list" | errors]

  defp validate_no_forbidden_in_standalone(errors, %{mode: :standalone, apps: apps}) do
    leaked =
      Enum.filter(apps, fn app ->
        app in @forbidden_standalone_exact or
          Enum.any?(@forbidden_standalone_prefixes, &String.starts_with?(Atom.to_string(app), &1))
      end)

    case leaked do
      [] -> errors
      _ -> ["standalone release contains forbidden web apps: #{inspect(leaked)}" | errors]
    end
  end

  defp validate_no_forbidden_in_standalone(errors, _), do: errors

  # ── Independence verification ───────────────────────────────────────────

  @doc """
  Verifies that the standalone release does not transitively depend on
  any web apps. Delegates to `DependencyClosure.verify_no_web_in_standalone/0`.
  Returns `:ok` or `{:error, [String.t()]}`.
  """
  @spec verify_independence() :: :ok | {:error, [String.t()]}
  def verify_independence do
    DependencyClosure.verify_no_web_in_standalone()
  end
end
