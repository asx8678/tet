defmodule Tet.PlanMode.Evaluator do
  @moduledoc """
  Ring-2 steering evaluator — runs AFTER deterministic gate checks.

  BD-0032 introduces a lightweight evaluator that takes a gate decision
  (from `Tet.PlanMode.Gate`, Ring-1) and applies a configurable evaluation
  profile to produce a final decision with an audit trail.

  ## Core invariant

  **The evaluator NEVER overrides a block.** If the gate says `{:block, _}`,
  the evaluator propagates it unchanged. This is the no-override guarantee
  that makes steering safe: deterministic gates are the final word on
  denial; the evaluator can only add guidance or focus to allowed
  operations.

  ## Decision pipeline

      gate_result → evaluator → final_decision

  1. **Block propagation** — `{:block, reason}` passes through untouched.
  2. **Guidance enrichment** — for `:allow` or `{:guide, _}`, the evaluator
     may add or enhance guidance based on profile aggressiveness and context.
  3. **Focus narrowing** — for allowed operations, the evaluator may narrow
     scope based on profile focus areas (e.g., file_safety, scope_narrowing).
  4. **Audit trail** — every evaluation produces an audit entry recording
     the gate result, profile used, and final decision.

  ## What this module does

  - Pure functions only — no side effects, no filesystem, no GenServer.
  - Adds guidance and focus to allowed operations.
  - Preserves blocks with zero modification.
  - Produces an audit trail for every evaluation.

  ## What this module does NOT do

  - Override or modify block decisions.
  - Make independent allow/block decisions (only the gate blocks).
  - Persist audit trails (that's a store concern).
  - Run hooks (that's `Tet.HookManager` — integrated via `Tet.PlanMode.evaluate_with_hooks/4`).

  ## Relationship to other modules

  - `Tet.PlanMode.Gate` (BD-0025): produces the gate_result input.
  - `Tet.PlanMode.Evaluator.Profile`: configurable evaluation criteria.
  - `Tet.PlanMode.Policy` (BD-0025): category/mode definitions for context.
  - `Tet.HookManager` (BD-0024): hooks run at a different layer, composed by `Tet.PlanMode`.
  """

  alias Tet.PlanMode.Evaluator.Profile
  alias Tet.PlanMode.Gate

  @type gate_decision :: Gate.decision()
  @type final_decision :: Gate.decision()
  @type focus :: [atom()]

  @type audit_entry :: %{
          gate_decision: gate_decision(),
          profile: Profile.t(),
          final_decision: final_decision(),
          focus: focus(),
          context: map()
        }

  @type eval_result :: {:ok, final_decision(), audit_entry()}

  @doc """
  Evaluates a gate decision through the steering evaluator profile.

  Returns `{:ok, final_decision, audit_entry}`. The final decision is the
  gate decision possibly enriched with guidance or focus, but NEVER
  different from a block.

  ## Examples

      # Blocks pass through untouched
      iex> {:ok, decision, audit} = Tet.PlanMode.Evaluator.evaluate(
      ...>   {:block, :plan_mode_blocks_mutation},
      ...>   Tet.PlanMode.Evaluator.Profile.default(),
      ...>   %{mode: :plan, task_category: :researching, task_id: "t1"})
      iex> decision
      {:block, :plan_mode_blocks_mutation}
      iex> audit.final_decision
      {:block, :plan_mode_blocks_mutation}

      # Allowed operations may get guidance added
      iex> {:ok, decision, _audit} = Tet.PlanMode.Evaluator.evaluate(
      ...>   :allow,
      ...>   Tet.PlanMode.Evaluator.Profile.default(),
      ...>   %{mode: :execute, task_category: :acting, task_id: "t1"})
      iex> match?({:guide, _}, decision) or decision == :allow
      true
  """
  @spec evaluate(gate_decision(), Profile.t(), map()) :: eval_result()
  def evaluate({:block, _reason} = gate_decision, %Profile{} = profile, %{} = context) do
    audit = build_audit(gate_decision, profile, gate_decision, [], context)
    {:ok, gate_decision, audit}
  end

  def evaluate(:allow, %Profile{} = profile, %{} = context) do
    {final_decision, focus} = enrich_allow(profile, context)
    audit = build_audit(:allow, profile, final_decision, focus, context)
    {:ok, final_decision, audit}
  end

  def evaluate({:guide, message}, %Profile{} = profile, %{} = context) do
    {final_decision, focus} = enrich_guide(message, profile, context)
    audit = build_audit({:guide, message}, profile, final_decision, focus, context)
    {:ok, final_decision, audit}
  end

  # Catch-all: unknown decision shapes pass through with a warning audit
  def evaluate(gate_decision, %Profile{} = profile, %{} = context) do
    audit = build_audit(gate_decision, profile, gate_decision, [], context)
    {:ok, gate_decision, audit}
  end

  @doc """
  Batch-evaluates a list of gate decisions through the evaluator.

  Returns a list of `{:ok, final_decision, audit_entry}` tuples in input order.
  """
  @spec evaluate_all([{binary(), gate_decision()}], Profile.t(), map()) ::
          [{binary(), eval_result()}]
  def evaluate_all(decisions, %Profile{} = profile, %{} = context) when is_list(decisions) do
    Enum.map(decisions, fn {name, gate_decision} ->
      {name, evaluate(gate_decision, profile, context)}
    end)
  end

  @doc """
  The no-override guarantee: if the gate blocks, the evaluator MUST
  return the exact same block.

  This function is the invariant check. It returns `true` when the
  evaluator correctly propagates a block decision unchanged.
  """
  @spec no_override_guaranteed?(gate_decision(), Profile.t(), map()) :: boolean()
  def no_override_guaranteed?({:block, _} = gate_decision, %Profile{} = profile, %{} = context) do
    case evaluate(gate_decision, profile, context) do
      {:ok, ^gate_decision, _audit} -> true
      _ -> false
    end
  end

  def no_override_guaranteed?(_gate_decision, _profile, _context), do: true

  @doc """
  Verifies the no-override guarantee across all block reasons.

  Returns `:ok` if all blocks are preserved, or `{:violated, details}` listing
  any block reasons that were not preserved.
  """
  @spec verify_no_override([gate_decision()], Profile.t(), map()) ::
          :ok | {:violated, [gate_decision()]}
  def verify_no_override(block_decisions, %Profile{} = profile, %{} = context)
      when is_list(block_decisions) do
    violations =
      Enum.filter(block_decisions, fn
        {:block, _} = gate_decision ->
          not no_override_guaranteed?(gate_decision, profile, context)

        _ ->
          false
      end)

    if violations == [], do: :ok, else: {:violated, violations}
  end

  # -- Private: enrichment for :allow decisions --

  defp enrich_allow(%Profile{} = profile, %{} = context) do
    focus = compute_focus(profile, context)

    guidance_message = compose_guidance_for_allow(profile, context, focus)

    final_decision =
      case {guidance_message, profile.aggressiveness} do
        {nil, _} -> :allow
        {msg, :conservative} -> {:guide, msg}
        {msg, _} -> {:guide, msg}
      end

    {final_decision, focus}
  end

  # -- Private: enrichment for {:guide, message} decisions --

  defp enrich_guide(existing_message, %Profile{} = profile, %{} = context) do
    focus = compute_focus(profile, context)

    extra_guidance = compose_extra_guidance(profile, context, focus)

    final_message =
      case {extra_guidance, profile.aggressiveness} do
        {nil, _} -> existing_message
        {extra, :aggressive} -> existing_message <> " " <> extra
        {extra, :moderate} -> existing_message <> " " <> extra
        {_, :conservative} -> existing_message
      end

    {{:guide, final_message}, focus}
  end

  # -- Private: guidance composition --

  defp compose_guidance_for_allow(%Profile{} = profile, %{} = context, focus) do
    mode = Map.get(context, :mode)
    category = Map.get(context, :task_category)

    parts =
      []
      |> maybe_add_category_guidance(mode, category, profile)
      |> maybe_add_focus_guidance(focus, profile)
      |> maybe_add_risk_guidance(profile)

    case parts do
      [] -> nil
      _ -> Enum.join(parts, " ")
    end
  end

  defp compose_extra_guidance(%Profile{} = profile, %{} = _context, focus) do
    parts =
      []
      |> maybe_add_focus_guidance(focus, profile)
      |> maybe_add_risk_guidance(profile)

    case parts do
      [] -> nil
      _ -> Enum.join(parts, " ")
    end
  end

  defp maybe_add_category_guidance(parts, mode, category, %Profile{} = profile) do
    if profile.aggressiveness in [:moderate, :aggressive] and
         is_atom(mode) and is_atom(category) do
      case {mode, category} do
        {m, c} when m in [:plan, :explore] and c in [:researching, :planning] ->
          parts ++ ["Stay in read-only territory until task commits to acting."]

        {:execute, :acting} ->
          if profile.risk_tolerance == :low do
            parts ++ ["Proceed carefully with write operations."]
          else
            parts
          end

        {:execute, :verifying} ->
          parts ++ ["Verify changes before proceeding."]

        {:execute, :debugging} ->
          parts ++ ["Focus diagnostics on the reported issue."]

        _ ->
          parts
      end
    else
      parts
    end
  end

  defp maybe_add_focus_guidance(parts, [], _profile), do: parts

  defp maybe_add_focus_guidance(parts, focus, %Profile{aggressiveness: agg}) do
    focus_messages =
      focus
      |> Enum.filter(fn _ -> agg in [:moderate, :aggressive] end)
      |> Enum.map(fn
        :file_safety -> "File safety focus: prefer minimal file modifications."
        :scope_narrowing -> "Scope narrowed: limit changes to the task's scope."
        :test_first -> "Test-first focus: run tests before and after changes."
        :minimal_mutations -> "Minimal mutations: make the smallest effective change."
        other -> "Focus: #{other}"
      end)

    parts ++ focus_messages
  end

  defp maybe_add_risk_guidance(parts, %Profile{risk_tolerance: :low, aggressiveness: agg})
       when agg in [:moderate, :aggressive] do
    parts ++ ["Low risk tolerance: double-check before mutating."]
  end

  defp maybe_add_risk_guidance(parts, _profile), do: parts

  # -- Private: focus computation --

  defp compute_focus(%Profile{focus_areas: []}, _context), do: []

  defp compute_focus(%Profile{focus_areas: areas}, _context), do: areas

  # -- Private: audit trail --

  defp build_audit(gate_decision, profile, final_decision, focus, context) do
    %{
      gate_decision: gate_decision,
      profile: %{
        aggressiveness: profile.aggressiveness,
        focus_areas: profile.focus_areas,
        risk_tolerance: profile.risk_tolerance
      },
      final_decision: final_decision,
      focus: focus,
      context: Map.take(context, [:mode, :task_category, :task_id])
    }
  end
end
