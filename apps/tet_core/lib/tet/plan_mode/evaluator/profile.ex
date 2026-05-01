defmodule Tet.PlanMode.Evaluator.Profile do
  @moduledoc """
  Configurable evaluation criteria for the Ring-2 steering evaluator.

  BD-0032 introduces a lightweight evaluator that runs AFTER deterministic
  gate checks (Ring-1). The profile controls how aggressively the evaluator
  adds guidance or narrows scope for allowed operations. It NEVER overrides
  a block — that invariant belongs to `Tet.PlanMode.Evaluator`.

  ## Fields

    - `aggressiveness` — how eagerly the evaluator adds guidance/focus.
      `:conservative` (minimal hints), `:moderate` (default), `:aggressive`
      (rich guidance, tight focus). Higher aggressiveness = more steering,
      but still never overrides blocks.
    - `focus_areas` — list of atoms naming areas the evaluator should
      narrow (e.g., `[:file_safety, :scope_narrowing]`). Empty list means
      no focus narrowing.
    - `risk_tolerance` — `:low` (extra cautious guidance), `:medium`
      (default), `:high` (permissive, fewer warnings).

  ## Invariants

  1. Aggressiveness and risk_tolerance must be valid atoms.
  2. Focus areas must be a non-empty list of atoms (or empty for none).
  3. Profile never affects block propagation — that's the evaluator's job.

  ## Relationship to other modules

  - `Tet.PlanMode.Evaluator`: consumes this profile to steer allowed
    operations after the gate has spoken.
  - `Tet.PlanMode.Gate` (BD-0025): produces the gate_result that the
    evaluator consumes.
  - `Tet.PlanMode.Policy` (BD-0025): category/mode definitions used by
    the evaluator for context-aware guidance.
  """


  @aggressiveness_levels [:conservative, :moderate, :aggressive]
  @risk_levels [:low, :medium, :high]
  @known_focus_areas [:file_safety, :scope_narrowing, :test_first, :minimal_mutations]

  @type aggressiveness :: :conservative | :moderate | :aggressive
  @type risk_tolerance :: :low | :medium | :high
  @type focus_area :: atom()

  @type t :: %__MODULE__{
          aggressiveness: aggressiveness(),
          focus_areas: [focus_area()],
          risk_tolerance: risk_tolerance()
        }

  @enforce_keys []
  defstruct aggressiveness: :moderate,
            focus_areas: [],
            risk_tolerance: :medium

  @doc "Returns valid aggressiveness levels."
  @spec aggressiveness_levels() :: [aggressiveness()]
  def aggressiveness_levels, do: @aggressiveness_levels

  @doc "Returns valid risk tolerance levels."
  @spec risk_levels() :: [risk_tolerance()]
  def risk_levels, do: @risk_levels

  @doc "Returns known focus area atoms (non-exhaustive; custom atoms allowed)."
  @spec known_focus_areas() :: [focus_area()]
  def known_focus_areas, do: @known_focus_areas

  @doc "Builds a validated evaluator profile from attributes."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, aggressiveness} <- fetch_aggressiveness(attrs),
         {:ok, focus_areas} <- fetch_focus_areas(attrs),
         {:ok, risk_tolerance} <- fetch_risk_tolerance(attrs) do
      {:ok,
       %__MODULE__{
         aggressiveness: aggressiveness,
         focus_areas: focus_areas,
         risk_tolerance: risk_tolerance
       }}
    end
  end

  @doc "Builds a profile or raises."
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, profile} -> profile
      {:error, reason} -> raise ArgumentError, "invalid evaluator profile: #{inspect(reason)}"
    end
  end

  @doc "Returns the default profile (moderate aggressiveness, medium risk, no focus)."
  @spec default() :: t()
  def default, do: new!(%{})

  @doc "Returns a conservative profile (low risk, conservative guidance)."
  @spec conservative() :: t()
  def conservative, do: new!(%{aggressiveness: :conservative, risk_tolerance: :low})

  @doc "Returns an aggressive profile (aggressive guidance, high risk tolerance)."
  @spec aggressive() :: t()
  def aggressive, do: new!(%{aggressiveness: :aggressive, risk_tolerance: :high})

  @doc "True when the profile has focus areas that narrow scope."
  @spec has_focus?(t()) :: boolean()
  def has_focus?(%__MODULE__{focus_areas: []}), do: false
  def has_focus?(%__MODULE__{focus_areas: [_ | _]}), do: true

  @doc "True when aggressiveness is at or above the given level."
  @spec aggressiveness_at_least?(t(), aggressiveness()) :: boolean()
  def aggressiveness_at_least?(%__MODULE__{aggressiveness: level}, level), do: true

  def aggressiveness_at_least?(%__MODULE__{aggressiveness: :aggressive}, _min), do: true
  def aggressiveness_at_least?(%__MODULE__{aggressiveness: :moderate}, :conservative), do: true
  def aggressiveness_at_least?(_, _), do: false

  @doc "True when risk tolerance is at or above the given level."
  @spec risk_at_least?(t(), risk_tolerance()) :: boolean()
  def risk_at_least?(%__MODULE__{risk_tolerance: level}, level), do: true

  def risk_at_least?(%__MODULE__{risk_tolerance: :high}, _min), do: true
  def risk_at_least?(%__MODULE__{risk_tolerance: :medium}, :low), do: true
  def risk_at_least?(_, _), do: false

  # -- Validators --

  defp fetch_aggressiveness(attrs) do
    case Map.get(attrs, :aggressiveness, :moderate) do
      level when level in @aggressiveness_levels -> {:ok, level}
      other -> {:error, {:invalid_profile_field, {:aggressiveness, other}}}
    end
  end

  defp fetch_focus_areas(attrs) do
    case Map.get(attrs, :focus_areas, []) do
      list when is_list(list) ->
        if Enum.all?(list, &is_atom/1) do
          {:ok, list}
        else
          {:error, {:invalid_profile_field, {:focus_areas, :not_all_atoms}}}
        end

      other ->
        {:error, {:invalid_profile_field, {:focus_areas, other}}}
    end
  end

  defp fetch_risk_tolerance(attrs) do
    case Map.get(attrs, :risk_tolerance, :medium) do
      level when level in @risk_levels -> {:ok, level}
      other -> {:error, {:invalid_profile_field, {:risk_tolerance, other}}}
    end
  end
end
