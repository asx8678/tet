defmodule Tet.Checkpoint.Replay do
  @moduledoc """
  Deterministic workflow replay from persisted steps — BD-0035.

  Replay orchestrates the idempotent re-execution of workflow steps after a
  crash or checkpoint restore, ensuring that already-committed steps are never
  re-executed (no double side effects).

  ## Replay lifecycle

      1. Load checkpoint state snapshot
      2. List workflow steps for the session
      3. For each step:
         - If committed/completed → skip (idempotent)
         - If pending/failed → re-execute via the provided step function
         - Non-deterministic steps (metadata key `non_deterministic: true`) are
           flagged but still replayed when pending

  ## Usage

      {:ok, snapshot} = Tet.Checkpoint.restore(MyStore, checkpoint_id)

      step_fn = fn step, store ->
        # Re-execute the step logic, ensuring idempotent side effects
        # Returns {:ok, output} or {:error, reason}
      end

      Tet.Checkpoint.Replay.replay_workflow(MyStore, workflow_id, step_fn)
  """

  @doc """
  Replays all steps for a specific workflow.

  Steps are processed in their original order. Already terminal steps
  (committed/completed) are skipped. Pending/failed steps are passed to
  `step_fn` for re-execution.

  ## Step function contract

  `step_fn` receives `(step, store)` and should return:
    - `{:ok, output}` on successful execution
    - `{:error, reason}` on failure

  The step function is responsible for committing the step via
  `store.commit_step/2` or `store.fail_step/2`.

  ## Options

    * `:on_skip` — callback `(step, reason) :: any` invoked when a step is skipped
    * `:on_non_deterministic` — callback `(step) :: any` invoked when a
      non-deterministic step is encountered
    * `:fail_on_non_deterministic` — when `true`, raises an error on non-deterministic
      steps instead of replaying them. Default `false`.

  Returns `{:ok, %{total: pos_integer(), skipped: pos_integer(), replayed: pos_integer(),
  failed: pos_integer()}}`.
  """
  @spec replay_workflow(module(), binary(), function(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def replay_workflow(store, workflow_id, step_fn, opts \\ []) when is_list(opts) do
    with {:ok, steps} <- store.list_steps(workflow_id, opts) do
      steps
      |> Enum.sort_by(& &1.created_at)
      |> replay_steps(store, step_fn, opts, %{total: 0, skipped: 0, replayed: 0, failed: 0})
    end
  end

  @doc """
  Replays all workflow steps across all workflows for a given session.
  """
  @spec replay_session(module(), binary(), function(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def replay_session(store, session_id, step_fn, opts \\ []) when is_list(opts) do
    with {:ok, steps} <- store.get_steps(session_id, opts) do
      workflow_ids =
        steps
        |> Enum.map(& &1.workflow_id)
        |> Enum.uniq()

      results =
        Enum.map(workflow_ids, fn wf_id ->
          wf_steps = Enum.filter(steps, &(&1.workflow_id == wf_id))
          wf_steps = Enum.sort_by(wf_steps, & &1.created_at)

          case replay_steps(wf_steps, store, step_fn, opts, %{
                 total: 0,
                 skipped: 0,
                 replayed: 0,
                 failed: 0
               }) do
            {:ok, summary} -> %{workflow_id: wf_id, summary: summary}
            {:error, reason} -> %{workflow_id: wf_id, error: reason}
          end
        end)

      {:ok, results}
    end
  end

  # -- Private helpers --

  defp replay_steps([], _store, _step_fn, _opts, summary) do
    {:ok, summary}
  end

  defp replay_steps([step | rest], store, step_fn, opts, summary) do
    summary = %{summary | total: summary.total + 1}

    cond do
      terminal?(step) ->
        maybe_call_skip_callback(opts, step, :already_committed)
        replay_steps(rest, store, step_fn, opts, %{summary | skipped: summary.skipped + 1})

      non_deterministic?(step) ->
        if Keyword.get(opts, :fail_on_non_deterministic, false) do
          maybe_call_non_deterministic_callback(opts, step)
          {:error, {:non_deterministic_step, step.step_name, step.id}}
        else
          maybe_call_non_deterministic_callback(opts, step)
          execute_and_continue(step, rest, store, step_fn, opts, summary)
        end

      true ->
        execute_and_continue(step, rest, store, step_fn, opts, summary)
    end
  end

  defp terminal?(%Tet.WorkflowStep{status: status}) do
    status in [:committed, :completed, :cancelled]
  end

  defp non_deterministic?(%Tet.WorkflowStep{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "non_deterministic", false) or
      Map.get(metadata, :non_deterministic, false)
  end

  defp non_deterministic?(_step), do: false

  defp execute_and_continue(step, rest, store, step_fn, opts, summary) do
    case step_fn.(step, store) do
      {:ok, _output} ->
        replay_steps(rest, store, step_fn, opts, %{summary | replayed: summary.replayed + 1})

      {:error, reason} ->
        case store.fail_step(step.id, reason) do
          {:ok, _} -> :ok
          {:error, _fail_err} -> :ok
        end

        {:error, {:step_failed, step.step_name, step.id, reason}}
    end
  end

  defp maybe_call_skip_callback(opts, step, reason) do
    case Keyword.get(opts, :on_skip) do
      nil -> :ok
      callback when is_function(callback, 2) -> callback.(step, reason)
    end
  end

  defp maybe_call_non_deterministic_callback(opts, step) do
    case Keyword.get(opts, :on_non_deterministic) do
      nil -> :ok
      callback when is_function(callback, 1) -> callback.(step)
    end
  end
end
