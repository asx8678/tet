defmodule Tet.Runtime.Session do
  @moduledoc """
  Universal Agent Runtime session state machine — BD-0018.

  Each session is a long-lived GenServer that owns the runtime state for one
  conversation. It orchestrates safe turn-boundary profile hot-swaps, emits
  audit events through the runtime EventBus, and preserves durable session
  references across profile transitions.

  Sessions are started under `Tet.Runtime.SessionSupervisor` (a
  DynamicSupervisor) so they are properly supervised without coupling start/stop
  to arbitrary callers. On init, each session registers itself with
  `SessionRegistry` so the runtime can look up sessions by id.

  ## Profile hot-swap lifecycle

  1. `request_swap/2` is called with a target profile.
  2. If the session is at a safe turn boundary (`turn_status: :idle`), the swap
     is applied immediately and a `:profile_swap_applied` event is emitted.
  3. If the session is mid-turn and the mode is `:queue_until_turn_boundary`,
     the swap is queued as `pending_profile_swap` and a `:profile_swap_queued`
     event is emitted.
  4. If the session is mid-turn and the mode is `:reject_mid_turn`, a
     `:profile_swap_rejected` event is emitted and the call returns an error.
  5. When `end_turn/1` is called, any queued pending swap is applied and a
     `:profile_swap_applied` event is emitted.

  ## Audit event correlation

  All swap-related events (`profile_swap_queued`, `profile_swap_applied`,
  `profile_swap_rejected`) carry a consistent `swap_id` in their metadata so
  callers can correlate the complete lifecycle of a single swap request.
  """

  use GenServer, restart: :temporary

  alias Tet.Runtime.{SessionRegistry, State}

  # ── Client API ──────────────────────────────────────────────────────

  @doc """
  Starts a session GenServer via the DynamicSupervisor.

  The `state_attrs` argument should be a validated `Tet.Runtime.State` struct
  or a map of attrs that `State.new/1` can accept.
  """
  @spec start_session(State.t() | map(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(state_attrs, opts \\ []) when is_map(state_attrs) and is_list(opts) do
    Tet.Runtime.SessionSupervisor.start_session(state_attrs, opts)
  end

  @doc """
  Starts a session GenServer directly (used by DynamicSupervisor).

  The `state` argument should be a validated `Tet.Runtime.State` struct or a
  map of attrs that `State.new/1` can accept.
  """
  @spec start_link(State.t() | map(), keyword()) :: GenServer.on_start()
  def start_link(state_attrs, opts \\ []) when is_map(state_attrs) and is_list(opts) do
    {gen_opts, runtime_opts} = Keyword.split(opts, [:name])

    state =
      case state_attrs do
        %State{} = s ->
          s

        attrs when is_map(attrs) ->
          case State.new(attrs) do
            {:ok, s} -> s
            {:error, reason} -> raise ArgumentError, "invalid session state: #{inspect(reason)}"
          end
      end

    GenServer.start_link(__MODULE__, {state, runtime_opts}, gen_opts)
  end

  @doc """
  Used by DynamicSupervisor as a child spec.
  """
  @spec child_spec({map(), keyword()}) :: Supervisor.child_spec()
  def child_spec({state_attrs, opts}) when is_map(state_attrs) and is_list(opts) do
    %{
      id: {__MODULE__, state_attrs},
      start: {__MODULE__, :start_link, [state_attrs, opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  Requests a profile swap for the given session.

  Returns `{:ok, state, events}` on success or `{:error, reason}` on failure.
  Events is a list of `Tet.Event` structs emitted during the operation.
  """
  @spec request_swap(pid(), State.profile_ref() | binary() | atom(), keyword()) ::
          {:ok, State.t(), [Tet.Event.t()]} | {:error, term()}
  def request_swap(session, profile, opts \\ [])
      when is_pid(session) and is_list(opts) do
    GenServer.call(session, {:request_swap, profile, opts})
  end

  @doc """
  Begins a new turn in the session.
  """
  @spec begin_turn(pid(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def begin_turn(session, opts \\ []) when is_pid(session) and is_list(opts) do
    GenServer.call(session, {:begin_turn, opts})
  end

  @doc """
  Updates the turn status during an active turn.
  """
  @spec put_turn_status(pid(), State.turn_status() | binary(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def put_turn_status(session, status, opts \\ [])
      when is_pid(session) and is_list(opts) do
    GenServer.call(session, {:put_turn_status, status, opts})
  end

  @doc """
  Ends the current turn, applying any queued profile swap at the boundary.

  Returns `{:ok, state, events}` on success where events includes any
  pending swap applied at the boundary.
  """
  @spec end_turn(pid(), keyword()) :: {:ok, State.t(), [Tet.Event.t()]} | {:error, term()}
  def end_turn(session, opts \\ []) when is_pid(session) and is_list(opts) do
    GenServer.call(session, {:end_turn, opts})
  end

  @doc """
  Returns the current session state.
  """
  @spec get_state(pid()) :: State.t()
  def get_state(session) when is_pid(session) do
    GenServer.call(session, :get_state)
  end

  @doc """
  Returns the session id for this session pid.
  """
  @spec get_session_id(pid()) :: binary()
  def get_session_id(session) when is_pid(session) do
    GenServer.call(session, :get_session_id)
  end

  # ── Server callbacks ────────────────────────────────────────────────

  @impl true
  def init({state, _runtime_opts}) do
    SessionRegistry.register(state.session_id)
    {:ok, state}
  end

  @impl true
  def terminate(_reason, %State{} = _state) do
    SessionRegistry.unregister()
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_call({:request_swap, profile, opts}, _from, %State{} = state) do
    # Generate a single swap_id for correlation across queued/applied/rejected events
    swap_id = Tet.Runtime.Ids.swap_id()
    opts = Keyword.put(opts, :swap_id, swap_id)

    case State.request_profile_swap(state, profile, opts) do
      {:ok, new_state} ->
        events = build_swap_applied_events(new_state, state, opts)
        {:reply, {:ok, new_state, events}, new_state}

      {:error, {:unsafe_profile_swap, request}} ->
        events = [build_rejected_event(state, request, opts)]
        Enum.each(events, &publish_event/1)
        {:reply, {:error, {:unsafe_profile_swap, request}}, state}

      {:error, {:profile_swap_already_pending, pending}} ->
        {:reply, {:error, {:profile_swap_already_pending, pending}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:begin_turn, _opts}, _from, %State{} = state) do
    case State.begin_turn(state) do
      {:ok, new_state} -> {:reply, {:ok, new_state}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:put_turn_status, status, _opts}, _from, %State{} = state) do
    case State.put_turn_status(state, status) do
      {:ok, new_state} -> {:reply, {:ok, new_state}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:end_turn, opts}, _from, %State{} = state) do
    case State.end_turn(state) do
      {:ok, new_state} ->
        events = build_turn_end_swap_events(new_state, state, opts)
        {:reply, {:ok, new_state, events}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, %State{} = state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:get_session_id, _from, %State{} = state) do
    {:reply, state.session_id, state}
  end

  # ── Event emission ──────────────────────────────────────────────────

  defp build_swap_applied_events(new_state, old_state, opts) do
    # If active_profile changed, emit a profile_swap_applied
    if new_state.active_profile != old_state.active_profile do
      event = build_applied_event(new_state, old_state, opts)
      publish_event(event)
      [event]
    else
      # Still queued — emit profile_swap_queued
      if old_state.pending_profile_swap != new_state.pending_profile_swap and
           new_state.pending_profile_swap != nil do
        event = build_queued_event(new_state, old_state, opts)
        publish_event(event)
        [event]
      else
        []
      end
    end
  end

  defp build_turn_end_swap_events(new_state, old_state, opts) do
    # Check if a pending swap was applied at turn boundary
    if old_state.pending_profile_swap != nil and
         new_state.pending_profile_swap == nil and
         new_state.active_profile != old_state.active_profile do
      # Carry forward the swap_id from the pending request for correlation
      swap_id = Map.get(old_state.pending_profile_swap, :swap_id)
      opts = if swap_id, do: Keyword.put(opts, :swap_id, swap_id), else: opts

      event = build_applied_event(new_state, old_state, opts)
      publish_event(event)
      [event]
    else
      []
    end
  end

  defp build_queued_event(new_state, _old_state, opts) do
    swap = new_state.pending_profile_swap
    swap_id = Keyword.get(opts, :swap_id, Tet.Runtime.Ids.swap_id())

    Tet.Event.profile_swap_queued(
      %{
        from_profile: swap.from_profile,
        to_profile: swap.to_profile,
        mode: swap.mode,
        requested_at_sequence: swap.requested_at_sequence,
        blocked_by: swap.blocked_by,
        cache_policy: swap.cache_policy
      },
      session_id: new_state.session_id,
      sequence: new_state.event_sequence,
      metadata:
        Keyword.get(opts, :metadata, %{})
        |> Map.put(:swap_id, swap_id)
    )
  end

  defp build_applied_event(new_state, _old_state, opts) do
    swap_id = Keyword.get(opts, :swap_id, Tet.Runtime.Ids.swap_id())

    Tet.Event.profile_swap_applied(
      %{
        active_profile: new_state.active_profile,
        pending_profile_swap: nil
      },
      session_id: new_state.session_id,
      sequence: new_state.event_sequence,
      metadata:
        Keyword.get(opts, :metadata, %{})
        |> Map.put(:swap_id, swap_id)
    )
  end

  defp build_rejected_event(state, request, opts) do
    swap_id = Keyword.get(opts, :swap_id, Tet.Runtime.Ids.swap_id())

    Tet.Event.profile_swap_rejected(
      %{
        from_profile: request.from_profile,
        to_profile: request.to_profile,
        mode: request.mode,
        requested_at_sequence: request.requested_at_sequence,
        blocked_by: request.blocked_by,
        reason: :mid_turn_rejected
      },
      session_id: state.session_id,
      sequence: state.event_sequence,
      metadata:
        Keyword.get(opts, :metadata, %{})
        |> Map.put(:swap_id, swap_id)
    )
  end

  defp publish_event(%Tet.Event{} = event) do
    Tet.EventBus.publish(Tet.Runtime.Timeline.all_topic(), event)

    case event.session_id do
      nil -> :ok
      session_id -> Tet.EventBus.publish({:session, session_id}, event)
    end
  end
end
