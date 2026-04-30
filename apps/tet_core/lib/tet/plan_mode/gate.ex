defmodule Tet.PlanMode.Gate do
  @moduledoc """
  Deterministic plan-mode gate for tool-call authorization.

  BD-0025 requires that plan mode permits read-only research tools while
  blocking write, edit, shell, and non-read execution until task commitment
  (i.e., until the active task category transitions from researching/planning
  to acting).

  This module is a set of pure functions. It does not dispatch tools, touch
  the filesystem, shell out, persist events, or ask a terminal question. It
  consumes `Tet.Tool.Contract` structs from BD-0020 and `Tet.PlanMode.Policy`
  data to return one of three gate decisions:

    - `:allow` — the tool call may proceed.
    - `{:block, reason}` — the tool call is denied; `reason` is a stable atom.
    - `{:guide, message}` — the tool call is allowed with a guidance hint.

  ## Decision flow

  1. If no active task is present and the policy requires one: `{:block, :no_active_task}`.
  2. If the runtime mode is plan-safe and the contract is read-only: `:allow`.
  3. If the runtime mode is plan-safe and the contract is NOT read-only: `{:block, :plan_mode_blocks_mutation}`.
  4. If the runtime mode is NOT plan-safe (e.g., :execute) and the contract is read-only: `:allow`.
  5. If the runtime mode is NOT plan-safe and the task category is acting: `:allow`.
  6. Otherwise: `{:block, :category_blocks_tool}`.

  This decision flow enforces the invariant: planning cannot mutate or execute
  non-read tools. Once a task commits to acting, the gate opens for mutating
  tools (future BD-0027+ contracts).

  ## Relationship to other modules

  - `Tet.Tool.Contract` (BD-0020): provides `read_only`, `mutation`, `modes`,
    `task_categories`, and `execution` metadata consumed by this gate.
  - `Tet.Tool.ReadOnlyContracts` (BD-0020): the read-only contract catalog.
  - `Tet.PlanMode.Policy`: the policy data this gate uses for mode/category
    decisions.
  - Future `Tet.HookManager` (BD-0024): will run hooks after this gate passes.
  - Future `Tet.PlanMode` facade: will compose this gate with hooks and events.
  """

  alias Tet.PlanMode.Policy
  alias Tet.Tool.Contract

  @type decision :: :allow | {:block, atom()} | {:guide, binary()}
  @type gate_context :: %{
          required(:mode) => atom(),
          optional(:task_category) => atom() | nil,
          optional(:task_id) => binary() | nil
        }

  @doc """
  Evaluates whether a tool contract is permitted under plan-mode policy.

  Returns `:allow`, `{:block, reason}`, or `{:guide, message}`.

  ## Examples

      iex> gate = Tet.PlanMode.Gate
      iex> policy = Tet.PlanMode.Policy.default()
      iex> {:ok, contract} = Tet.Tool.ReadOnlyContracts.fetch("read")
      iex> ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      iex> gate.evaluate(contract, policy, ctx)
      :allow

      iex> # A hypothetical mutating contract would be blocked in plan mode
      iex> gate.evaluate(mutating_contract, policy, %{mode: :plan, task_category: :researching, task_id: "t1"})
      {:block, :plan_mode_blocks_mutation}
  """
  @spec evaluate(Contract.t(), Policy.t(), gate_context()) :: decision()
  def evaluate(%Contract{} = contract, %Policy{} = policy, %{} = context) do
    with :ok <- check_active_task(policy, context),
         :ok <- check_contract_mode(contract, context),
         :ok <- check_plan_mode_gate(contract, policy, context),
         :ok <- check_category_gate(contract, policy, context) do
      maybe_guide(contract, policy, context)
    end
  end

  # -- Gate checks (ordered) --

  # Invariant 1: No mutating/executing tool without an active task.
  # Fail closed: omitted, nil, empty, or non-binary task_id and omitted, nil,
  # or non-atom task_category all block deterministically — never crash.
  defp check_active_task(%Policy{require_active_task: true}, context) do
    task_id = Map.get(context, :task_id)
    task_category = Map.get(context, :task_category)

    cond do
      not valid_active_task_id?(task_id) -> {:block, :no_active_task}
      not valid_active_task_category?(task_category) -> {:block, :no_active_task}
      true -> :ok
    end
  end

  defp check_active_task(_policy, _context), do: :ok

  defp valid_active_task_id?(id) when is_binary(id) and byte_size(id) > 0, do: true
  defp valid_active_task_id?(_), do: false

  defp valid_active_task_category?(cat) when is_atom(cat) and not is_nil(cat), do: true
  defp valid_active_task_category?(_), do: false

  # The contract must declare the current mode.
  # Unknown tools that don't declare the mode are blocked.
  # Malformed contexts (missing/non-atom :mode) are rejected
  # deterministically rather than crashing on pattern match.
  defp check_contract_mode(%Contract{modes: modes}, context) do
    mode = Map.get(context, :mode)

    cond do
      is_nil(mode) -> {:block, :invalid_context}
      not is_atom(mode) -> {:block, :invalid_context}
      mode in modes -> :ok
      true -> {:block, :mode_not_allowed}
    end
  end

  # Plan-mode gate: plan/explore modes only permit read-only contracts.
  # Uses Map.get for crash-safe context access.
  defp check_plan_mode_gate(contract, policy, context) do
    mode = Map.get(context, :mode)

    cond do
      is_nil(mode) ->
        {:block, :invalid_context}

      not is_atom(mode) ->
        {:block, :invalid_context}

      Policy.plan_safe_mode?(policy, mode) ->
        if Policy.read_only_contract?(contract) do
          :ok
        else
          {:block, :plan_mode_blocks_mutation}
        end

      true ->
        # Non-plan modes (execute, repair) pass this check;
        # category gate handles the rest.
        :ok
    end
  end

  # Category gate: the runtime task category must be both policy-allowed
  # and contract-declared. Policy.plan_safe_category?/acting_category? checks
  # policy rules; Policy.contract_allows_category?/2 enforces the contract's
  # own task_categories declaration as an *independent* prerequisite — even
  # read-only contracts must declare the runtime category before the
  # read-only allow/guidance shortcut applies.
  defp check_category_gate(contract, policy, context) do
    mode = Map.get(context, :mode)
    category = Map.get(context, :task_category)

    cond do
      is_nil(mode) or not is_atom(mode) ->
        {:block, :invalid_context}

      is_nil(category) or not is_atom(category) ->
        {:block, :invalid_context}

      not Policy.contract_allows_category?(contract, category) ->
        # Contract does not declare this category — block regardless
        # of read-only status. This is the independent prerequisite.
        {:block, :category_blocks_tool}

      Policy.plan_safe_mode?(policy, mode) ->
        # Plan-safe modes already passed check_plan_mode_gate.
        if Policy.plan_safe_category?(policy, category) do
          :ok
        else
          # e.g., :plan mode with :acting category — the task has committed
          # but the mode hasn't transitioned yet. Block mutating intent.
          # Read-only contracts that already declared the category may
          # still proceed (they passed the plan-mode gate above).
          if Policy.read_only_contract?(contract) do
            :ok
          else
            {:block, :category_blocks_tool}
          end
        end

      true ->
        # Non-plan modes: acting categories unlock mutating tools
        # (contract already declared the category per prerequisite above).
        if Policy.acting_category?(policy, category) do
          :ok
        else
          # Read-only shortcut applies only when contract declared the category.
          if Policy.read_only_contract?(contract) do
            :ok
          else
            {:block, :category_blocks_tool}
          end
        end
    end
  end

  # After allow, optionally attach guidance for plan-mode read-only calls.
  # Defensive: guard against nil mode/category even though upstream checks
  # should reject them — never crash in a decision path.
  defp maybe_guide(%Contract{} = contract, %Policy{} = policy, %{} = context) do
    mode = Map.get(context, :mode)
    category = Map.get(context, :task_category)

    cond do
      is_atom(mode) and not is_nil(mode) and
        is_atom(category) and not is_nil(category) and
        Policy.plan_safe_mode?(policy, mode) and
        Policy.plan_safe_category?(policy, category) and
          Policy.read_only_contract?(contract) ->
        {:guide, "Plan-mode research allowed. Commit to acting to unlock write/edit/shell tools."}

      true ->
        :allow
    end
  end

  @doc """
  Batch-evaluates a list of tool contracts against policy and context.

  Returns a list of `{contract_name, decision}` tuples in input order.
  Useful for testing the full catalog against plan-mode policy.
  """
  @spec evaluate_all([Contract.t()], Policy.t(), gate_context()) ::
          [{binary(), decision()}]
  def evaluate_all(contracts, %Policy{} = policy, %{} = context) when is_list(contracts) do
    Enum.map(contracts, fn %Contract{name: name} = contract ->
      {name, evaluate(contract, policy, context)}
    end)
  end

  @doc """
  Returns true when the gate decision is `:allow` or `{:guide, _}`.
  """
  @spec allowed?(decision()) :: boolean()
  def allowed?(:allow), do: true
  def allowed?({:guide, _}), do: true
  def allowed?({:block, _}), do: false

  @doc """
  Returns true when the gate decision blocks the tool call.
  """
  @spec blocked?(decision()) :: boolean()
  def blocked?({:block, _}), do: true
  def blocked?(_), do: false

  @doc """
  Returns true when the gate decision is a guidance hint.
  """
  @spec guided?(decision()) :: boolean()
  def guided?({:guide, _}), do: true
  def guided?(_), do: false
end
