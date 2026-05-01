defmodule Tet.Runtime.GuidanceLoop do
  @moduledoc """
  Guidance rendering loop — BD-0033.

  A runtime GenServer that listens for task/tool events on the EventBus,
  extracts focus/guide decisions from steering evaluator output, persists
  guidance messages with event references, and manages the guidance lifecycle.

  ## Lifecycle

  1. On init, subscribes to the runtime-wide event topic.
  2. When a task or tool event arrives:
     a. Active guidance for the event's session is marked as expired (superseded by new events).
     b. If the event payload contains a steering decision with guidance
        (`:focus` or `:guide`), a `GuidanceMessage` is created with the
        event's session_id and sequence for correlation.
  3. Active guidance can be queried via `get_active_guidance/1`.

  ## Task/tool events that trigger guidance lifecycle

  - `:tool.started`, `:tool.finished`
  - `:"read_tool.started"`, `:"read_tool.completed"`
  - `:steering_decision`

  ## Usage

      {:ok, pid} = Tet.Runtime.GuidanceLoop.start_link([])
      active = Tet.Runtime.GuidanceLoop.get_active_guidance(pid)
  """

  use GenServer

  alias Tet.Steering.{GuidanceMessage, GuidanceStore}

  @task_tool_event_types [
    :"tool.started",
    :"tool.finished",
    :"read_tool.started",
    :"read_tool.completed",
    :steering_decision
  ]

  # ── Client API ──────────────────────────────────────────────────────

  @doc "Starts the guidance loop GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {gen_opts, _loop_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, :ok, gen_opts)
  end

  @doc "Returns the child spec for supervision trees."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Returns all active (non-expired) guidance messages.

  Returns a list of `Tet.Steering.GuidanceMessage` structs ordered by event
  sequence (earliest first).
  """
  @spec get_active_guidance(pid()) :: [GuidanceMessage.t()]
  def get_active_guidance(pid) when is_pid(pid) do
    GenServer.call(pid, :get_active_guidance)
  end

  @doc """
  Returns all guidance messages (active + expired) ordered by event sequence.
  """
  @spec get_all_guidance(pid()) :: [GuidanceMessage.t()]
  def get_all_guidance(pid) when is_pid(pid) do
    GenServer.call(pid, :get_all_guidance)
  end

  @doc """
  Returns active guidance messages for a specific session.

  Convenience for renderers that only need one session's guidance.
  """
  @spec get_active_guidance_for_session(pid(), binary()) :: [GuidanceMessage.t()]
  def get_active_guidance_for_session(pid, session_id)
      when is_pid(pid) and is_binary(session_id) do
    GenServer.call(pid, {:get_active_guidance_for_session, session_id})
  end

  @doc """
  Blocks until all previously sent messages have been processed.

  Used in tests to avoid flaky Process.sleep calls.
  """
  @spec sync(pid()) :: :ok
  def sync(pid) when is_pid(pid) do
    GenServer.call(pid, :sync)
  end

  @doc """
  Injects a steering decision into the loop for processing.

  Used when a caller has already evaluated a steering decision and wants
  the loop to persist any resulting guidance. This is the primary mechanism
  for "extracting focus/guide decisions from steering evaluator output."
  """
  @spec ingest_decision(pid(), map(), keyword()) :: :ok
  def ingest_decision(pid, decision_attrs, opts \\ [])
      when is_pid(pid) and is_map(decision_attrs) and is_list(opts) do
    GenServer.cast(pid, {:ingest_decision, decision_attrs, opts})
  end

  # ── Server callbacks ────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    if Tet.EventBus.started?() do
      Tet.EventBus.subscribe(Tet.Runtime.Timeline.all_topic())
    end

    {:ok, %{store: GuidanceStore.new()}}
  end

  @impl true
  def handle_info({:tet_event, _topic, %Tet.Event{} = event}, %{store: store} = state) do
    if event.type in @task_tool_event_types do
      new_store = handle_task_tool_event(event, store)
      {:noreply, %{state | store: new_store}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:get_active_guidance, _from, %{store: store} = state) do
    active = store |> GuidanceStore.active() |> sort_by_event_seq()
    {:reply, active, state}
  end

  @impl true
  def handle_call(:get_all_guidance, _from, %{store: store} = state) do
    all = store |> GuidanceStore.all() |> sort_by_event_seq()
    {:reply, all, state}
  end

  @impl true
  def handle_call({:get_active_guidance_for_session, session_id}, _from, %{store: store} = state) do
    active =
      store
      |> GuidanceStore.active_by_session(session_id)
      |> sort_by_event_seq()

    {:reply, active, state}
  end

  @impl true
  def handle_call(:sync, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:ingest_decision, decision_attrs, opts}, %{store: store} = state) do
    session_id = Keyword.get(opts, :session_id, "")
    store = GuidanceStore.expire_by_session(store, session_id)
    new_store = process_decision(decision_attrs, opts, store)
    {:noreply, %{state | store: new_store}}
  end

  # ── Event processing ────────────────────────────────────────────────

  defp handle_task_tool_event(%Tet.Event{} = event, store) do
    session_id = event.session_id || ""

    # Expire only this session's active guidance
    store = GuidanceStore.expire_by_session(store, session_id)

    # 2. Extract steering decision from event payload if present
    case event.payload do
      %{decision: decision_map} when is_map(decision_map) ->
        process_decision(
          decision_map,
          [
            session_id: event.session_id,
            event_seq: event.seq || event.sequence,
            trigger_event_type: event.type,
            trigger_event_seq: event.seq || event.sequence
          ],
          store
        )

      _ ->
        store
    end
  end

  defp process_decision(decision_attrs, opts, store) do
    session_id = Keyword.get(opts, :session_id)
    event_seq = Keyword.get(opts, :event_seq, 0)
    trigger_event_type = Keyword.get(opts, :trigger_event_type)
    trigger_event_seq = Keyword.get(opts, :trigger_event_seq)

    case Tet.Steering.new_decision(decision_attrs) do
      {:ok, decision} ->
        if Tet.Steering.has_guidance?(decision) && is_binary(decision.guidance_message) &&
             byte_size(decision.guidance_message) > 0 do
          case GuidanceMessage.from_decision(decision,
                 session_id: session_id || "",
                 event_seq: event_seq,
                 trigger_event_type: trigger_event_type,
                 trigger_event_seq: trigger_event_seq
               ) do
            {:ok, msg} ->
              GuidanceStore.add(store, msg)

            {:error, _reason} ->
              store
          end
        else
          store
        end

      {:error, _reason} ->
        store
    end
  end

  defp sort_by_event_seq(messages) do
    Enum.sort_by(messages, & &1.event_seq)
  end
end
