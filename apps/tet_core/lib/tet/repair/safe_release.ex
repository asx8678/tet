defmodule Tet.Repair.SafeRelease do
  @moduledoc """
  Configuration and validation for the minimal safe repair release — BD-0063.

  A safe release is a stripped-down configuration that can diagnose, patch,
  compile, smoke-test, and hand off control independently — even when the
  main CLI cannot boot. This module defines the release struct and
  pure-function validators.

  ## Repair pipeline

  The release drives an ordered pipeline defined in
  `Tet.Repair.SafeRelease.Pipeline`. Which pipeline steps are active depends
  on the release's `:capabilities`.

  ## Modes

    - `:standalone` — runs independently, no main release needed
    - `:embedded`   — embedded inside the main release
    - `:fallback`   — emergency fallback when main release fails (default)

  This module is pure data and pure functions. It does not execute repairs,
  touch the filesystem, or persist events.
  """

  alias Tet.Entity
  alias Tet.Repair.SafeRelease.Pipeline

  @modes [:standalone, :embedded, :fallback]
  @valid_capabilities [:diagnose, :patch, :compile, :smoke, :handoff]
  @valid_restricted_tools [:read, :search, :list, :patch, :compile]
  @valid_handoff_strategies [:graceful, :force, :manual]
  @required_capabilities [:diagnose, :handoff]

  # Pipeline steps that don't require explicit capabilities.
  @infrastructure_steps [:plan, :approve, :checkpoint]

  @enforce_keys [:id]
  defstruct [
    :id,
    mode: :fallback,
    capabilities: @valid_capabilities,
    restricted_tools: @valid_restricted_tools,
    excluded_deps: [],
    health_check_interval: 5_000,
    max_repair_attempts: 3,
    handoff_strategy: :graceful
  ]

  @type release_mode :: :standalone | :embedded | :fallback
  @type capability :: :diagnose | :patch | :compile | :smoke | :handoff
  @type restricted_tool :: :read | :search | :list | :patch | :compile
  @type handoff_strategy :: :graceful | :force | :manual

  @type t :: %__MODULE__{
          id: binary(),
          mode: release_mode(),
          capabilities: [capability()],
          restricted_tools: [restricted_tool()],
          excluded_deps: [atom()],
          health_check_interval: pos_integer(),
          max_repair_attempts: pos_integer(),
          handoff_strategy: handoff_strategy()
        }

  @doc "Returns valid release modes."
  @spec modes() :: [release_mode()]
  def modes, do: @modes

  @doc "Returns valid capabilities."
  @spec valid_capabilities() :: [capability()]
  def valid_capabilities, do: @valid_capabilities

  @doc "Returns valid restricted tools."
  @spec valid_restricted_tools() :: [restricted_tool()]
  def valid_restricted_tools, do: @valid_restricted_tools

  @doc "Returns valid handoff strategies."
  @spec valid_handoff_strategies() :: [handoff_strategy()]
  def valid_handoff_strategies, do: @valid_handoff_strategies

  @doc """
  Creates a validated safe release configuration from attributes.

  Only `:id` is required — all other fields have sensible defaults.
  Supports both atom and string keyed maps.

  Returns `{:ok, %SafeRelease{}}` or `{:error, reason}`.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- Entity.fetch_required_binary(attrs, :id, :safe_release),
         {:ok, mode} <- fetch_mode(attrs),
         {:ok, capabilities} <- fetch_capabilities(attrs),
         {:ok, restricted_tools} <- fetch_restricted_tools(attrs),
         {:ok, excluded_deps} <- fetch_excluded_deps(attrs),
         {:ok, interval} <- fetch_pos_integer(attrs, :health_check_interval, 5_000),
         {:ok, attempts} <- fetch_pos_integer(attrs, :max_repair_attempts, 3),
         {:ok, handoff} <- fetch_handoff_strategy(attrs) do
      {:ok,
       %__MODULE__{
         id: id,
         mode: mode,
         capabilities: capabilities,
         restricted_tools: restricted_tools,
         excluded_deps: excluded_deps,
         health_check_interval: interval,
         max_repair_attempts: attempts,
         handoff_strategy: handoff
       }}
    end
  end

  def new(_), do: {:error, :invalid_safe_release}

  @doc """
  Validates that a release configuration is safe and complete.

  Checks required capabilities are present, field values sit within their
  allowed ranges, and the configuration is internally consistent. Useful
  as a safety-net for structs that were mutated after construction.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = release) do
    cond do
      not is_binary(release.id) or release.id == "" ->
        {:error, {:invalid_safe_release_field, :id}}

      release.mode not in @modes ->
        {:error, {:invalid_safe_release_field, :mode}}

      not valid_list?(release.capabilities, @valid_capabilities) ->
        {:error, {:invalid_safe_release_field, :capabilities}}

      not Enum.all?(@required_capabilities, &(&1 in release.capabilities)) ->
        missing = @required_capabilities -- release.capabilities
        {:error, {:missing_required_capabilities, missing}}

      not valid_list?(release.restricted_tools, @valid_restricted_tools) ->
        {:error, {:invalid_safe_release_field, :restricted_tools}}

      not is_list(release.excluded_deps) or not Enum.all?(release.excluded_deps, &is_atom/1) ->
        {:error, {:invalid_safe_release_field, :excluded_deps}}

      not is_integer(release.health_check_interval) or release.health_check_interval < 1 ->
        {:error, {:invalid_safe_release_field, :health_check_interval}}

      not is_integer(release.max_repair_attempts) or release.max_repair_attempts < 1 ->
        {:error, {:invalid_safe_release_field, :max_repair_attempts}}

      release.handoff_strategy not in @valid_handoff_strategies ->
        {:error, {:invalid_safe_release_field, :handoff_strategy}}

      true ->
        :ok
    end
  end

  def validate(_), do: {:error, :invalid_safe_release}

  @doc """
  Checks if the minimal requirements are met for a repair boot.

  A release can boot when it has a valid mode, the `:diagnose` capability,
  and at least one repair attempt available.
  """
  @spec can_boot?(t()) :: boolean()
  def can_boot?(%__MODULE__{} = release) do
    release.mode in @modes and
      :diagnose in release.capabilities and
      release.max_repair_attempts >= 1
  end

  @doc """
  Checks whether a specific capability is enabled in the release.
  """
  @spec capability_available?(t(), capability()) :: boolean()
  def capability_available?(%__MODULE__{capabilities: capabilities}, capability) do
    capability in capabilities
  end

  @doc """
  Returns the ordered repair pipeline steps available in this release.

  Infrastructure steps (`:plan`, `:approve`, `:checkpoint`) are always
  included. Capability-gated steps are included only when the matching
  capability is present.
  """
  @spec pipeline(t()) :: [Pipeline.step()]
  def pipeline(%__MODULE__{capabilities: capabilities}) do
    Enum.filter(Pipeline.steps(), fn step ->
      step in @infrastructure_steps or step in capabilities
    end)
  end

  @doc """
  Checks whether the release is configured for handoff to the main release.

  Requires both `:handoff` and `:diagnose` capabilities and a valid
  handoff strategy.
  """
  @spec handoff_ready?(t()) :: boolean()
  def handoff_ready?(%__MODULE__{} = release) do
    :handoff in release.capabilities and
      :diagnose in release.capabilities and
      release.handoff_strategy in @valid_handoff_strategies
  end

  # -- Private helpers --

  defp fetch_mode(attrs) do
    case Entity.fetch_value(attrs, :mode, :fallback) do
      mode when mode in @modes ->
        {:ok, mode}

      mode when is_binary(mode) ->
        parse_enum(mode, @modes, :mode)

      _ ->
        {:error, {:invalid_safe_release_field, :mode}}
    end
  end

  defp fetch_capabilities(attrs) do
    case Entity.fetch_value(attrs, :capabilities, @valid_capabilities) do
      caps when is_list(caps) ->
        if Enum.all?(caps, &(&1 in @valid_capabilities)),
          do: {:ok, caps},
          else: {:error, {:invalid_safe_release_field, :capabilities}}

      _ ->
        {:error, {:invalid_safe_release_field, :capabilities}}
    end
  end

  defp fetch_restricted_tools(attrs) do
    case Entity.fetch_value(attrs, :restricted_tools, @valid_restricted_tools) do
      tools when is_list(tools) ->
        if Enum.all?(tools, &(&1 in @valid_restricted_tools)),
          do: {:ok, tools},
          else: {:error, {:invalid_safe_release_field, :restricted_tools}}

      _ ->
        {:error, {:invalid_safe_release_field, :restricted_tools}}
    end
  end

  defp fetch_excluded_deps(attrs) do
    case Entity.fetch_value(attrs, :excluded_deps, []) do
      deps when is_list(deps) ->
        if Enum.all?(deps, &is_atom/1),
          do: {:ok, deps},
          else: {:error, {:invalid_safe_release_field, :excluded_deps}}

      _ ->
        {:error, {:invalid_safe_release_field, :excluded_deps}}
    end
  end

  defp fetch_pos_integer(attrs, key, default) do
    case Entity.fetch_value(attrs, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_safe_release_field, key}}
    end
  end

  defp fetch_handoff_strategy(attrs) do
    case Entity.fetch_value(attrs, :handoff_strategy, :graceful) do
      strategy when strategy in @valid_handoff_strategies ->
        {:ok, strategy}

      strategy when is_binary(strategy) ->
        parse_enum(strategy, @valid_handoff_strategies, :handoff_strategy)

      _ ->
        {:error, {:invalid_safe_release_field, :handoff_strategy}}
    end
  end

  defp parse_enum(str, allowed, field) when is_binary(str) do
    case Enum.find(allowed, &(Atom.to_string(&1) == str)) do
      nil -> {:error, {:invalid_safe_release_field, field}}
      atom -> {:ok, atom}
    end
  end

  defp valid_list?(values, allowed) when is_list(values) do
    Enum.all?(values, &(&1 in allowed))
  end

  defp valid_list?(_values, _allowed), do: false
end
