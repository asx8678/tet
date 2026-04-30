defmodule Tet.PlanMode do
  @moduledoc """
  Plan-mode gate facade owned by `tet_core`.

  BD-0025 introduces plan-mode gates that permit read-only research tools while
  blocking write, edit, shell, and non-read execution until task commitment.
  This facade composes the policy and gate modules into a single public API
  surface for the rest of the umbrella.

  ## What this module does

  - Provides default policy and gate evaluation.
  - Exposes the full read-only contract catalog evaluated against plan-mode policy.
  - Keeps the gate pure and side-effect-free: no filesystem, no shell, no GenServer.

  ## What this module does NOT do

  - Dispatch tool execution.
  - Persist blocked-attempt events (future BD-0022/BD-0026 concern).
  - Run hooks (future BD-0024 concern).
  - LLM steering (future BD-0029 concern).
  """

  alias Tet.PlanMode.{Gate, Policy}
  alias Tet.Tool.Contract

  @doc "Returns the default plan-mode policy."
  @spec default_policy() :: Policy.t()
  def default_policy, do: Policy.default()

  @doc "Evaluates a tool contract against the default plan-mode policy and context."
  @spec evaluate(Contract.t(), Gate.gate_context()) :: Gate.decision()
  def evaluate(%Contract{} = contract, %{} = context) do
    Gate.evaluate(contract, Policy.default(), context)
  end

  @doc "Evaluates a tool contract against a given policy and context."
  @spec evaluate(Contract.t(), Policy.t(), Gate.gate_context()) :: Gate.decision()
  def evaluate(%Contract{} = contract, %Policy{} = policy, %{} = context) do
    Gate.evaluate(contract, policy, context)
  end

  @doc """
  Evaluates all read-only contracts against plan-mode policy and context.

  Returns `{allowed, blocked}` where each list contains `{name, decision}` tuples.
  """
  @spec evaluate_read_only_catalog(Policy.t(), Gate.gate_context()) ::
          {allowed :: [{binary(), Gate.decision()}], blocked :: [{binary(), Gate.decision()}]}
  def evaluate_read_only_catalog(%Policy{} = policy, %{} = context) do
    contracts = Tet.Tool.read_only_contracts()
    results = Gate.evaluate_all(contracts, policy, context)

    Enum.split_with(results, fn {_name, decision} -> Gate.allowed?(decision) end)
  end

  @doc "True when the gate decision permits the tool call."
  @spec allowed?(Gate.decision()) :: boolean()
  defdelegate allowed?(decision), to: Gate

  @doc "True when the gate decision blocks the tool call."
  @spec blocked?(Gate.decision()) :: boolean()
  defdelegate blocked?(decision), to: Gate

  @doc "True when the gate decision is a guidance hint."
  defdelegate guided?(decision), to: Gate
end
