defmodule Tet.Runtime.RepairInspector do
  @moduledoc """
  Pre-turn repair inspection hook — BD-0058.

  Inspects open Error Log entries and pending Repair Queue items before
  normal prompt execution. Surfaces guidance for critical items and
  summaries for non-critical items.

  ## Severity classification

    - `:critical` — boot/runtime corruption (`:crash`, `:compile_failure` errors
      or pending repairs with `:patch`/`:fallback` strategy). The inspector
      returns a `{:guide, message, context}` action with a critical guidance
      message suggesting the operator pause and choose: diagnose, ignore once,
      or use fallback.
    - `:high` — subsystem failure (`:exception`, `:remote_failure`,
      `:smoke_failure` errors or any pending repairs). A warning is surfaced
      but normal prompt execution may proceed.
    - `:normal` — non-blocking items. A brief summary is shown when items
      exist; no items produces a plain `{:continue, context}`.

  ## Hook registration

      registry =
        Tet.HookManager.new()
        |> Tet.HookManager.register(Tet.Runtime.RepairInspector.build_hook())

  The hook expects the following keys in context:

    - `:store_adapter` — the store module to query (defaults to configured
      `:tet_core, :store_adapter` or `Tet.Store.Memory`)
    - `:session_id` — optional session id to scope the query

  ## Examples

      iex> context = %{store_adapter: MyStore, session_id: "ses_001"}
      iex> {:guide, msg, ctx} = Tet.Runtime.RepairInspector.run_inspection(context)
      iex> ctx.repair_inspection.severity
      :normal
  """

  # Error kinds considered critical (boot/runtime corruption).
  @critical_kinds [:crash, :compile_failure]

  # Error kinds considered high severity (subsystem failure).
  @high_kinds [:exception, :remote_failure, :smoke_failure]

  # Repair strategies that elevate severity to critical.
  @critical_repair_strategies [:patch, :fallback]

  @doc """
  Returns the recognised critical error kinds.
  """
  @spec critical_kinds() :: [atom()]
  def critical_kinds, do: @critical_kinds

  @doc """
  Returns the recognised high error kinds.
  """
  @spec high_kinds() :: [atom()]
  def high_kinds, do: @high_kinds

  @doc """
  Critical repair strategies that indicate boot/runtime corruption.
  """
  @spec critical_repair_strategies() :: [atom()]
  def critical_repair_strategies, do: @critical_repair_strategies

  @doc """
  Builds a pre-turn repair inspection hook for registration with HookManager.

  ## Options

    * `:priority` — hook priority (default `500`). High enough to run before
      most other pre-hooks.

  Returns a `Tet.HookManager.Hook` struct.
  """
  @spec build_hook(keyword()) :: Tet.HookManager.Hook.t()
  def build_hook(opts \\ []) when is_list(opts) do
    priority = Keyword.get(opts, :priority, 500)

    Tet.HookManager.Hook.new!(%{
      id: "pre-turn-repair-inspection",
      event_type: :pre,
      priority: priority,
      action_fn: &run_inspection/1,
      description: "Pre-turn repair inspection (BD-0058)"
    })
  end

  @doc """
  Inspects open repairs and errors before prompt execution.

  Context may include:
    - `:store_adapter` — store module for querying errors and repairs
    - `:session_id` — optional session id to scope queries

  Returns one of:
    - `{:guide, message, context}` — issues found, message contains guidance
    - `{:continue, context}` — no issues, execution may proceed normally

  The context is augmented with a `:repair_inspection` key containing the
  inspection result.
  """
  @spec run_inspection(map()) :: {:continue, map()} | {:guide, String.t(), map()}
  def run_inspection(context) when is_map(context) do
    store = Map.get(context, :store_adapter, default_store())
    session_id = Map.get(context, :session_id)

    case fetch_open_items(store, session_id) do
      {:ok, open_errors, pending_repairs} ->
        severity = classify_severity(open_errors, pending_repairs)

        inspection = %{
          severity: severity,
          open_errors: open_errors,
          pending_repairs: pending_repairs,
          critical_count: count_by_kind(open_errors, @critical_kinds),
          high_count: count_by_kind(open_errors, @high_kinds),
          pending_count: length(pending_repairs),
          query_errors: [],
          inspection_complete?: true
        }

        context = Map.put(context, :repair_inspection, inspection)

        case severity do
          :critical ->
            {:guide, format_critical_guidance(inspection), context}

          :high ->
            {:guide, format_high_guidance(inspection), context}

          :normal ->
            if open_errors == [] and pending_repairs == [] do
              {:continue, context}
            else
              {:guide, format_normal_summary(inspection), context}
            end
        end

      {:error, {:list_errors_failed, reason}} ->
        query_errors = [list_errors_failed: reason]

        inspection = %{
          severity: :normal,
          open_errors: [],
          pending_repairs: [],
          critical_count: 0,
          high_count: 0,
          pending_count: 0,
          query_errors: query_errors,
          inspection_complete?: false
        }

        context = Map.put(context, :repair_inspection, inspection)

        {:guide,
         "WARNING: Repair inspection could not complete — error query failed with: #{inspect(reason)}",
         context}

      {:error, {:list_repairs_failed, reason}} ->
        query_errors = [list_repairs_failed: reason]

        inspection = %{
          severity: :normal,
          open_errors: [],
          pending_repairs: [],
          critical_count: 0,
          high_count: 0,
          pending_count: 0,
          query_errors: query_errors,
          inspection_complete?: false
        }

        context = Map.put(context, :repair_inspection, inspection)

        {:guide,
         "WARNING: Repair inspection could not complete — repair query failed with: #{inspect(reason)}",
         context}
    end
  end

  # ── Classification ──────────────────────────────────────────────────────

  @doc """
  Classifies the combined severity of open errors and pending repairs.

  Returns `:critical`, `:high`, or `:normal`.

  ## Examples

      iex> Tet.Runtime.RepairInspector.classify_severity([], [])
      :normal

      iex> error = struct(Tet.ErrorLog, %{id: "e1", session_id: "s1", kind: :crash, message: "boom"})
      iex> Tet.Runtime.RepairInspector.classify_severity([error], [])
      :critical

      iex> error = struct(Tet.ErrorLog, %{id: "e1", session_id: "s1", kind: :exception, message: "oops"})
      iex> Tet.Runtime.RepairInspector.classify_severity([error], [])
      :high
  """
  @spec classify_severity([Tet.ErrorLog.t()], [Tet.Repair.t()]) :: :critical | :high | :normal
  def classify_severity(open_errors, pending_repairs) do
    cond do
      has_critical?(open_errors, pending_repairs) -> :critical
      has_high?(open_errors, pending_repairs) -> :high
      true -> :normal
    end
  end

  @doc """
  Returns true when any error or repair indicates critical severity.
  """
  @spec has_critical?([Tet.ErrorLog.t()], [Tet.Repair.t()]) :: boolean()
  def has_critical?(open_errors, pending_repairs) do
    Enum.any?(open_errors, &(&1.kind in @critical_kinds)) or
      Enum.any?(pending_repairs, &(&1.strategy in @critical_repair_strategies))
  end

  @doc """
  Returns true when any error or repair indicates high severity.
  """
  @spec has_high?([Tet.ErrorLog.t()], [Tet.Repair.t()]) :: boolean()
  def has_high?(open_errors, pending_repairs) do
    Enum.any?(open_errors, &(&1.kind in @high_kinds)) or
      Enum.any?(pending_repairs, &(&1.status == :pending))
  end

  # ── Data fetching ───────────────────────────────────────────────────────

  defp fetch_open_items(store, session_id) do
    with {:ok, errors} <- fetch_open_errors(store, session_id),
         {:ok, repairs} <- fetch_pending_repairs(store) do
      {:ok, errors, repairs}
    end
  end

  defp fetch_open_errors(_store, nil), do: {:ok, []}

  defp fetch_open_errors(store, session_id) when is_binary(session_id) do
    case store.list_errors(session_id, []) do
      {:ok, errors} -> {:ok, Enum.filter(errors, &(&1.status == :open))}
      {:error, reason} -> {:error, {:list_errors_failed, reason}}
    end
  end

  defp fetch_pending_repairs(store) do
    case store.list_repairs([]) do
      {:ok, repairs} -> {:ok, Enum.filter(repairs, &(&1.status == :pending))}
      {:error, reason} -> {:error, {:list_repairs_failed, reason}}
    end
  end

  # ── Formatting ──────────────────────────────────────────────────────────

  defp format_critical_guidance(inspection) do
    """
    ⚠️  CRITICAL REPAIR ITEMS DETECTED

    The system has detected boot/runtime corruption that requires attention
    before normal operation can proceed.

    Open critical errors: #{inspection.critical_count}
    High severity errors: #{inspection.high_count}
    Pending repairs:      #{inspection.pending_count}

    Recommended actions:
      • Diagnose — investigate the root cause before proceeding
      • Ignore once — continue with this turn only (risk of instability)
      • Use fallback — apply a known fallback strategy

    Please address these items or choose an action to continue.
    """
    |> String.trim()
  end

  defp format_high_guidance(inspection) do
    """
    ⚠  REPAIR ITEMS FOUND (non-blocking)

    There are open error log entries or pending repairs, but none are
    critical. Normal prompt execution may proceed.

    Open high severity errors: #{inspection.high_count}
    Pending repairs:           #{inspection.pending_count}

    Consider running diagnostics when convenient.
    """
    |> String.trim()
  end

  defp format_normal_summary(inspection) do
    """
    ℹ  MINOR REPAIR ITEMS PRESENT

    Non-critical error log entries or repair queue items exist, but they
    do not block normal operation.

    Open non-critical errors: #{length(inspection.open_errors) - inspection.critical_count - inspection.high_count}
    Pending repairs:          #{inspection.pending_count}

    Normal prompt execution will proceed.
    """
    |> String.trim()
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp count_by_kind(errors, kinds) do
    Enum.count(errors, &(&1.kind in kinds))
  end

  defp default_store do
    Application.get_env(:tet_core, :store_adapter, Tet.Store.Memory)
  end
end
