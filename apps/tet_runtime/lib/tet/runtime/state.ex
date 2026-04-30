defmodule Tet.Runtime.State do
  @moduledoc """
  Pure Universal Agent Runtime session state.

  This is the runtime-owned coordination view for one session, not a durable
  source of truth. It stores references to durable records, makes turn-level
  lifecycle explicit, and models safe profile-swap transitions. Profiles are
  data refs for now: a non-empty id plus optional options, version, and metadata.

  BD-0016 only introduces this state shape and pure transition helpers. Queued
  and rejected profile swaps are modeled as data so later runtime work can make
  deterministic decisions; this module does not orchestrate provider swaps or
  emit audit/checkpoint side effects.

  BD-0018 still owns runtime orchestration, audit event emission, checkpoints,
  compatibility diffing, and integration with the rest of the runtime. In other
  words: this module is the map, not the tiny little robot driving the car.

  ## Lifecycle/turn invariant

  Runtime states obey a deliberately small invariant: any non-idle turn status
  requires `lifecycle: :active`. `:new`, `:paused`, and terminal lifecycles must
  use `turn_status: :idle`.
  """

  alias Tet.Runtime.State.Input

  @lifecycle_statuses [:new, :active, :paused, :completed, :failed, :cancelled]
  @terminal_lifecycles [:completed, :failed, :cancelled]
  @turn_statuses [
    :idle,
    :in_turn,
    :streaming,
    :tool_running,
    :remote_running,
    :waiting_for_approval,
    :cancelling
  ]
  @profile_swap_modes [:queue_until_turn_boundary, :reject_mid_turn]

  @enforce_keys [:session_id, :active_profile]
  defstruct [
    :session_id,
    :active_profile,
    :history_ref,
    :session_memory_ref,
    :task_memory_ref,
    attachments: [],
    active_task_refs: [],
    artifact_refs: [],
    approval_refs: [],
    cache_hints: %{},
    context: %{},
    event_log_cursor: nil,
    event_sequence: 0,
    lifecycle: :new,
    turn_status: :idle,
    pending_profile_swap: nil,
    metadata: %{}
  ]

  @type ref :: binary() | map()
  @type profile_ref :: %{
          required(:id) => binary(),
          optional(:options) => map(),
          optional(:version) => binary(),
          optional(:metadata) => map()
        }
  @type lifecycle :: :new | :active | :paused | :completed | :failed | :cancelled
  @type turn_status ::
          :idle
          | :in_turn
          | :streaming
          | :tool_running
          | :remote_running
          | :waiting_for_approval
          | :cancelling
  @type profile_swap_mode :: :queue_until_turn_boundary | :reject_mid_turn
  @type cache_policy :: :preserve | :drop | {:replace, map()}
  @type profile_swap_request :: map()
  @type t :: %__MODULE__{
          session_id: binary(),
          active_profile: profile_ref(),
          history_ref: ref() | nil,
          session_memory_ref: ref() | nil,
          task_memory_ref: ref() | nil,
          attachments: [ref()],
          active_task_refs: [ref()],
          artifact_refs: [ref()],
          approval_refs: [ref()],
          cache_hints: map(),
          context: map(),
          event_log_cursor: ref() | non_neg_integer() | nil,
          event_sequence: non_neg_integer(),
          lifecycle: lifecycle(),
          turn_status: turn_status(),
          pending_profile_swap: profile_swap_request() | nil,
          metadata: map()
        }

  def lifecycle_statuses, do: @lifecycle_statuses
  def turn_statuses, do: @turn_statuses
  def profile_swap_modes, do: @profile_swap_modes

  @doc "Builds a validated runtime state from atom or string keyed attrs."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, session_id} <- Input.fetch_binary(attrs, :session_id),
         {:ok, active_profile} <- Input.fetch_profile(attrs, :active_profile, [:profile]),
         {:ok, history_ref} <- Input.fetch_optional_ref(attrs, :history_ref),
         {:ok, session_memory_ref} <- Input.fetch_optional_ref(attrs, :session_memory_ref),
         {:ok, task_memory_ref} <- Input.fetch_optional_ref(attrs, :task_memory_ref),
         {:ok, attachments} <- Input.fetch_ref_list(attrs, :attachments, [], [:attachment_refs]),
         {:ok, active_task_refs} <- Input.fetch_ref_list(attrs, :active_task_refs, [], [:tasks]),
         {:ok, artifact_refs} <- Input.fetch_ref_list(attrs, :artifact_refs, [], [:artifacts]),
         {:ok, approval_refs} <- Input.fetch_ref_list(attrs, :approval_refs, [], [:approvals]),
         {:ok, cache_hints} <- Input.fetch_map(attrs, :cache_hints, %{}),
         {:ok, context} <-
           Input.fetch_map(attrs, :context, %{}, [:compacted_context, :context_metadata]),
         {:ok, event_log_cursor} <- Input.fetch_event_log_cursor(attrs),
         {:ok, event_sequence} <-
           Input.fetch_non_negative_integer(attrs, :event_sequence, 0, [:sequence]),
         {:ok, lifecycle} <- Input.fetch_status(attrs, :lifecycle, :new, @lifecycle_statuses),
         {:ok, turn_status} <- Input.fetch_status(attrs, :turn_status, :idle, @turn_statuses),
         :ok <- validate_lifecycle_turn_state(lifecycle, turn_status),
         {:ok, pending_profile_swap} <-
           Input.fetch_pending_profile_swap(attrs, @profile_swap_modes, @turn_statuses),
         :ok <- validate_terminal_pending_swap(lifecycle, pending_profile_swap),
         {:ok, metadata} <- Input.fetch_map(attrs, :metadata, %{}) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         active_profile: active_profile,
         history_ref: history_ref,
         session_memory_ref: session_memory_ref,
         task_memory_ref: task_memory_ref,
         attachments: attachments,
         active_task_refs: active_task_refs,
         artifact_refs: artifact_refs,
         approval_refs: approval_refs,
         cache_hints: cache_hints,
         context: context,
         event_log_cursor: event_log_cursor,
         event_sequence: event_sequence,
         lifecycle: lifecycle,
         turn_status: turn_status,
         pending_profile_swap: pending_profile_swap,
         metadata: metadata
       }}
    end
  end

  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, state} -> state
      {:error, reason} -> raise ArgumentError, "invalid runtime state: #{inspect(reason)}"
    end
  end

  @doc "Converts runtime state to a map suitable for persistence or event payloads."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = state) do
    %{
      session_id: state.session_id,
      active_profile: state.active_profile,
      history_ref: state.history_ref,
      session_memory_ref: state.session_memory_ref,
      task_memory_ref: state.task_memory_ref,
      attachments: state.attachments,
      active_task_refs: state.active_task_refs,
      artifact_refs: state.artifact_refs,
      approval_refs: state.approval_refs,
      cache_hints: state.cache_hints,
      context: state.context,
      event_log_cursor: state.event_log_cursor,
      event_sequence: state.event_sequence,
      lifecycle: Atom.to_string(state.lifecycle),
      turn_status: Atom.to_string(state.turn_status),
      pending_profile_swap: Input.pending_profile_swap_to_map(state.pending_profile_swap),
      metadata: state.metadata
    }
  end

  @doc "Converts a map back to a validated runtime state."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  @doc "Returns true when a profile swap can be applied without mutating in-flight work."
  @spec safe_to_swap?(t()) :: boolean()
  def safe_to_swap?(%__MODULE__{turn_status: :idle, lifecycle: lifecycle}) do
    lifecycle not in @terminal_lifecycles
  end

  def safe_to_swap?(%__MODULE__{}), do: false

  @doc "Marks the start of a user/model turn."
  @spec begin_turn(t()) :: {:ok, t()} | {:error, term()}
  def begin_turn(%__MODULE__{turn_status: :idle} = state) do
    if state.lifecycle in @terminal_lifecycles do
      {:error, {:invalid_lifecycle_transition, state.lifecycle, :active}}
    else
      {:ok, %__MODULE__{state | lifecycle: :active, turn_status: :in_turn}}
    end
  end

  def begin_turn(%__MODULE__{} = state) do
    {:error, {:invalid_turn_transition, state.turn_status, :in_turn}}
  end

  @doc "Updates in-turn status for active streams, tools, approvals, or remote work."
  @spec put_turn_status(t(), turn_status() | binary()) :: {:ok, t()} | {:error, term()}
  def put_turn_status(%__MODULE__{} = state, status) do
    with {:ok, status} <- Input.normalize_status(status, @turn_statuses, :turn_status) do
      cond do
        state.lifecycle in @terminal_lifecycles ->
          {:error, {:invalid_lifecycle_transition, state.lifecycle, :active}}

        status == :idle ->
          {:error, {:invalid_turn_transition, state.turn_status, :idle}}

        state.turn_status == :idle ->
          {:error, {:invalid_turn_transition, :idle, status}}

        true ->
          {:ok, %__MODULE__{state | lifecycle: :active, turn_status: status}}
      end
    end
  end

  @doc "Marks a turn boundary and applies any queued profile swap."
  @spec end_turn(t()) :: {:ok, t()} | {:error, term()}
  def end_turn(%__MODULE__{lifecycle: lifecycle}) when lifecycle in @terminal_lifecycles,
    do: {:error, {:invalid_lifecycle_transition, lifecycle, :active}}

  def end_turn(%__MODULE__{turn_status: :idle}),
    do: {:error, {:invalid_turn_transition, :idle, :idle}}

  def end_turn(%__MODULE__{} = state) do
    state = %__MODULE__{state | lifecycle: :active, turn_status: :idle}

    apply_pending_profile_swap(state)
  end

  @doc """
  Queues or applies a profile swap while preserving durable runtime references.

  If a swap is already pending, this returns
  `{:error, {:profile_swap_already_pending, existing}}` before accepting or
  applying a new request, even when the current state is otherwise at a safe
  boundary.

  This is BD-0016 data modeling only. BD-0018 owns orchestration, audit event
  emission, checkpoints, compatibility diffing, and runtime integration.
  """
  @spec request_profile_swap(t(), profile_ref() | binary() | atom(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def request_profile_swap(state, profile, opts \\ [])

  def request_profile_swap(%__MODULE__{pending_profile_swap: pending}, _profile, opts)
      when not is_nil(pending) and is_list(opts) do
    {:error, {:profile_swap_already_pending, pending}}
  end

  def request_profile_swap(%__MODULE__{} = state, profile, opts) when is_list(opts) do
    with {:ok, to_profile} <- Input.normalize_profile(profile),
         {:ok, mode} <- Input.fetch_swap_mode(opts, @profile_swap_modes),
         {:ok, cache_policy} <- Input.fetch_cache_policy(opts),
         {:ok, metadata} <- Input.fetch_option_map(opts, :metadata, %{}) do
      request = build_profile_swap_request(state, to_profile, mode, cache_policy, metadata)

      cond do
        safe_to_swap?(state) ->
          {:ok, apply_profile_swap(state, request)}

        state.lifecycle in @terminal_lifecycles ->
          {:error, {:unsafe_profile_swap, request}}

        mode == :queue_until_turn_boundary ->
          {:ok, %__MODULE__{state | pending_profile_swap: request}}

        mode == :reject_mid_turn ->
          {:error, {:unsafe_profile_swap, request}}
      end
    end
  end

  @doc """
  Applies a queued profile swap when the runtime is at a safe turn boundary.

  This helper only mutates the pure state struct. BD-0018 is responsible for
  orchestration, audit events, checkpoints, compatibility diffing, and wiring the
  operation into live runtime flows.
  """
  @spec apply_pending_profile_swap(t()) :: {:ok, t()} | {:error, term()}
  def apply_pending_profile_swap(%__MODULE__{pending_profile_swap: nil} = state), do: {:ok, state}

  def apply_pending_profile_swap(%__MODULE__{} = state) do
    if safe_to_swap?(state) do
      {:ok, apply_profile_swap(state, state.pending_profile_swap)}
    else
      {:error, {:unsafe_profile_swap, state.pending_profile_swap}}
    end
  end

  defp apply_profile_swap(%__MODULE__{} = state, request) do
    %__MODULE__{
      state
      | active_profile: request.to_profile,
        cache_hints: apply_cache_policy(state.cache_hints, request.cache_policy),
        pending_profile_swap: nil
    }
  end

  defp apply_cache_policy(cache_hints, :preserve), do: cache_hints
  defp apply_cache_policy(_cache_hints, :drop), do: %{}
  defp apply_cache_policy(_cache_hints, {:replace, cache_hints}), do: cache_hints

  defp build_profile_swap_request(state, to_profile, mode, cache_policy, metadata) do
    request = %{
      from_profile: state.active_profile,
      to_profile: to_profile,
      mode: mode,
      requested_at_sequence: state.event_sequence,
      blocked_by: state.turn_status,
      cache_policy: cache_policy
    }

    if metadata == %{} do
      request
    else
      Map.put(request, :metadata, metadata)
    end
  end

  defp validate_lifecycle_turn_state(_lifecycle, :idle), do: :ok

  defp validate_lifecycle_turn_state(:active, _status), do: :ok

  defp validate_lifecycle_turn_state(lifecycle, _status) when lifecycle in @terminal_lifecycles,
    do: {:error, {:invalid_lifecycle_transition, lifecycle, :active}}

  defp validate_lifecycle_turn_state(lifecycle, status),
    do: {:error, {:invalid_lifecycle_turn_state, lifecycle, status}}

  defp validate_terminal_pending_swap(lifecycle, pending)
       when lifecycle in @terminal_lifecycles and not is_nil(pending),
       do: {:error, {:unsafe_profile_swap, pending}}

  defp validate_terminal_pending_swap(_lifecycle, _pending), do: :ok
end
