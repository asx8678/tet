defmodule Tet.PlanMode.Policy do
  @moduledoc """
  Plan-mode permission policy as pure data.

  BD-0025 defines plan mode as a gate that permits read-only research tools
  while blocking write, edit, shell, and non-read execution until the active
  task category commits to acting. This policy struct captures which modes,
  categories, and tool capabilities are permitted in plan mode so the gate
  module (`Tet.PlanMode.Gate`) can make deterministic allow/block/guide
  decisions without side effects.

  ## Invariants enforced

  1. No mutating/executing tool without an active task.
  2. Category-based tool gating: researching/planning tasks are plan-safe;
     acting tasks unlock write/edit/shell.
  3. Plan mode never widens permissions — it only narrows them.

  ## Relationship to contracts

  BD-0020 tool contracts declare `read_only`, `mutation`, `modes`,
  `task_categories`, and `execution` metadata. This policy consumes those
  fields; it does not re-define tool capabilities.
  """

  alias Tet.Tool.Contract

  @plan_mode :plan
  @read_only_safe_modes [:plan, :explore]
  @plan_safe_categories [:researching, :planning]
  @acting_categories [:acting, :verifying, :debugging, :documenting]
  @all_categories @plan_safe_categories ++ @acting_categories

  @type mode :: :plan | :explore | :execute | :repair
  @type category ::
          :researching | :planning | :acting | :verifying | :debugging | :documenting

  @type t :: %__MODULE__{
          plan_mode: mode(),
          safe_modes: [mode()],
          plan_safe_categories: [category()],
          acting_categories: [category()],
          require_active_task: boolean()
        }

  @enforce_keys [:plan_mode]
  defstruct [
    :plan_mode,
    safe_modes: @read_only_safe_modes,
    plan_safe_categories: @plan_safe_categories,
    acting_categories: @acting_categories,
    require_active_task: true
  ]

  @doc "Returns the canonical plan mode atom."
  @spec plan_mode() :: mode()
  def plan_mode, do: @plan_mode

  @doc "Returns modes that permit read-only tools by default."
  @spec safe_modes() :: [mode()]
  def safe_modes, do: @read_only_safe_modes

  @doc "Returns task categories that are plan-mode safe (research/planning only)."
  @spec plan_safe_categories() :: [category()]
  def plan_safe_categories, do: @plan_safe_categories

  @doc "Returns task categories that unlock write/edit/shell tools."
  @spec acting_categories() :: [category()]
  def acting_categories, do: @acting_categories

  @doc "Returns all known task categories."
  @spec all_categories() :: [category()]
  def all_categories, do: @all_categories

  @doc "Builds a validated plan-mode policy from attributes."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, plan_mode} <- fetch_atom(attrs, :plan_mode, @plan_mode),
         {:ok, safe_modes} <- fetch_atom_list(attrs, :safe_modes, @read_only_safe_modes),
         {:ok, plan_safe_categories} <-
           fetch_atom_list(attrs, :plan_safe_categories, @plan_safe_categories),
         {:ok, acting_categories} <-
           fetch_atom_list(attrs, :acting_categories, @acting_categories),
         {:ok, require_active_task} <-
           fetch_boolean(attrs, :require_active_task, true),
         :ok <- validate_no_overlap(plan_safe_categories, acting_categories) do
      {:ok,
       %__MODULE__{
         plan_mode: plan_mode,
         safe_modes: safe_modes,
         plan_safe_categories: plan_safe_categories,
         acting_categories: acting_categories,
         require_active_task: require_active_task
       }}
    end
  end

  @doc "Builds a policy or raises."
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, policy} -> policy
      {:error, reason} -> raise ArgumentError, "invalid plan-mode policy: #{inspect(reason)}"
    end
  end

  @doc "Returns the default policy matching Phase 7 spec."
  @spec default() :: t()
  def default, do: new!(%{})

  @doc "True when the given runtime mode is a plan-safe mode."
  @spec plan_safe_mode?(t(), atom()) :: boolean()
  def plan_safe_mode?(%__MODULE__{safe_modes: safe_modes}, mode) when is_atom(mode) do
    safe_list = safe_modes || []
    mode in safe_list
  end

  @doc "True when the task category is plan-safe (researching/planning)."
  @spec plan_safe_category?(t(), atom()) :: boolean()
  def plan_safe_category?(%__MODULE__{plan_safe_categories: cats}, category)
      when is_atom(category) do
    cat_list = cats || []
    category in cat_list
  end

  @doc "True when the task category unlocks write/edit/shell."
  @spec acting_category?(t(), atom()) :: boolean()
  def acting_category?(%__MODULE__{acting_categories: cats}, category) when is_atom(category) do
    cat_list = cats || []
    category in cat_list
  end

  @doc "True when the contract is read-only and non-mutating per BD-0020."
  @spec read_only_contract?(Contract.t()) :: boolean()
  def read_only_contract?(%Contract{
        read_only: true,
        mutation: :none,
        execution: %{mutates_workspace: false, mutates_store: false, executes_code: false}
      }),
      do: true

  def read_only_contract?(%Contract{}), do: false

  @doc "True when the contract declares the given mode."
  @spec contract_allows_mode?(Contract.t(), atom()) :: boolean()
  def contract_allows_mode?(%Contract{modes: modes}, mode) when is_atom(mode) do
    mode in modes
  end

  @doc "True when the contract declares the given task category."
  @spec contract_allows_category?(Contract.t(), atom()) :: boolean()
  def contract_allows_category?(%Contract{task_categories: categories}, category)
      when is_atom(category) do
    category in categories
  end

  # -- Validators --

  defp fetch_atom(attrs, key, default) do
    case Map.get(attrs, key, default) do
      value when is_atom(value) -> {:ok, value}
      _other -> {:error, {:invalid_policy_field, key}}
    end
  end

  defp fetch_atom_list(attrs, key, default) do
    case Map.get(attrs, key, default) do
      list when is_list(list) and length(list) > 0 ->
        if Enum.all?(list, &is_atom/1) do
          {:ok, list}
        else
          {:error, {:invalid_policy_field, key}}
        end

      _other ->
        {:error, {:invalid_policy_field, key}}
    end
  end

  defp fetch_boolean(attrs, key, default) do
    case Map.get(attrs, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _other -> {:error, {:invalid_policy_field, key}}
    end
  end

  defp validate_no_overlap(plan_safe, acting) do
    overlap = MapSet.intersection(MapSet.new(plan_safe), MapSet.new(acting))

    if MapSet.size(overlap) == 0 do
      :ok
    else
      {:error, {:policy_category_overlap, MapSet.to_list(overlap)}}
    end
  end
end
