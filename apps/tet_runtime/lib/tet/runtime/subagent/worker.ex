defmodule Tet.Runtime.Subagent.Worker do
  @moduledoc """
  GenServer managing a single subagent's lifecycle.

  Each subagent runs inside a Worker that tracks status, supports cancellation
  with cleanup, and enforces budget/timeout limits. The worker is the unit of
  supervision — if a subagent crashes, only that worker restarts (transient).

  ## Status transitions

      :idle → :running → :completed
        ↘         ↘          ↘
        :cancelled  :cancelled  :cancelled
                    :error

  Status is monotonic: once a subagent leaves :idle, it cannot go back. A
  subagent in :completed, :cancelled, or :error is terminal.

  ## Parent-task correlation

  Every worker holds its `Tet.Subagent.Spec` which includes `parent_task_id`.
  The runtime can use this to find all subagents for a given task, or cancel
  subagents when a parent task is cancelled.

  ## Budget tracking

  If the spec specifies a `:budget`, the worker tracks accumulated cost and
  exposes `budget_remaining/1` so callers can decide whether to continue
  before dispatching another LLM call.
  """

  use GenServer, restart: :transient

  alias Tet.Subagent.Spec

  @terminal_statuses [:completed, :cancelled, :error]

  # ── Client API ───────────────────────────────────────────────────────

  @doc """
  Starts a subagent worker linked to the caller.

  The worker registers itself via `:via` tuple using `subagent_id` from the
  spec so the supervisor can find it by id.
  """
  @spec start_link(Spec.t()) :: GenServer.on_start()
  def start_link(%Spec{} = spec) do
    GenServer.start_link(__MODULE__, spec, name: via(spec))
  end

  @doc """
  Returns the subagent spec for the worker at `pid`.
  """
  @spec get_spec(pid()) :: Spec.t() | nil
  def get_spec(pid) do
    GenServer.call(pid, :get_spec)
  catch
    :exit, _ -> nil
  end

  @doc """
  Returns the current status of the subagent.
  """
  @spec get_status(pid()) :: atom() | nil
  def get_status(pid) do
    GenServer.call(pid, :get_status)
  catch
    :exit, _ -> nil
  end

  @doc """
  Transitions the subagent to `:running`.

  Returns `{:ok, pid}` if transition was valid, or `{:error, reason}` if the
  subagent is already in a terminal state or cancelled.
  """
  @spec start_run(pid()) :: {:ok, pid()} | {:error, term()}
  def start_run(pid) do
    GenServer.call(pid, :start_run)
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Transitions the subagent to `:completed`.

  Returns `{:ok, state}` or `{:error, reason}`.
  """
  @spec complete(pid()) :: {:ok, atom()} | {:error, term()}
  def complete(pid) do
    GenServer.call(pid, :complete)
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Transitions the subagent to `:error`.

  Optionally accepts a reason that is stored in worker state.
  Returns `{:ok, state}` or `{:error, reason}`.
  """
  @spec error(pid(), binary() | nil) :: {:ok, atom()} | {:error, term()}
  def error(pid, reason \\ nil) do
    GenServer.call(pid, {:error, reason})
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Cancels the subagent with cleanup.

  Cancellation is idempotent — calling cancel on an already-cancelled or
  terminal subagent returns `{:ok, :already_cancelled}`.

  Returns `{:ok, status}` where status is the new or existing terminal status.
  """
  @spec cancel(pid()) :: {:ok, atom()} | {:error, term()}
  def cancel(pid) do
    GenServer.call(pid, :cancel)
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Returns the remaining budget in milli-units, or `nil` if no budget was set.
  """
  @spec budget_remaining(pid()) :: non_neg_integer() | nil | {:error, term()}
  def budget_remaining(pid) do
    GenServer.call(pid, :budget_remaining)
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  Records a cost against the subagent's budget.

  Returns `{:ok, remaining}` or `{:error, :over_budget}` if the cost exceeds
  the remaining budget. When over budget, the subagent is NOT automatically
  cancelled — the caller should decide based on the return value.
  """
  @spec record_cost(pid(), pos_integer()) :: {:ok, non_neg_integer() | nil} | {:error, term()}
  def record_cost(pid, cost) when is_integer(cost) and cost > 0 do
    GenServer.call(pid, {:record_cost, cost})
  catch
    :exit, _ -> {:error, :not_found}
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(%Spec{} = spec) do
    state = %{
      spec: spec,
      status: :idle,
      budget_used: 0,
      error_reason: nil,
      started_at: nil,
      completed_at: nil,
      timer_ref: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_spec, _from, state) do
    {:reply, state.spec, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call(:start_run, _from, state) do
    case state.status do
      :idle ->
        timer_ref =
          if state.spec.timeout do
            Process.send_after(self(), :subagent_timeout, state.spec.timeout)
          end

        new_state = %{
          state
          | status: :running,
            started_at: DateTime.utc_now(),
            timer_ref: timer_ref
        }

        {:reply, {:ok, self()}, new_state}

      :cancelled ->
        {:reply, {:error, {:cancelled, "subagent was cancelled before starting"}}, state}

      terminal_status when terminal_status in @terminal_statuses ->
        {:reply, {:error, {:invalid_transition, %{to: :running, from: terminal_status}}}, state}

      current ->
        {:reply, {:error, {:invalid_transition, %{to: :running, from: current}}}, state}
    end
  end

  @impl true
  def handle_call(:complete, _from, state) do
    case state.status do
      :running ->
        if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

        new_state = %{
          state
          | status: :completed,
            completed_at: DateTime.utc_now(),
            timer_ref: nil
        }

        {:stop, :normal, {:ok, :completed}, new_state}

      :cancelled ->
        {:reply, {:ok, :cancelled}, state}

      terminal_status when terminal_status in @terminal_statuses ->
        {:reply, {:error, {:invalid_transition, %{to: :completed, from: terminal_status}}}, state}

      current ->
        {:reply, {:error, {:invalid_transition, %{to: :completed, from: current}}}, state}
    end
  end

  @impl true
  def handle_call({:error, reason}, _from, state) do
    case state.status do
      :running ->
        if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

        new_state = %{
          state
          | status: :error,
            error_reason: reason,
            completed_at: DateTime.utc_now(),
            timer_ref: nil
        }

        {:stop, :normal, {:ok, :error}, new_state}

      :cancelled ->
        {:reply, {:ok, :cancelled}, state}

      terminal_status when terminal_status in @terminal_statuses ->
        {:reply, {:error, {:invalid_transition, %{to: :error, from: terminal_status}}}, state}

      current ->
        {:reply, {:error, {:invalid_transition, %{to: :error, from: current}}}, state}
    end
  end

  @impl true
  def handle_call(:cancel, _from, state) do
    case state.status do
      status when status in [:completed, :error] ->
        {:reply, {:error, {:invalid_transition, %{to: :cancelled, from: status}}}, state}

      :cancelled ->
        {:reply, {:ok, :cancelled}, state}

      _ ->
        if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

        new_state = %{
          state
          | status: :cancelled,
            completed_at: DateTime.utc_now(),
            timer_ref: nil
        }

        {:reply, {:ok, :cancelled}, new_state}
    end
  end

  @impl true
  def handle_call(:budget_remaining, _from, state) do
    remaining = calculate_remaining(state)
    {:reply, remaining, state}
  end

  @impl true
  def handle_call({:record_cost, cost}, _from, state) do
    case state.spec.budget do
      nil ->
        # No budget cap, just track usage
        new_state = %{state | budget_used: state.budget_used + cost}
        {:reply, {:ok, nil}, new_state}

      budget ->
        new_used = state.budget_used + cost

        if new_used <= budget do
          remaining = budget - new_used
          new_state = %{state | budget_used: new_used}
          {:reply, {:ok, remaining}, new_state}
        else
          {:reply, {:error, :over_budget}, state}
        end
    end
  end

  @impl true
  def handle_call(_unknown, _from, state) do
    {:reply, {:error, :unknown_request}, state}
  end

  @impl true
  def handle_info(:subagent_timeout, state) do
    new_state = %{
      state
      | status: :error,
        error_reason: "timeout",
        completed_at: DateTime.utc_now(),
        timer_ref: nil
    }

    {:stop, :normal, new_state}
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp via(%Spec{} = spec) do
    {:via, Registry, {Tet.Runtime.Subagent.Registry, Spec.subagent_id(spec)}}
  end

  defp calculate_remaining(state) do
    case state.spec.budget do
      nil -> nil
      budget when state.budget_used <= budget -> budget - state.budget_used
      _budget -> 0
    end
  end
end
