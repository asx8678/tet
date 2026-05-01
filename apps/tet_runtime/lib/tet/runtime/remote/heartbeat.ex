defmodule Tet.Runtime.Remote.Heartbeat do
  @moduledoc """
  Periodic heartbeat monitor for remote worker sessions.

  BD-0055: Remote execution heartbeat, cancellation, and artifacts.

  This GenServer tracks the liveness of a remote worker by monitoring heartbeat
  reports. If no heartbeat arrives within the timeout window (interval ×
  multiplier), the session is marked stale and then expired.

  ## Telemetry events

    * `[:tet, :remote, :heartbeat, :start]` — monitor started
    * `[:tet, :remote, :heartbeat, :beat]` — heartbeat received
    * `[:tet, :remote, :heartbeat, :stale]` — heartbeat not received in time
    * `[:tet, :remote, :heartbeat, :expired]` — heartbeat expired, too late
    * `[:tet, :remote, :heartbeat, :stop]` — monitor stopped normally
  """

  use GenServer, restart: :temporary

  alias Tet.Runtime.Telemetry

  @default_interval_ms 15_000
  @default_timeout_multiplier 3
  @default_cleanup_interval_ms 60_000

  @typedoc "Current heartbeat status"
  @type status :: :starting | :alive | :stale | :expired | :stopped

  @typedoc "Heartbeat monitor state"
  @type t :: %__MODULE__{
          worker_ref: binary(),
          interval_ms: pos_integer(),
          timeout_ms: pos_integer(),
          last_seen_monotonic_ms: non_neg_integer(),
          status: status(),
          lease_id: binary() | nil,
          timer_ref: reference() | nil,
          cleanup_timer_ref: reference() | nil,
          telemetry_emit: function() | nil,
          metadata: map()
        }

  defstruct [
    :worker_ref,
    :interval_ms,
    :timeout_ms,
    :last_seen_monotonic_ms,
    :status,
    :lease_id,
    :timer_ref,
    :cleanup_timer_ref,
    :cleanup_interval_ms,
    :telemetry_emit,
    metadata: %{}
  ]

  # ── Public API ──────────────────────────────────────────────

  @doc """
  Starts a heartbeat monitor for the given worker.

  ## Options

    * `:interval_ms` — how often to check for heartbeats (default: 15_000)
    * `:timeout_multiplier` — how many intervals before expiry (default: 3)
    * `:cleanup_interval_ms` — how often to clean up stale sessions (default: 60_000)
    * `:telemetry_emit` — optional telemetry emit callback (see `Tet.Runtime.Telemetry`)
    * `:lease_id` — optional lease identifier from the bootstrap report
    * `:metadata` — optional metadata map attached to telemetry events
  """
  @spec start_link(binary(), keyword()) :: GenServer.on_start()
  def start_link(worker_ref, opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, {worker_ref, opts})
  end

  @doc "Registers a heartbeat from the remote worker."
  @spec beat(pid(), map()) :: :ok
  def beat(pid, heartbeat_data) when is_map(heartbeat_data) do
    GenServer.cast(pid, {:beat, heartbeat_data})
  end

  @doc "Returns the current heartbeat status."
  @spec status(pid()) :: status()
  def status(pid) do
    GenServer.call(pid, :status)
  end

  @doc "Stops the heartbeat monitor gracefully."
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.cast(pid, :stop)
  end

  @doc "Returns whether the session is still considered alive."
  @spec alive?(pid()) :: boolean()
  def alive?(pid) do
    status(pid) in [:alive, :starting]
  end

  # ── GenServer callbacks ─────────────────────────────────────

  @impl true
  def init({worker_ref, opts}) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    timeout_multiplier = Keyword.get(opts, :timeout_multiplier, @default_timeout_multiplier)
    cleanup_interval_ms = Keyword.get(opts, :cleanup_interval_ms, @default_cleanup_interval_ms)

    state = %__MODULE__{
      worker_ref: worker_ref,
      interval_ms: interval_ms,
      timeout_ms: interval_ms * timeout_multiplier,
      last_seen_monotonic_ms: System.monotonic_time(:millisecond),
      status: :starting,
      lease_id: Keyword.get(opts, :lease_id),
      cleanup_interval_ms: cleanup_interval_ms,
      telemetry_emit: Keyword.get(opts, :telemetry_emit),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    timer_ref = schedule_check(state)
    cleanup_timer_ref = schedule_cleanup(state)

    emit(:start, %{interval_ms: interval_ms, timeout_ms: state.timeout_ms}, state)

    {:ok, %{state | timer_ref: timer_ref, cleanup_timer_ref: cleanup_timer_ref}}
  end

  @impl true
  def handle_cast({:beat, heartbeat_data}, state) do
    new_last_seen = System.monotonic_time(:millisecond)
    remote_timestamp = Map.get(heartbeat_data, :last_seen_monotonic_ms)

    new_status = :alive
    new_lease_id = Map.get(heartbeat_data, :lease_id, state.lease_id)

    emit(
      :beat,
      %{
        last_seen_monotonic_ms: new_last_seen,
        remote_timestamp_ms: remote_timestamp,
        interval_ms: state.interval_ms
      },
      state
    )

    {:noreply,
     %{state | last_seen_monotonic_ms: new_last_seen, status: new_status, lease_id: new_lease_id}}
  end

  @impl true
  def handle_cast(:stop, state) do
    emit(:stop, %{duration_ms: elapsed(state)}, state)
    {:stop, :normal, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_info(:check, state) do
    now = System.monotonic_time(:millisecond)
    elapsed_since_last = now - state.last_seen_monotonic_ms

    new_status =
      cond do
        state.status == :stopped -> :stopped
        elapsed_since_last >= state.timeout_ms -> :expired
        elapsed_since_last >= div(state.timeout_ms, 2) -> :stale
        true -> :alive
      end

    new_state = %{state | status: new_status, timer_ref: schedule_check(state)}

    if new_status in [:stale, :expired] and new_status != state.status do
      emit(
        new_status,
        %{elapsed_since_last_ms: elapsed_since_last, timeout_ms: state.timeout_ms},
        state
      )
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    if state.status == :expired do
      emit(:stop, %{duration_ms: elapsed(state), reason: :expired}, state)
      {:stop, :normal, state}
    else
      cleanup_timer_ref = schedule_cleanup(state)
      {:noreply, %{state | cleanup_timer_ref: cleanup_timer_ref}}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  # ── Private helpers ─────────────────────────────────────────

  defp schedule_check(state) do
    Process.send_after(self(), :check, state.interval_ms)
  end

  defp schedule_cleanup(state) do
    Process.send_after(self(), :cleanup, state.cleanup_interval_ms)
  end

  defp elapsed(state) do
    System.monotonic_time(:millisecond) - state.last_seen_monotonic_ms
  end

  defp emit(event, measurements, state) do
    Telemetry.execute(
      [:tet, :remote, :heartbeat, event],
      measurements,
      %{
        worker_ref: state.worker_ref,
        lease_id: state.lease_id,
        status: state.status
      },
      telemetry_opts(state)
    )
  end

  defp telemetry_opts(state) do
    case state.telemetry_emit do
      nil -> []
      emit -> [telemetry_emit: emit]
    end
  end
end
