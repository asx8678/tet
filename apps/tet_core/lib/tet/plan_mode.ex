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
  - LLM steering beyond what `steer/3` provides (future BD-0029 concern).

  ## Hook integration (BD-0024)

  `evaluate_with_hooks/4` composes the deterministic gate with the hook
  lifecycle. Pre-hooks execute before gate evaluation (can modify context
  or block), and post-hooks execute after the gate decides (can add
  guidance or veto allowed operations). Gate blocks are final — hooks
  cannot override them.
  """

  alias Tet.PlanMode.{Evaluator, Gate, Policy}
  alias Tet.PlanMode.Evaluator.Profile
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

  # ── Ring-2 Steering Evaluator (BD-0032) ──────────────────────────

  @doc "Returns the default evaluator profile."
  @spec default_evaluator_profile() :: Profile.t()
  def default_evaluator_profile, do: Profile.default()

  @doc """
  Evaluates a gate decision through the Ring-2 steering evaluator.

  Returns `{:ok, final_decision, audit_entry}`. Blocks are never
  overridden — they pass through unchanged.
  """
  @spec steer(Gate.decision(), Profile.t(), map()) ::
          {:ok, Gate.decision(), Evaluator.audit_entry()}
  def steer(gate_decision, %Profile{} = profile, %{} = context) do
    Evaluator.evaluate(gate_decision, profile, context)
  end

  @doc """
  Full evaluation pipeline: gate → evaluator → final decision.

  Runs the deterministic gate (Ring-1) first, then passes the result
  through the steering evaluator (Ring-2) with the given profile.
  """
  @spec evaluate_and_steer(Contract.t(), Policy.t(), Gate.gate_context(), Profile.t()) ::
          {:ok, Gate.decision(), Evaluator.audit_entry()}
  def evaluate_and_steer(
        %Contract{} = contract,
        %Policy{} = policy,
        %{} = context,
        %Profile{} = profile
      ) do
    gate_decision = Gate.evaluate(contract, policy, context)
    Evaluator.evaluate(gate_decision, profile, context)
  end

  @doc """
  Verifies the no-override guarantee for a list of block decisions.

  Returns `:ok` if all blocks are preserved, or `{:violated, details}`.
  """
  @spec verify_no_override([Gate.decision()], Profile.t(), map()) ::
          :ok | {:violated, [Gate.decision()]}
  defdelegate verify_no_override(decisions, profile, context), to: Evaluator

  # ── Hook Lifecycle Integration (BD-0024) ────────────────────────

  @type hook_result ::
          {:ok, Gate.decision(), map(), [binary()]} | {:block, term(), map()}

  @doc """
  Evaluates a tool contract with full hook lifecycle integration.

  Pipeline: pre-hooks → gate → post-hooks

  1. **Pre-hooks** execute in descending priority order. They can enrich
     the context (`{:modify, ctx}`), emit guidance (`{:guide, msg, ctx}`),
     or veto the operation (`:block`). If a pre-hook blocks, the gate
     never runs.

  2. **Gate** evaluates the (possibly enriched) context against the
     contract and policy. If the gate blocks, the decision is final —
     post-hooks do not run and cannot override it (no-override invariant).

  3. **Post-hooks** execute in ascending priority order on allowed or
     guided decisions. They can add guidance or veto (`:block`).

  Returns `{:ok, gate_decision, final_context, guides}` on success,
  or `{:block, reason, context}` when a hook or gate blocks.

  ## Examples

      iex> registry = Tet.HookManager.new()
      iex> ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      iex> {:ok, decision, _ctx, _guides} =
      ...>   Tet.PlanMode.evaluate_with_hooks(read_contract(), Policy.default(), ctx, registry)
      iex> Tet.PlanMode.allowed?(decision)
      true
  """
  @spec evaluate_with_hooks(Contract.t(), Policy.t(), Gate.gate_context(), map()) ::
          hook_result()
  def evaluate_with_hooks(
        %Contract{} = contract,
        %Policy{} = policy,
        %{} = context,
        %{} = registry
      ) do
    alias Tet.HookManager

    case HookManager.execute_pre(registry, context) do
      {:ok, pre_context, pre_guides} ->
        gate_decision = Gate.evaluate(contract, policy, pre_context)

        case gate_decision do
          {:block, _} ->
            # Gate blocks → decision is final. Post-hooks do not run.
            # Hooks cannot override gate blocks (no-override invariant).
            {:ok, gate_decision, pre_context, pre_guides}

          _ ->
            # Gate allows or guides → run post-hooks for enrichment.
            post_context = Map.put(pre_context, :gate_decision, gate_decision)

            case HookManager.execute_post(registry, post_context) do
              {:ok, final_context, post_guides} ->
                {:ok, gate_decision, final_context, pre_guides ++ post_guides}

              {:block, _reason, block_context} ->
                # Post-hook vetoes the allowed decision.
                {:block, :hook_blocked, block_context}
            end
        end

      {:block, reason, block_context} ->
        # Pre-hook veto → gate never runs.
        {:block, reason, block_context}
    end
  end
end
